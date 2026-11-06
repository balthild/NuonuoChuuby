import CoreGraphics
import Foundation
import PetBehaviour
import PetDesktop
import PetFoundation
import PetMedia

@MainActor
public protocol PetControllerDelegate: AnyObject {
	func petController(_ controller: PetController, didProduceFrame image: CGImage)
	func petControllerDidChangePlacement(_ controller: PetController)
	func petControllerDidRequestMenu(_ controller: PetController)
	/// The simulation stopped or started again, so anything drawn alongside her
	/// should go away or come back.
	func petController(_ controller: PetController, didChangeSuspension suspended: Bool)
	/// The cheek-pinch overlay changed, or ended (`nil`). It is drawn on top of the
	/// sprite frame, which arrives through ``petController(_:didProduceFrame:)``.
	func petController(_ controller: PetController, didUpdateCheekPinch pinch: CheekPinchState?)
}

extension PetControllerDelegate {
	public func petController(
		_ controller: PetController,
		didUpdateCheekPinch pinch: CheekPinchState?
	) {}
}

@MainActor
public protocol PetMealDelegate: AnyObject {
	/// Items joined the meal queue. Their fake icons go up now, where the files
	/// were, rather than when she sets off for them — she may not get to them for a
	/// while, and an icon that stays missing until then reads as a deletion she
	/// never noticed.
	func petController(_ controller: PetController, didEnqueueMeals items: [DeletedItem])
	func petController(_ controller: PetController, didBeginMeal item: DeletedItem)
	func petController(_ controller: PetController, didFinishMeal item: DeletedItem)
	/// Where the fake icon is and how it is drawn for this tick of the chomping
	/// state. `visual.center` is in the simulation's global top-left coordinates.
	func petController(
		_ controller: PetController,
		didUpdateMeal item: DeletedItem,
		visual: MealConsumptionVisual
	)
}

extension PetMealDelegate {
	public func petController(_ controller: PetController, didEnqueueMeals items: [DeletedItem]) {}

	public func petController(
		_ controller: PetController,
		didUpdateMeal item: DeletedItem,
		visual: MealConsumptionVisual
	) {}
}

/// The pet's brain: it owns the simulation position, the behavioural state
/// machine and the sprite animator, and reports where the window should be.
///
/// The behaviour lives in `PetController+…` files, split by which part of her it
/// belongs to; the stored state stays here, because a stored property cannot be
/// declared in an extension. `private` on a member therefore means **this file only** —
/// the split is why some members that look equally internal are not private.
///
/// Coordinates are points, top-left origin, Y down (see ``DisplaySpace``).
@MainActor
public final class PetController: SpriteAnimatorDelegate {
	enum Motion {
		static let gravity: Double = 1650
		static let terminalVelocity: Double = 1350
		static let horizontalAirDrag: Double = 0.48
		static let walkSpeed: Double = 92
		static let exploreSpeed: Double = 118
		static let groundResponse: Double = 5.8
		static let landingInset: Double = 10
		static let boundaryMargin: Double = 8
		/// Sideways as well as up: the sideways part is what carries her across a gap
		/// onto a nearby window (upstream `BeginTerrainHop`: 315 / 560).
		static let hopVelocityX: Double = 315
		static let hopVelocityY: Double = 560
		/// The same leap, shortened, aimed at the next terrain down (upstream
		/// `BeginTerrainJumpDown`: 255 / 175).
		static let jumpDownVelocityX: Double = 255
		static let jumpDownVelocityY: Double = 175
		static let arrivalTolerance: Double = 5
		/// How fast a ledge must be rising to catch her back up rather than pass her.
		static let airborneCatchUpSpeed: Double = 360
		/// How far she may sit from where the ride last put her before the edge she is
		/// anchored to counts as one she has left.
		static let perchDriftTolerance: Double = 8
	}

	private static let implementedActions: Set<AutonomousAction> = [
		.rest, .wander, .explore, .sleep, .hop,
		.askForFood, .lickIcon, .roll,
	]

	public let profile: PetCharacterProfile
	public weak var delegate: PetControllerDelegate?
	public weak var mealDelegate: PetMealDelegate?
	public weak var speech: PetSpeechCoordinator?
	/// Real desktop icon positions; empty when Accessibility is unavailable, and
	/// callers fall back to ``DesktopIconGrid``.
	public var desktopIcons: DesktopIconIndex?

	public internal(set) var state: PetState = .idle {
		didSet {
			guard state != oldValue else { return }
			DiagnosticsLog.shared.writeEvent(
				"StateTransition",
				[
					("From", oldValue.rawValue),
					("To", state.rawValue),
					("Foot", "\(Int(foot.x)),\(Int(foot.y))"),
				]
			)
		}
	}
	public internal(set) var life: PetLifeState
	public internal(set) var petSize: Double
	public internal(set) var foot: PixelPoint
	/// -1 faces left, +1 faces right.
	public internal(set) var facing: Double = 1

	public var fastingMode = false
	public var quietMode = false {
		didSet {
			// Quiet mode means "only rest and sleep", so it does not just stop her
			// mid-walk: every meal is dropped, in progress or queued, and their icons
			// come down. That matches the original, which clears its food queue and
			// closes every ghost window when the mode is switched on — a queue that
			// kept its icons on screen would advertise food she has been told to
			// ignore.
			if quietMode {
				discardAllMeals(reason: "QuietMode")
				if state == .running || state == .chomping || state == .licking {
					returnToIdle()
				}
			}
		}
	}

	// MARK: - State

	private let catalog: AssetCatalog
	let animator: SpriteAnimator
	let surfaceProvider: SurfaceProvider
	private let lifeStore: PetLifeStateStore
	var displaySpace: DisplaySpace

	var velocity = PixelPoint.zero
	var remainderX: Double = 0
	var remainderY: Double = 0
	var stateElapsed: Double = 0
	private var idleRemaining: Double
	/// Which way she is currently patrolling, or 0 until she picks one.
	var patrolDirection: Double = 0
	/// The purpose a stroll to a point is walked under, remembered for the strolls
	/// that follow an edge leg. ``explore`` takes the quicker pace.
	var strollPurpose: MovementPurpose = .wander
	var terrainActionCooldown: Double = 0
	/// Seconds since the controller started, which is what the cooldowns below are
	/// measured against. ``stateElapsed`` cannot serve: it restarts with every state.
	var elapsedSeconds: Double = 0
	/// When she may next stop a patrol for a given need. See
	/// ``tryInterruptPatrolForNeed()``.
	var actionReadyAt: [AutonomousAction: Double] = [:]
	var nextHungerReactionAt: Double = 0
	var patrolNeedCheckRemaining: Double = 0
	/// Every random draw she makes. Seeded in tests so a run is reproducible.
	var random: PetRandom
	var dragTracker = DragMotionTracker()
	var dragOffset = PixelPoint.zero
	var isDragging = false
	/// No display (session locked, screen asleep) or a fullscreen app in front of
	/// everything. Nothing advances while this is true, and her window is hidden,
	/// because a frozen sprite left floating over the fullscreen app reads as a bug
	/// — and keeping out of that app's way is the point of suspending.
	public private(set) var isSuspended = false
	var targetX: Double = 0
	var targetPoint: PixelPoint = .zero
	var mealQueue = MealQueue()
	var activeMeal: DeletedItem?
	var burstTracker = DeletionBurstTracker()
	/// Simulated seconds until her next unprompted remark about how she feels.
	var selfReportRemaining: Double
	/// Whether the lick under way is aimed at a real Finder icon rather than the
	/// guessed grid, which is what she can taste when it finishes.
	var iconLickUsedRealIcons = false
	var movementPurpose: MovementPurpose = .unset
	var fallStartFootY: Double = 0
	var fallReason = "support-lost"
	var cheek = CheekPinchDynamics()
	/// Where the pinch started, in view points.
	var pinchOrigin: CGPoint = .zero

	var perch: Perch?
	var perchSurface: Surface?
	var lastPerchOffset: Double?
	var perchUnavailableSeconds: Double = 0
	/// So the grace is logged once, not per frame.
	var isInPerchGrace = false
	var perchLogGate = ChangeGate<PlatformMotionResponse>()
	/// A drag-resize grows a box continuously; this keeps the remark to one.
	var boxGrowthGate = ChangeGate<Bool>()
	/// What the desktop looked like one sample ago: whether it was being swapped.
	private var wasDesktopSwapping = false
	/// How long the current swap episode has lasted.
	private var desktopSwapSeconds: Double = 0
	/// So the cap is logged once per episode rather than every frame after it.
	private var hasCappedSwapHold = false
	/// The window she is in the air because of, if any, and where its edge was last
	/// frame, so one rising faster than she flies cannot pass through her.
	var airborneSupportWindowID: UInt32?
	var airborneSupportTop: Double?
	var pendingClimb: WindowClimbPlan?
	var activeClimb: WindowClimbPlan?
	var climbProgress: Double = 0
	var climbStart: PixelPoint = .zero
	/// Where the visible wall begins: the window's bottom, or her feet if higher.
	var climbWallStartY: Double = 0
	var climbHopFraction: Double = 0
	var climbDuration: Double = 3
	var climbWillSucceed = true
	var climbSlipAt: Double = 1
	var transientDuration: Double = 0

	/// Her state while a window's walls hold her.
	///
	/// Deliberately not a `PetState`: inside a box she still falls and rests, so
	/// every state-driven rule (the ride, autonomy, the clip table) would need a
	/// case for it. Holding the window and returning early from ``step(_:)`` says
	/// the same thing without touching any of them.
	struct Enclosure {
		var windowID: UInt32
		var previousBox: PixelRect
		var isResting: Bool
	}

	var enclosure: Enclosure?
	/// Simulated seconds left before another side impact may be felt.
	var sideImpactCooldown: Double = 0
	/// The window-server body sample the collision pass last looked at, so it runs
	/// once per sample rather than once per frame.
	var processedBodyRefreshVersion = -1
	/// A window that has just thrown her must not catch her again on its own top
	/// edge in the same instant: at a corner the side hit and the platform top are
	/// the same window.
	/// The window top just below her, as the graph last described it, tracked by
	/// identity so its real position can be read live.
	///
	/// A window that rises into her path has to be caught by **state** — "its top is
	/// now at or above my feet, and it is still coming up" — because a window can
	/// cross her inside a single frame, and a test for the crossing itself only fires
	/// when a sample happens to land inside it. The graph is rebuilt at 30 Hz while she
	/// falls, so a window rising faster than about 700 pt/s steps clean over the whole
	/// band the landing test looks in, and she used to go straight through it.
	var catcherWindowID: UInt32?
	var catcherTop: Double?
	var ignoredLandingWindow: UInt32?
	var ignoredLandingSeconds: Double = 0
	/// Simulated seconds the window holding her has been covered by one in front
	/// of it. Held briefly, because switching apps covers a window for a moment.
	var enclosureCoveredSeconds: Double = 0
	/// Simulated seconds left before the box's rectangle is read again while she
	/// rests on its floor. Zero or less means it is read this frame.
	var enclosureResampleRemaining: Double = 0
	/// Simulated seconds since the box's rectangle was last read, which is the
	/// interval the two rectangles the physics compares really span.
	var enclosureBoxAgeSeconds: Double = 0

	/// How long the window holding her may be covered before she gives up on it.
	///
	/// She cannot be composited between two ordinary windows, so a covered box
	/// would leave her looking like she is standing on nothing.
	static let enclosureCoverageGraceSeconds: Double = 0.6

	/// How long she goes between unprompted remarks.
	///
	/// Drawn from ``random`` like everything else she does, so adding or removing
	/// any consumer shifts every seeded draw that follows it.
	static func selfReportInterval(using random: inout PetRandom) -> Double {
		Double.random(in: 45...95, using: &random)
	}

	/// How long she must wait before another edge action (a hop, a slide or a jump
	/// off the side). Without it a narrow window, which she can cross in a couple of
	/// seconds, would send her off the edge every time she got there.
	static let terrainActionInterval: Double = 14

	/// How often a leg of an autonomous walk is one out to an edge rather than a
	/// stroll to a point she settles at.
	///
	/// The original always walks to an edge, and an edge is only ever the start of
	/// something else — a hop, a slide, a jump off, or another lap — so she walks
	/// without pause for as long as she is awake. Strolling to a point is what gives a
	/// walk an ending.
	static let edgeLegChance: Double = 0.6

	/// How much a box must grow in one step before she remarks on it, so the
	/// pixel of drift a drag-resize leaves behind is not a window "getting big".
	static let boxGrowthTolerance: Double = 24

	/// How often the box's rectangle is re-read while she rests on its floor.
	///
	/// That read is the largest single item in a resting frame, and a resting
	/// pet's box is normally still, so paying for it sixty times a second buys
	/// nothing. Half the rate rather than a quarter: the saving falls off
	/// steeply (60 → 30 Hz is most of what 60 → 15 Hz gets) while the delay
	/// before she notices a box that has started moving grows in proportion, and
	/// that delay is the price of this.
	static let enclosureRestingResampleInterval: Double = 1.0 / 30

	/// How long a swap may hold her still before she is let go regardless.
	///
	/// A transition lasts a second or two, but the signal that raises this — a window
	/// on no display — would also be raised for ever by an application that parks one
	/// off screen. The cap bounds that to one episode rather than freezing her for the
	/// rest of the session. See ``holdForDesktopSwap(_:)``.
	private static let maximumDesktopSwapSeconds: Double = 6

	let displayScale: Double = 1
	private var timer: Timer?
	private var lastTick: CFAbsoluteTime = 0

	/// The rate the tick timer is running at.
	private(set) var tickIntervalSeconds = PetController.awakeTickInterval
	/// How long nothing has moved her, which is what allows the slow tick.
	private var secondsSinceSheMoved: Double = 0

	/// The tick rate while she is awake.
	static let awakeTickInterval: Double = 1.0 / 60
	/// The tick rate while she is asleep in the `sleep` loop.
	///
	/// That clip is 8 frames at 0.185 s — 5.4 fps — so 10 Hz draws every one of its
	/// frames for two ticks and looks the same, while a tenth of the frames are
	/// composited. The rate is the only thing that can be cut: what a frame costs is the
	/// run loop, the framework and the drawing push, not her own step.
	static let sleepingTickInterval: Double = 1.0 / 10
	/// How long she must have gone without moving before the slow tick is allowed.
	///
	/// Because a slow tick is only honest while nothing is carrying her: asleep on a
	/// window top, she is ridden by it like at any other time, and at 10 Hz she would
	/// ride it in 100 ms steps while the window itself moved smoothly.
	private static let stillnessBeforeSlowTickSeconds: Double = 1
	private var heartbeatRemaining: Double = 10
	private var lastNotifiedFoot: PixelPoint?
	private var lastNotifiedSize: Double?
	private var lastNotifiedMovingFast: Bool?
	private var dragRefreshRemaining: Double = 0
	private static let dragSurfaceRefreshInterval: Double = 2
	var fallRefreshRemaining: Double = 0
	var lastFallRefreshFootY: Double = 0
	/// How often the terrain graph is rebuilt while she is airborne, and how far she
	/// has to fall before it is rebuilt regardless of the clock.
	///
	/// A rebuild enumerates every window, which is the most expensive thing in the
	/// falling loop, so lowering this is worth real CPU: measured over twelve seconds of
	/// repeated throws, the graph rebuild went from **29% to 6%** of main-thread time when
	/// the rate dropped from 25 Hz to under 3, about 2% of a core.
	///
	/// It can be lowered only because the landing no longer depends on it: which window
	/// she is heading for comes from the body sample, and where that window is comes from
	/// the live read. What the graph is still needed for is **occlusion**, and occlusion
	/// that is too old is not harmless — a spot it wrongly calls clear puts her down
	/// somewhere she is covered, and the perch is rejected on the next frame.
	var fallRefreshInterval: Double = 0.25
	var fallRefreshDistance: Double = 100
	/// How many simulation ticks and graph rebuilds the current fall has cost.
	///
	/// Sampling counts cannot be used as a denominator — a symbol that is cheap is
	/// under-sampled, so the denominator moves with the thing being measured. These are
	/// exact, and the rebuild count is what says whether a lower rate was actually
	/// achieved.
	var fallTickCount = 0
	var fallRefreshCount = 0
	/// Collapses a run of catches by one window into a single line.
	///
	/// A window rising into her is caught **every frame** while it keeps rising, and a log
	/// line costs about 45 us — measured, not guessed — so a run of them is worth real
	/// CPU. What is worth recording is that the catch happened, by which window and at
	/// what speed, and that is the same for every frame of the run.
	var caughtLogGate = ChangeGate<UInt32>()

	/// The rate the graph is rebuilt at while she is airborne, for a trace to be told
	/// apart from one taken at another rate without guessing from the launch command.
	public var fallRefreshDescription: String {
		String(format: "%.3fs / %.0fpt", fallRefreshInterval, fallRefreshDistance)
	}

	public init(
		catalog: AssetCatalog,
		surfaceProvider: SurfaceProvider,
		lifeStore: PetLifeStateStore,
		displaySpace: DisplaySpace,
		profile: PetCharacterProfile = .nuonuo,
		petSize: Double = PetSizePolicy.defaultSize,
		randomSeed: UInt64? = nil
	) {
		self.profile = profile
		self.catalog = catalog
		self.surfaceProvider = surfaceProvider
		self.lifeStore = lifeStore
		self.displaySpace = displaySpace
		self.petSize = PetSizePolicy.clampPreferredSize(petSize)
		self.life = lifeStore.load()
		self.random = randomSeed.map(PetRandom.init(seed:)) ?? PetRandom()

		let animator = SpriteAnimator(catalog: catalog, profile: profile)
		self.animator = animator

		let home =
			displaySpace.displays.first?.visibleFrame
			?? PixelRect(x: 0, y: 0, width: 1440, height: 900)
		self.foot = PixelPoint(x: home.centerX, y: home.bottom)
		self.idleRemaining = Double.random(in: 0.5...1.6, using: &random)
		self.selfReportRemaining = Self.selfReportInterval(using: &random)

		animator.delegate = self
		animator.play("idle")
	}

	var sleepRemaining: Double = 0
	/// Whether the wake-up in progress should end in a meal.
	var wakeForMeal = false

	// MARK: - Lifecycle

	public func start() {
		guard timer == nil else { return }
		lastTick = CFAbsoluteTimeGetCurrent()
		scheduleTickTimer()
		if let frame = animator.currentFrame {
			delegate?.petController(self, didProduceFrame: frame)
		}
	}

	private func scheduleTickTimer() {
		timer?.invalidate()
		// `.common` keeps the pet animating while a menu or a drag loop runs.
		let timer = Timer(timeInterval: tickIntervalSeconds, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.tick() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	public func stop() {
		timer?.invalidate()
		timer = nil
		try? lifeStore.save(life)
	}

	func tick() {
		let now = CFAbsoluteTimeGetCurrent()
		let elapsed = now - lastTick
		lastTick = now
		// A paused app must not fast-forward the simulation.
		step(min(max(elapsed, 0), 0.1))
		updateTickRate()
	}

	/// How fast she should be ticked for what she is doing now.
	///
	/// Slow only for the `sleep` loop, and only once she has been still for a while. The
	/// two clips on either side of it are left out for their own reasons: `sleep_enter`'s
	/// frames are 0.145 s and `sleep_exit`'s 0.105 s, neither of which a 0.1 s tick lands
	/// evenly, so they would stutter where the loop does not (and `sleep_exit` is played
	/// in the waking state anyway).
	var wantedTickInterval: Double {
		guard state == .sleeping, animator.currentClip == "sleep",
			secondsSinceSheMoved >= Self.stillnessBeforeSlowTickSeconds
		else { return Self.awakeTickInterval }
		return Self.sleepingTickInterval
	}

	/// Restarts the tick timer when the rate that suits her has changed.
	///
	/// Called after every step, and from ``enter(_:clip:purpose:velocity:facing:transientSeconds:)``
	/// so that a drag, a wake or a throw takes effect at once rather than a slow tick
	/// later.
	func updateTickRate() {
		let wanted = wantedTickInterval
		guard wanted != tickIntervalSeconds else { return }
		tickIntervalSeconds = wanted
		// Nothing to reschedule when the timer was never started: `start()` reads the
		// rate in force.
		guard timer != nil else { return }
		scheduleTickTimer()
	}

	func step(_ delta: Double) {
		let timing = FrameTiming.fromElapsed(
			delta,
			// The cap is for a hitch, not for a deliberately slow tick: the two are told
			// apart by the tick rate in force, and a 0.1 s cap at 10 Hz is what keeps the
			// sleep loop playing at its own speed rather than at half of it.
			maximumAnimationStep: max(FrameTiming.defaultMaximumAnimationStep, tickIntervalSeconds)
		)
		let simulation = timing.simulationSeconds
		guard simulation > 0 else { return }

		// Measured around the whole step rather than in ``tick()``, because a test drives
		// this directly and the slow tick turns on it either way.
		let footBefore = foot
		defer { secondsSinceSheMoved = foot == footBefore ? secondsSinceSheMoved + simulation : 0 }

		life.advance(elapsedSeconds: simulation, sleeping: state == .sleeping)
		stateElapsed += simulation
		elapsedSeconds += simulation

		// Kept refreshing while suspended too: this is where the fullscreen check
		// below gets its data, so stopping it would mean never resuming.
		if isDragging {
			dragRefreshRemaining -= simulation
			if dragRefreshRemaining <= 0 {
				surfaceProvider.refresh(displaySpace: displaySpace)
				dragRefreshRemaining = Self.dragSurfaceRefreshInterval
			}
			fallRefreshRemaining = 0
		} else if state == .falling {
			dragRefreshRemaining = 0
			refreshForFalling(simulation)
		} else {
			dragRefreshRemaining = 0
			fallRefreshRemaining = 0
			surfaceProvider.refreshIfStale(displaySpace: displaySpace, delta: simulation)
		}

		// No display (session locked, screen asleep) or a fullscreen app: suspend.
		let suspended = displaySpace.displays.isEmpty || surfaceProvider.isFullscreenAppActive
		if suspended != isSuspended {
			isSuspended = suspended
			if !suspended { resumeFromSuspension() }
			DiagnosticsLog.shared.writeEvent(
				"SuspensionChanged",
				[
					("Suspended", "\(suspended)"),
					("State", state.rawValue),
					("Foot", "\(Int(foot.x)),\(Int(foot.y))"),
					("Support", enclosure != nil ? "enclosure" : perchSurface?.key.kind.rawValue ?? "none"),
				]
			)
			delegate?.petController(self, didChangeSuspension: suspended)
		}
		if suspended {
			return
		}

		// Body sampling is only needed for free movement and falls; dragging is
		// directly controlled by the cursor and skips this expensive path.
		if !isDragging {
			surfaceProvider.sampleBodiesIfStale(displaySpace: displaySpace, delta: simulation)
		}

		// Asked before the collision pass, because the sample that notices the swap
		// is the first one that compares two different desktops.
		if holdForDesktopSwap(simulation) {
			// Her overlay is not on a Space, so she keeps her place on screen while the
			// desktop slides past her.
			animator.tick(timing.animationSeconds)
			notifyPlacementIfChanged()
			return
		}

		// Not while dragging: the cursor moves her directly, and a side impact is
		// not something a hand on her can be given.
		if !isDragging {
			updateWindowSideCollisions()
		}
		tickCooldowns(simulation)

		// Inside a window the four walls are the whole world: no ride, no
		// autonomy, no terrain. Everything below belongs to the open desktop.
		if !updateWindowEnclosure(simulation) {
			// Runs for every grounded state, not only while walking: a dragged
			// window moves her whether or not she happens to be walking.
			maintainGroundSupport(simulation)
			updateState(simulation)
		}

		// A meal lives in the two states that carry it and nowhere else. Whatever
		// pulls her out of them without finishing it — a pinch, a window's edge
		// throwing her, being sent home — hands the item back to the queue, which is
		// also what takes its ghost icon off the display and lets the queue move on.
		if activeMeal != nil, state != .chomping,
			!(state == .running && movementPurpose == .meal)
		{
			requeueActiveMeal(reason: state.rawValue)
		}

		reportMealVisual()

		animator.tick(timing.animationSeconds)
		// The pinch spring runs independently of the walk cycle.
		updatePinchFrame(simulation)
		notifyPlacementIfChanged()
		logHeartbeat(simulation)
	}

	/// A periodic snapshot of state, position and support.
	///
	/// The state log only fires on transitions, so a pet that settled somewhere
	/// wrong would otherwise log nothing at all.
	private func logHeartbeat(_ delta: Double) {
		heartbeatRemaining -= delta
		guard heartbeatRemaining <= 0 else { return }
		heartbeatRemaining = 10

		// Inside a window the four walls are what holds her, and she rests there
		// with `state == .idle` — so reporting "none" would look exactly like the
		// floating bug this heartbeat exists to catch (see Docs/Internal/physics.md).
		let support: String
		let tracked: String
		if let enclosure {
			support = "enclosure"
			tracked = String(enclosure.windowID)
		} else {
			switch perchSurface?.key.kind {
			case nil: support = "none"
			case .some(.floor): support = "floor"
			default: support = "window"
			}
			tracked =
				perch.flatMap { $0.key.kind == .windowTop ? String($0.key.owner) : nil } ?? "none"
		}
		let position = "\(Int(foot.x)),\(Int(foot.y))"

		DiagnosticsLog.shared.writeEvent(
			"StatusHeartbeat",
			[
				("State", state.rawValue),
				("Foot", position),
				("Support", support),
				("Tracked", tracked),
				("VelocityY", String(format: "%.0f", velocity.y)),
			]
		)
	}

	/// Her window follows the simulation, so every place that moves the foot or
	/// changes the size must go through here — a drag updates the foot *between*
	/// ticks, where a change made during `step()` would never be noticed.
	///
	/// ``isMovingFast`` is compared as well, even though it is not part of where she is.
	/// A renderer that stops following her with a window has to be told when it may start
	/// again, and the frame that state ends is exactly the frame she *stops* moving: a
	/// settle leaves her feet on the floor where the previous frame already put them, so
	/// a test on her position alone never fires, and the renderer holds the state until
	/// something else happens to move her.
	func notifyPlacementIfChanged() {
		let movingFast = isMovingFast
		guard
			lastNotifiedFoot != foot || lastNotifiedSize != petSize
				|| lastNotifiedMovingFast != movingFast
		else { return }
		lastNotifiedFoot = foot
		lastNotifiedSize = petSize
		lastNotifiedMovingFast = movingFast
		delegate?.petControllerDidChangePlacement(self)
	}

	// MARK: - Idle & autonomy

	private func updateIdle(_ delta: Double) {
		idleRemaining -= delta
		guard idleRemaining <= 0 else { return }

		// A queued meal is picked up before anything else she might decide to do,
		// so one that arrived while she was airborne or mid-clip is not forgotten.
		if !mealQueue.isEmpty, beginNextMeal() { return }

		let hasSupport = surfaceProvider.support(at: foot) != nil

		// A strongly sleepy pet naps regardless of the weighted draw.
		if life.sleepiness >= LifeBehaviorPolicy.sleepInterruptionThreshold {
			beginSleep()
			return
		}

		let available = Self.implementedActions.filter {
			PetModePolicy.allowsAutonomousAction($0, fastingMode: fastingMode, quietMode: quietMode)
		}
		let action = AutonomousBehaviorPlanner.choose(
			life: life,
			hasGroundSupport: hasSupport,
			availableActions: available,
			randomUnit: Double.random(in: 0..<1, using: &random),
			profile: profile
		)
		DiagnosticsLog.shared.writeEvent(
			"AutonomousDecision",
			[
				("Action", action.rawValue),
				("Support", "\(hasSupport)"),
				("Sleepiness", String(format: "%.0f", life.sleepiness)),
				("Curiosity", String(format: "%.0f", life.curiosity)),
				("Hunger", String(format: "%.0f", life.hunger)),
			]
		)

		switch action {
		case .sleep:
			beginSleep()
		case .wander:
			beginAutonomousWalk(preferClimb: false, strollPurpose: .wander)
		case .explore:
			if beginAutonomousWalk(preferClimb: true, strollPurpose: .explore) {
				announce(.exploration, voice: .question, priority: .normal)
			}
		case .hop:
			beginHop()
		case .askForFood:
			// Pending meals take priority over pleading for one.
			if beginNextMeal() { return }
			beginHungryPlea()
		case .lickIcon:
			if beginNextMeal() { return }
			if tryBeginIconLick(manual: false) { return }
			resetIdleTimer(factor: 1.2)
		case .roll:
			beginRoll()
		case .rest:
			resetIdleTimer(factor: 1.4)
		}
	}

	private func resetIdleTimer(factor: Double = 1) {
		idleRemaining = Double.random(in: 1.2...profile.maximumIdleSeconds, using: &random) * factor
	}

	/// Says how she feels, unprompted: the one line here that is not tied to
	/// something happening.
	func reportOwnMood() {
		guard state == .idle, !quietMode else { return }
		guard let line = PetMoodSpeech.line(life: life, fastingMode: fastingMode) else { return }
		announce(line.cue, voice: line.voice, priority: .ambient)
	}

	// MARK: - Geometry

	/// Where a canvas anchor sits on screen for the pet's current size.
	var canvasScale: Double { petSize / SpriteGeometry.canvasSize }

	func screenPoint(canvasX: Double, canvasY: Double) -> PixelPoint {
		PixelPoint(
			x: foot.x + (canvasX - profile.geometry.footCanvasX) * canvasScale,
			y: foot.y + (canvasY - profile.geometry.footCanvasY) * canvasScale
		)
	}

	/// The rectangle she can be hit in, in global top-left coordinates.
	///
	/// The feet are deliberately outside it, so standing on a window's top edge can
	/// never be mistaken for that window's side edge sweeping through her.
	func bodyRect(bottomCanvasY: Double? = nil) -> PixelRect {
		let topLeft = screenPoint(
			canvasX: profile.geometry.bodyCollisionLeftCanvasX,
			canvasY: profile.geometry.bodyCollisionTopCanvasY
		)
		let bottomRight = screenPoint(
			canvasX: profile.geometry.bodyCollisionRightCanvasX,
			canvasY: bottomCanvasY ?? profile.geometry.bodyCollisionBottomCanvasY
		)
		return PixelRect(
			x: topLeft.x,
			y: topLeft.y,
			width: bottomRight.x - topLeft.x,
			height: bottomRight.y - topLeft.y
		)
	}

	/// Her rectangle as a window enclosure sees it: ``bodyRect(bottomCanvasY:)`` with
	/// the **feet included**, unlike the plain ``bodyRect()``.
	///
	/// A box holds her at the feet — they are what rests on its floor — so the feet must
	/// be inside the rectangle the walls are measured against. Excluding them leaves her
	/// standing with her feet below the window's bottom edge by the gap between the body's
	/// bottom and the foot anchor, which grows with her size. The original draws the same
	/// line: its enclosure passes `FootCanvasY`, while its side-impact hitbox omits the feet.
	var enclosureBodyRect: PixelRect {
		bodyRect(bottomCanvasY: profile.geometry.footCanvasY)
	}

	// MARK: - Suspension and the desktop swap

	/// Forgets everything that measures movement **across frames**, because the frames
	/// it is measured over did not happen.
	///
	/// Every moving thing here is a difference between the last sample and this one,
	/// divided by a frame to get a speed: the ledge she rides, the walls of a box, and
	/// a window edge sweeping at her. Suspended, none of them are asked — so on the way
	/// back, each is a difference spanning the whole suspension while still being
	/// divided by one frame. A display that rearranged itself, or a window that moved,
	/// then reads as something lashing past her, and she is thrown off her footing the
	/// moment she reappears.
	///
	/// Zeroing the baselines makes the first frame back a starting point instead. The
	/// ride then carries her to wherever the surface is now, which is what she should
	/// do after a gap: the world moved, she did not.
	private func resumeFromSuspension() {
		rebaselineCrossFrameMotion()
	}

	/// Restarts every measurement made by differencing two frames, so the next frame
	/// is read as a starting point rather than as a movement.
	///
	/// Used for the two gaps the simulation can have — a suspension, and the desktop
	/// being swapped under her by a space switch — where nothing she observed changed
	/// because of her.
	private func rebaselineCrossFrameMotion() {
		lastPerchOffset = nil
		surfaceProvider.rebaselineBodySamples()
		enclosureResampleRemaining = 0
		enclosureBoxAgeSeconds = 0
		catcherTop = nil
		if let current = enclosure, let box = liveBounds(of: current.windowID) {
			enclosure?.previousBox = box
		}
	}

	/// Whether the desktop is being swapped under her, having noticed the change.
	///
	/// While the transition runs the window server reports the neighbouring desktops'
	/// windows beside this one's — laid out along the strip the transition slides
	/// across, thousands of points outside every display — so nothing about her
	/// surroundings can be read from it. An edge sweeping through her is the whole
	/// desktop moving rather than a window being dragged, the walls of a box she is in
	/// are being slid out from under her, and the edge she stands on belongs to a desk
	/// she has left.
	///
	/// Held still rather than corrected, for the same reason a suspension is handled
	/// this way: there is no right answer to compute from the data, and every attempt
	/// to interpolate through it gave her a sideways throw or a ledge to stand on that
	/// was not there. Measured baselines are dropped on both edges, so neither the
	/// transition nor its end can read as her own movement.
	private func holdForDesktopSwap(_ delta: Double) -> Bool {
		let reported = surfaceProvider.isDesktopSwapping
		desktopSwapSeconds = reported ? desktopSwapSeconds + delta : 0
		// An application that keeps a window parked off screen would raise the signal
		// for ever. The cap ends one episode instead of holding her for the session;
		// that window stays out of her world either way, because the sample drops it.
		let swapping = reported && desktopSwapSeconds <= Self.maximumDesktopSwapSeconds
		if reported, !swapping, !hasCappedSwapHold {
			hasCappedSwapHold = true
			DiagnosticsLog.shared.writeEvent(
				"DesktopSwapHoldCapped",
				[("Seconds", String(format: "%.1f", desktopSwapSeconds))]
			)
		}
		if !reported { hasCappedSwapHold = false }

		guard swapping != wasDesktopSwapping else { return swapping }

		wasDesktopSwapping = swapping
		rebaselineCrossFrameMotion()
		// The graph is stale by the whole transition otherwise, and the first thing
		// asked of it once she is moving again is whether the edge she is on still
		// exists.
		if !swapping { surfaceProvider.refresh(displaySpace: displaySpace) }
		DiagnosticsLog.shared.writeEvent(
			"DesktopSwapped",
			[
				("Swapping", "\(swapping)"),
				("State", state.rawValue),
				("Foot", "\(Int(foot.x)),\(Int(foot.y))"),
				("Support", enclosure != nil ? "enclosure" : perchSurface?.key.kind.rawValue ?? "none"),
			]
		)
		return swapping
	}

	// MARK: - State dispatch

	/// The single way she leaves one state for another.
	///
	/// Every transition used to be written out by hand in its own order — set the
	/// state, restart the clock, set or clear the velocity, pick the clip — and the
	/// copies had drifted apart.
	///
	/// What this deliberately does **not** own is the fractional pixel in flight
	/// (`remainderX` / `remainderY`). Whether it is worth carrying across a transition
	/// depends on whether the motion is continuous through it, which is a per-call
	/// judgement — the enclosure, for one, absorbs it in the wall that was hit. Callers
	/// still clear it where they mean to.
	///
	/// - Parameters:
	///   - velocity: the velocity to enter with; `.zero` to come to rest, `nil` to
	///     leave whatever she already had.
	///   - purpose: `MovementPurpose.unset` to clear it, `nil` to leave it as it was.
	///     That case is deliberately not spelled `.none`: in this optional position
	///     `.none` resolves to `Optional.none` and compiles.
	///   - transientSeconds: how long a one-shot state (`landing`, `curious`,
	///     `satisfied`, `rolling`) lasts before it falls back to idle.
	func enter(
		_ next: PetState,
		clip: String? = nil,
		purpose: MovementPurpose? = nil,
		velocity newVelocity: PixelPoint? = .zero,
		facing newFacing: Double? = nil,
		transientSeconds: Double? = nil
	) {
		state = next
		stateElapsed = 0
		if let newVelocity { velocity = newVelocity }
		if let purpose { movementPurpose = purpose }
		if let newFacing { facing = newFacing }
		if let transientSeconds { transientDuration = transientSeconds }
		if let clip { animator.play(clip) }
		// The rate follows the state wherever it changes: a hand on her while she sleeps,
		// a wake for a meal, a window edge throwing her, all have to be drawn at the
		// ordinary rate from the next frame, not a tenth of a second later.
		updateTickRate()
	}

	/// One frame of whichever behaviour the current state owns. Inside a window
	/// this is skipped entirely: the walls decide everything.
	private func updateState(_ delta: Double) {
		switch state {
		case .idle: updateIdle(delta)
		case .running: updateRunning(delta)
		case .falling: updateFalling(delta)
		case .climbing: updateClimbing(delta)
		case .landing, .curious, .satisfied, .rolling:
			if stateElapsed >= transientDuration {
				returnToIdle()
			}
		case .waking:
			guard stateElapsed >= transientDuration else { return }
			finishWaking()
		case .sleeping: updateSleeping(delta)
		case .chomping, .licking:
			// Driven by the clip finishing, not by a timer.
			break
		default: break
		}
	}

	/// Her mouth and lick point, which are what actually reach the target.
	var mouthPoint: PixelPoint {
		screenPoint(
			canvasX: profile.geometry.mouthCanvasX,
			canvasY: profile.geometry.mouthCanvasY
		)
	}

	var lickPoint: PixelPoint {
		screenPoint(
			canvasX: profile.geometry.lickContactCanvasX,
			canvasY: profile.geometry.lickContactCanvasY
		)
	}

	func persistLifeStateQuietly() {
		try? lifeStore.save(life)
	}

	func returnToIdle() {
		enter(.idle, clip: "idle", purpose: MovementPurpose.unset)
		remainderX = 0
		wakeForMeal = false
		resetIdleTimer()
	}

	// MARK: - Test seams

	/// A window server cannot be driven on demand in a test, so the ride logic is
	/// exercised through these three entry points instead. They are internal: no
	/// part of the app reads them.
	struct DebugState {
		var state: PetState
		var velocityX: Double
		var velocityY: Double
		var foot: PixelPoint
		var fallReason: String
		/// What she set out to do — the walk she is in the middle of, if any.
		var movementPurpose: MovementPurpose
		/// The window currently being ridden, if any.
		var trackedWindowID: UInt32?
		/// The edge she is anchored to, if any.
		var perchKey: SurfaceKey?
		/// The window whose walls are holding her, if any.
		var enclosureWindowID: UInt32?
	}

	var debugState: DebugState {
		DebugState(
			state: state,
			velocityX: velocity.x,
			velocityY: velocity.y,
			foot: foot,
			fallReason: fallReason,
			movementPurpose: movementPurpose,
			trackedWindowID: perch.flatMap { $0.key.kind == .windowTop ? $0.key.owner : nil },
			perchKey: perch?.key,
			enclosureWindowID: enclosure?.windowID
		)
	}

	/// Stands in for the per-frame live window query the enclosure makes.
	var debugLiveWindowBoundsOverride: ((UInt32) -> PixelRect?)?

	/// Stands in for the release velocity the drag tracker computes.
	///
	/// The tracker measures between real timestamps, so a drag a test scripts is always
	/// a drop — and the release velocity is what decides whether the window under her
	/// takes her in. Set this before ``endDrag(at:)`` to release her at a speed of the
	/// test's choosing.
	var debugReleaseMotionOverride: DragReleaseMotion?

	/// Meals still waiting their turn, not counting the one she is eating.
	var debugQueuedMealCount: Int { mealQueue.count }

	/// Her hittable body rectangle, as the collision and enclosure code sees it.
	func debugBodyRect() -> PixelRect { bodyRect() }

	/// Advances only the enclosure step, as one frame would.
	func debugUpdateEnclosure(delta: Double) -> Bool {
		updateWindowEnclosure(delta)
	}

	/// Places her on a known surface and anchors her to it.
	func debugPlaceOnSurface(_ surface: Surface) {
		state = .idle
		movementPurpose = .unset
		foot = PixelPoint(x: surface.span.start + surface.span.length / 2, y: surface.offset)
		adopt(surface)
	}

	/// Advances only the ground-support handling, as one frame would.
	func debugMaintainGroundSupport(delta: Double) {
		maintainGroundSupport(delta)
	}

	/// Advances one whole simulation frame, as the timer would.
	func debugStep(delta: Double) {
		step(delta)
	}

	/// Triggers a hop, which is normally chosen by the autonomy planner. The
	/// planner's own direction is random, so tests may pin one.
	func debugBeginHop(direction: Int? = nil) {
		beginHop(direction: direction)
	}

	/// Starts a ground walk towards a chosen x, which the autonomy planner would
	/// otherwise only pick by weight.
	func debugBeginWalk(toX x: Double) {
		targetX = x
		enter(.running, clip: "walk", purpose: .wander, velocity: nil)
	}

	/// Starts a patrol leg, which the autonomy planner would otherwise only pick by
	/// weight. `direction` pins which end she sets out for, which is otherwise drawn.
	///
	/// The leg kind and the climb look are both coin flips inside a walk, so they are
	/// skipped here: a test that asks for a patrol wants a patrol.
	func debugBeginPatrol(direction: Double? = nil) {
		if let direction { patrolDirection = direction }
		if beginPatrolLeg() { return }
		returnToIdle()
	}

	/// Starts an autonomous walk, whose leg kind is drawn unless
	/// ``debugForcedEdgeLeg`` pins it.
	@discardableResult
	func debugBeginAutonomousWalk(
		preferClimb: Bool = false,
		strollPurpose: MovementPurpose = .wander
	) -> Bool {
		beginAutonomousWalk(preferClimb: preferClimb, strollPurpose: strollPurpose)
	}

	/// Pins which kind of leg the next one is, so a test need not depend on the draw.
	/// True is a leg out to an edge, false a stroll to a point.
	var debugForcedEdgeLeg: Bool?

	/// Draws one leg-kind decision, as a walk would, so the ratio can be measured.
	func debugRollIsEdgeLeg() -> Bool { rollIsEdgeLeg() }

	/// Raises a need, so a test need not simulate the minutes of drift that would
	/// normally get her there.
	func debugSetLife(hunger: Double? = nil, sleepiness: Double? = nil) {
		if let hunger { life.hunger = hunger }
		if let sleepiness { life.sleepiness = sleepiness }
	}

	/// The end of her run she is currently walking to.
	var debugPatrolTargetX: Double { targetX }

	/// How far short of an end of her run a patrol stops when it arrives.
	var debugPatrolStopMargin: Double { patrolStopMargin }

	/// Forces the edge decision, so a test can pin a hop, a slide or a jump instead of
	/// depending on which way the draw happens to fall.
	var debugForcedTerrainEdgeAction: TerrainEdgeAction?

	/// Naps, which the autonomy planner would otherwise only choose by weight.
	func debugBeginSleep() {
		beginSleep()
	}

	/// Faces her a given way, which the simulation otherwise only does by walking
	/// her somewhere.
	func debugSetFacing(_ value: Double) {
		facing = value
	}

	/// The pinch's current offset in canvas units, positive towards her right in
	/// the authored art.
	var debugCheekOffset: (x: Double, y: Double) { (cheek.x, cheek.y) }

	/// Which clip is playing, so a test can pin what an interrupted state leaves behind.
	var debugCurrentClip: String { animator.currentClip }

	/// Stands in for the per-frame live window read.
	///
	/// A test cannot make the window server describe a window, so this models the
	/// case that matters: the live read succeeds and reports the whole edge, while
	/// the graph already knows another window covers her spot.
	var debugLiveWindowSurfaceOverride: ((UInt32) -> Surface?)?

	/// Lands on a surface, as a completed fall would.
	func debugLand(on surface: Surface) {
		releasePerch()
		foot = PixelPoint(x: surface.span.start + surface.span.length / 2, y: surface.offset)
		land(on: surface)
	}

	// MARK: - External commands

	public func bringHome() {
		guard let home = displaySpace.displays.first?.visibleFrame else { return }
		surrenderEnclosure(reason: "BringHome")
		foot = PixelPoint(x: home.centerX, y: home.bottom)
		velocity = .zero
		remainderX = 0
		remainderY = 0
		// Home is the floor, which is not where she was: dropping the perch makes the
		// next frame anchor her to what is under her rather than ride her back up.
		releasePerch()
		returnToIdle()
		notifyPlacementIfChanged()
		announce(.home, voice: .affirmative, priority: .normal)
	}

	/// Announces the startup line once, after the first frame is on screen.
	public func announceStartup() {
		announce(.startup, voice: .neutral, priority: .normal)
	}

	func announce(
		_ cue: DialogueCue,
		voice: VoiceCue,
		priority: VoicePriority = .normal,
		itemName: String? = nil
	) {
		speech?.react(cue, voice: voice, priority: priority, itemName: itemName)
	}

	public func setSize(_ size: Double) {
		petSize = PetSizePolicy.clampPreferredSize(size)
		notifyPlacementIfChanged()
		// Resizing her is the one thing that can make a box she fits in stop
		// fitting; a box that still holds her keeps holding her.
		_ = enclosureFitsTheBox()
	}

	/// Rebuilds the coordinate space after a display change and re-clamps the pet
	/// so it cannot be left off every screen.
	public func updateDisplaySpace(_ space: DisplaySpace) {
		displaySpace = space
		// Inside a window the box is the authority on where she is, so the
		// display's own edges must not clamp her out of it. She is released only
		// if the box can no longer hold her.
		if !enclosureFitsTheBox() { return }
		if enclosure == nil, let display = space.display(containing: foot) {
			let clampedX = min(max(foot.x, display.frame.left + 12), display.frame.right - 12)
			if clampedX != foot.x { foot.x = clampedX }
			if foot.y > display.visibleFrame.bottom { foot.y = display.visibleFrame.bottom }
		}
		notifyPlacementIfChanged()
	}

	public func persistLifeState() {
		try? lifeStore.save(life)
	}

	// MARK: - Placement

	public var footInset: PixelPoint {
		PixelPoint(
			x: petSize * profile.geometry.footCanvasX / SpriteGeometry.canvasSize,
			y: petSize * profile.geometry.footCanvasY / SpriteGeometry.canvasSize
		)
	}

	/// Her window's top-left corner in global top-left coordinates.
	public var windowTopLeft: PixelPoint {
		PixelPoint(x: foot.x - footInset.x, y: foot.y - footInset.y)
	}

	/// Her whole square, in global top-left coordinates.
	public var petFrame: PixelRect {
		let topLeft = windowTopLeft
		return PixelRect(x: topLeft.x, y: topLeft.y, width: petSize, height: petSize)
	}

	/// The interactive body ellipse, in the view's own (flipped, Y-down) space.
	public var bodyEllipseInView: CGRect {
		let scale = petSize / SpriteGeometry.canvasSize
		let geometry = profile.geometry
		let left = geometry.bodyCollisionLeftCanvasX * scale
		let top = geometry.bodyCollisionTopCanvasY * scale
		let right = geometry.bodyCollisionRightCanvasX * scale
		let bottom = geometry.bodyCollisionBottomCanvasY * scale
		return CGRect(x: left, y: top, width: right - left, height: bottom - top)
	}

	// MARK: - SpriteAnimatorDelegate

	public func spriteAnimator(_ animator: SpriteAnimator, didChangeTo frame: CGImage) {
		// The pinch, when there is one, is an overlay the presenter draws on top of
		// this frame — so the frame is always the cel itself.
		delegate?.petController(self, didProduceFrame: frame)
	}

	public func spriteAnimator(_ animator: SpriteAnimator, didFinishClip clip: String) {
		switch clip {
		case "chomp":
			// Eating the item is what completes the meal.
			completeActiveMeal()
		case "lick":
			// The verdict on what she tasted.
			announce(
				iconLickUsedRealIcons ? .iconTaste : .iconsHidden,
				voice: iconLickUsedRealIcons ? .aggrieved : .question,
				priority: .normal
			)
			// She drops from the icon's height rather than snapping back to the edge
			// she set off from; `purpose` is cleared so the ride resumes on landing.
			beginFall(reason: "IconLickFinished", purpose: MovementPurpose.unset)
		case "satisfied", "satisfied_quick":
			advanceAfterMeal()
		case "land", "curious":
			if state == .landing || state == .curious {
				returnToIdle()
			}
		case "sleep_exit":
			// The wake can end on the clip finishing as well as on the timer.
			if state == .waking {
				finishWaking()
			}
		default:
			break
		}
	}
}
