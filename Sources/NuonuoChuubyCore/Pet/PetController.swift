import AppKit

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
	public func petController(
		_ controller: PetController,
		didUpdateMeal item: DeletedItem,
		visual: MealConsumptionVisual
	) {}
}

/// The pet's brain: it owns the simulation position, the behavioural state
/// machine and the sprite animator, and reports where the window should be.
///
/// Coordinates are points, top-left origin, Y down (see ``DisplaySpace``).
@MainActor
public final class PetController: SpriteAnimatorDelegate {
	private enum Motion {
		static let gravity: Double = 1650
		static let terminalVelocity: Double = 1350
		static let horizontalAirDrag: Double = 0.48
		static let walkSpeed: Double = 92
		static let exploreSpeed: Double = 118
		static let groundResponse: Double = 5.8
		static let landingInset: Double = 10
		static let boundaryMargin: Double = 8
		static let hopVelocity: Double = 420
		static let arrivalTolerance: Double = 5
		static let movementTimeout: Double = 8
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

	public private(set) var state: PetState = .idle {
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
	public private(set) var life: PetLifeState
	public private(set) var petSize: Double
	public private(set) var foot: PixelPoint
	/// -1 faces left, +1 faces right.
	public private(set) var facing: Double = 1

	public var fastingMode = false
	public var quietMode = false {
		didSet {
			// Turning quiet mode on stops her mid-walk; an interrupted meal goes back
			// on the queue rather than being lost.
			if quietMode {
				requeueActiveMeal(reason: "QuietMode")
				if state == .running || state == .chomping || state == .licking {
					returnToIdle()
				}
			}
		}
	}

	private let catalog: AssetCatalog
	private let animator: SpriteAnimator
	private let surfaceProvider: SurfaceProvider
	private let lifeStore: PetLifeStateStore
	private var displaySpace: DisplaySpace

	private var velocity = PixelPoint.zero
	private var remainderX: Double = 0
	private var remainderY: Double = 0
	private var stateElapsed: Double = 0
	private var idleRemaining: Double
	/// Every random draw she makes. Seeded in tests so a run is reproducible.
	private var random: PetRandom
	private var dragTracker = DragMotionTracker()
	private var dragOffset = PixelPoint.zero
	private var isDragging = false
	/// No display (session locked, screen asleep) or a fullscreen app in front of
	/// everything. Nothing advances while this is true, and her window is hidden,
	/// because a frozen sprite left floating over the fullscreen app reads as a bug
	/// — and keeping out of that app's way is the point of suspending.
	public private(set) var isSuspended = false
	private var targetX: Double = 0
	private var targetPoint: PixelPoint = .zero
	private var mealQueue = MealQueue()
	private var activeMeal: DeletedItem?
	private var burstTracker = DeletionBurstTracker()
	private var movementPurpose: MovementPurpose = .none
	private var fallStartFootY: Double = 0
	private var fallReason = "support-lost"
	private var cheek = CheekPinchDynamics()
	/// Where the pinch started, in view points.
	private var pinchOrigin: CGPoint = .zero

	// MARK: - Support

	private var perch: Perch?
	private var perchSurface: Surface?
	private var lastPerchOffset: Double?
	private var perchUnavailableSeconds: Double = 0
	/// So the grace is logged once, not per frame.
	private var isInPerchGrace = false
	private var perchLogGate = ChangeGate<PlatformMotionResponse>()
	/// The window she is in the air because of, if any, and where its edge was last
	/// frame, so one rising faster than she flies cannot pass through her.
	private var airborneSupportWindowID: UInt32?
	private var airborneSupportTop: Double?
	private var pendingClimb: WindowClimbPlan?
	private var activeClimb: WindowClimbPlan?
	private var climbProgress: Double = 0
	private var climbStart: PixelPoint = .zero
	/// Where the visible wall begins: the window's bottom, or her feet if higher.
	private var climbWallStartY: Double = 0
	private var climbHopFraction: Double = 0
	private var climbDuration: Double = 3
	private var climbWillSucceed = true
	private var climbSlipAt: Double = 1
	private var transientDuration: Double = 0

	/// Her state while a window's walls hold her.
	///
	/// Deliberately not a `PetState`: inside a box she still falls and rests, so
	/// every state-driven rule (the ride, autonomy, the clip table) would need a
	/// case for it. Holding the window and returning early from ``step(_:)`` says
	/// the same thing without touching any of them.
	private struct Enclosure {
		var windowID: UInt32
		var previousBox: PixelRect
		var isResting: Bool
	}

	private var enclosure: Enclosure?
	/// Simulated seconds left before another side impact may be felt.
	private var sideImpactCooldown: Double = 0
	/// The window-server body sample the collision pass last looked at, so it runs
	/// once per sample rather than once per frame.
	private var processedBodyRefreshVersion = -1
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
	private var catcherWindowID: UInt32?
	private var catcherTop: Double?
	private var ignoredLandingWindow: UInt32?
	private var ignoredLandingSeconds: Double = 0
	/// Simulated seconds the window holding her has been covered by one in front
	/// of it. Held briefly, because switching apps covers a window for a moment.
	private var enclosureCoveredSeconds: Double = 0
	/// Simulated seconds left before the box's rectangle is read again while she
	/// rests on its floor. Zero or less means it is read this frame.
	private var enclosureResampleRemaining: Double = 0
	/// Simulated seconds since the box's rectangle was last read, which is the
	/// interval the two rectangles the physics compares really span.
	private var enclosureBoxAgeSeconds: Double = 0

	/// How long the window holding her may be covered before she gives up on it.
	///
	/// She cannot be composited between two ordinary windows, so a covered box
	/// would leave her looking like she is standing on nothing.
	private static let enclosureCoverageGraceSeconds: Double = 0.6

	/// How often the box's rectangle is re-read while she rests on its floor.
	///
	/// That read is the largest single item in a resting frame, and a resting
	/// pet's box is normally still, so paying for it sixty times a second buys
	/// nothing. Half the rate rather than a quarter: the saving falls off
	/// steeply (60 → 30 Hz is most of what 60 → 15 Hz gets) while the delay
	/// before she notices a box that has started moving grows in proportion, and
	/// that delay is the price of this.
	private static let enclosureRestingResampleInterval: Double = 1.0 / 30

	private let displayScale: Double = 1
	private var timer: Timer?
	private var lastTick: CFAbsoluteTime = 0
	private var heartbeatRemaining: Double = 10
	private var lastNotifiedFoot: PixelPoint?
	private var lastNotifiedSize: Double?
	private var dragRefreshRemaining: Double = 0
	private static let dragSurfaceRefreshInterval: Double = 2
	private var fallRefreshRemaining: Double = 0
	private var lastFallRefreshFootY: Double = 0
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
	private var fallRefreshInterval: Double = 0.25
	private var fallRefreshDistance: Double = 100
	/// How many simulation ticks and graph rebuilds the current fall has cost.
	///
	/// Sampling counts cannot be used as a denominator — a symbol that is cheap is
	/// under-sampled, so the denominator moves with the thing being measured. These are
	/// exact, and the rebuild count is what says whether a lower rate was actually
	/// achieved.
	private var fallTickCount = 0
	private var fallRefreshCount = 0
	/// Collapses a run of catches by one window into a single line.
	///
	/// A window rising into her is caught **every frame** while it keeps rising, and a log
	/// line costs about 45 us — measured, not guessed — so a run of them is worth real
	/// CPU. What is worth recording is that the catch happened, by which window and at
	/// what speed, and that is the same for every frame of the run.
	private var caughtLogGate = ChangeGate<UInt32>()

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
			displaySpace.displays.first?.visibleFrame ?? PixelRect(x: 0, y: 0, width: 1440, height: 900)
		self.foot = PixelPoint(x: home.centerX, y: home.bottom)
		self.idleRemaining = Double.random(in: 0.5...1.6, using: &random)

		animator.delegate = self
		animator.play("idle")
	}

	// MARK: - Lifecycle

	public func start() {
		guard timer == nil else { return }
		lastTick = CFAbsoluteTimeGetCurrent()
		// `.common` keeps the pet animating while a menu or a drag loop runs.
		let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.tick() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
		if let frame = animator.currentFrame {
			delegate?.petController(self, didProduceFrame: frame)
		}
	}

	public func stop() {
		timer?.invalidate()
		timer = nil
		try? lifeStore.save(life)
	}

	private func tick() {
		let now = CFAbsoluteTimeGetCurrent()
		let elapsed = now - lastTick
		lastTick = now
		// A paused app must not fast-forward the simulation.
		step(min(max(elapsed, 0), 0.1))
	}

	private func step(_ delta: Double) {
		let timing = FrameTiming.fromElapsed(delta)
		let simulation = timing.simulationSeconds
		guard simulation > 0 else { return }

		life.advance(elapsedSeconds: simulation, sleeping: state == .sleeping)
		stateElapsed += simulation

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
		// floating bug this heartbeat exists to catch (see TODO.md §1).
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

	/// The panel follows the simulation, so every place that moves the foot or
	/// changes the size must go through here — a drag updates the foot *between*
	/// ticks, where a change made during `step()` would never be noticed.
	private func notifyPlacementIfChanged() {
		guard lastNotifiedFoot != foot || lastNotifiedSize != petSize else { return }
		lastNotifiedFoot = foot
		lastNotifiedSize = petSize
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
			// Standing on a window top, she may instead decide to climb higher.
			if tryBeginClimb() { return }
			beginGroundMove(purpose: .wander)
		case .explore:
			state = .running
			movementPurpose = .explore
			stateElapsed = 0
			beginGroundMove(purpose: .explore)
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

	// MARK: - Meals and icon licks

	/// Where a canvas anchor sits on screen for the pet's current size.
	private var canvasScale: Double { petSize / SpriteGeometry.canvasSize }

	private func screenPoint(canvasX: Double, canvasY: Double) -> PixelPoint {
		PixelPoint(
			x: foot.x + (canvasX - profile.geometry.footCanvasX) * canvasScale,
			y: foot.y + (canvasY - profile.geometry.footCanvasY) * canvasScale
		)
	}

	/// The rectangle she can be hit in, in global top-left coordinates.
	///
	/// The feet are deliberately outside it, so standing on a window's top edge can
	/// never be mistaken for that window's side edge sweeping through her.
	private func bodyRect(bottomCanvasY: Double? = nil) -> PixelRect {
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
		lastPerchOffset = nil
		surfaceProvider.rebaselineBodySamples()
		enclosureResampleRemaining = 0
		enclosureBoxAgeSeconds = 0
		if let current = enclosure, let box = liveBounds(of: current.windowID) {
			enclosure?.previousBox = box
		}
	}

	// MARK: - Window enclosure

	/// The window's rectangle right now, read fresh.
	///
	/// The graph lags by up to half a second, which inside a box is the difference
	/// between being carried by a wall and being punched through it, so the walls
	/// come from the window server — the same single-window query the ride uses.
	/// ``updateWindowEnclosure(_:)`` decides how often that has to happen.
	private func liveBounds(of windowID: UInt32) -> PixelRect? {
		if let debugLiveWindowBoundsOverride { return debugLiveWindowBoundsOverride(windowID) }
		return WindowSurfaceProvider.liveBounds(of: windowID)
	}

	/// Whether the box still holds her, leaving it if it does not.
	///
	/// The capacity rule, shared with entry through the same wall inset: a box big
	/// enough for her when she goes in is big enough until it — or she — is
	/// resized. Where she is *inside* it is ``WindowEnclosurePhysics/resolve``'s
	/// business, not this one's, so a window being dragged can never trip it.
	///
	/// `box` is the rectangle the caller already read this frame. Reading it again
	/// here was a second window-server round trip per frame, and inside a box it was
	/// the largest single item in the whole simulation step — larger than everything
	/// the enclosure does with it.
	private func enclosureFitsTheBox(_ box: PixelRect?) -> Bool {
		guard enclosure != nil else { return true }
		guard let box else {
			surrenderEnclosure(reason: "WindowUnavailable")
			beginFall(
				reason: "EnclosureWindowLost",
				initialVelocityY: velocity.y,
				initialVelocityX: velocity.x
			)
			return false
		}
		guard
			WindowEnclosurePhysics.boxHasRoom(
				for: bodyRect(),
				in: box,
				inset: WindowEnclosurePhysics.wallInset * displayScale
			)
		else {
			surrenderEnclosure(reason: "BoxTooSmall")
			beginFall(reason: "EnclosureTooSmall")
			return false
		}
		return true
	}

	/// The same check for callers that do not already have the rectangle, which are
	/// the ones outside the per-frame path.
	private func enclosureFitsTheBox() -> Bool {
		guard let current = enclosure else { return true }
		return enclosureFitsTheBox(liveBounds(of: current.windowID))
	}

	/// Steps her as a free body inside the window's walls.
	///
	/// Returns true while the box holds her, which is the signal to skip the whole
	/// terrain path for this frame: inside a box its four walls are the world.
	private func updateWindowEnclosure(_ delta: Double) -> Bool {
		guard let current = enclosure, !isDragging else {
			enclosureBoxAgeSeconds = 0
			return false
		}

		// The walls come from the window server, as the same single-window query the
		// ride uses, so they follow a dragged window exactly. A resting pet's box is
		// normally still, though, and that read is the largest single cost in the
		// frame — so while she rests it runs 30 times a second instead of 60. The
		// full rate comes back on the first read that shows the box moving.
		enclosureResampleRemaining -= delta
		let skippedRead = current.isResting && enclosureResampleRemaining > 0

		let box: PixelRect
		if skippedRead {
			// Nothing has been seen moving it, so the rectangle she was given last is
			// still the truth about the walls.
			box = current.previousBox
		} else {
			guard let fresh = liveBounds(of: current.windowID) else {
				enclosureBoxAgeSeconds = 0
				let velocityY = velocity.y
				let velocityX = velocity.x
				surrenderEnclosure(reason: "WindowUnavailable")
				beginFall(
					reason: "EnclosureWindowLost",
					initialVelocityY: velocityY,
					initialVelocityX: velocityX
				)
				return false
			}
			box = fresh
		}
		let moved = box != current.previousBox

		let scale = displayScale
		let step = WindowEnclosurePhysics.resolve(
			pet: bodyRect(),
			previousBox: current.previousBox,
			currentBox: box,
			baselineSeconds: enclosureBoxAgeSeconds,
			velocityX: velocity.x,
			velocityY: velocity.y,
			wasOnFloor: current.isResting,
			elapsedSeconds: delta,
			scale: scale
		)
		enclosure?.previousBox = box
		enclosureBoxAgeSeconds = skippedRead ? enclosureBoxAgeSeconds + delta : delta

		// She is worth reading every frame while she is not resting, and while the
		// box is moving under her. Anything else earns the slower clock again.
		if !skippedRead {
			enclosureResampleRemaining =
				step.isResting && !moved ? Self.enclosureRestingResampleInterval : 0
		}
		velocity = PixelPoint(x: step.velocityX, y: step.velocityY)

		let movementX = SubpixelMotion.takeWholePixels(step.offsetX, remainder: &remainderX)
		let movementY = SubpixelMotion.takeWholePixels(step.offsetY, remainder: &remainderY)
		// A wall absorbs whatever subpixel drift was in flight, so a bounce does
		// not carry a stale fraction through the impact.
		if step.hitHorizontal { remainderX = 0 }
		if step.hitVertical { remainderY = 0 }
		foot.x += Double(movementX)
		foot.y += Double(movementY)

		if abs(velocity.x) > 8 { facing = velocity.x < 0 ? -1 : 1 }

		// The floor's own answer is the truth about whether she is standing on it.
		// Reading it back only when she happened to be moving fast enough left her
		// "resting" for ever after a yank that gave her no speed of her own — a
		// downward one — so the floor went on carrying her for the whole drag
		// instead of dropping away from her.
		let wasResting = current.isResting
		enclosure?.isResting = step.isResting

		if step.hitAny, step.impactSpeed >= 70 * scale {
			state = .falling
			stateElapsed = 0
			animator.play(velocity.y < -40 * scale ? "toss" : "fall")
			DiagnosticsLog.shared.writeEvent(
				"WindowEnclosureImpact",
				[
					("Window", "\(current.windowID)"),
					("Walls", "L=\(step.hitLeft),T=\(step.hitTop),R=\(step.hitRight),B=\(step.hitBottom)"),
					("ImpactSpeed", String(format: "%.0f", step.impactSpeed)),
				]
			)
			announce(.platformLaunch, voice: .scream, priority: .important)
		} else if step.isResting, !wasResting {
			state = .idle
			stateElapsed = 0
			animator.play("idle")
			DiagnosticsLog.shared.writeEvent(
				"WindowEnclosureSettled",
				[("Window", "\(current.windowID)")]
			)
		} else if !step.isResting {
			// Nothing holds her: the box was yanked, or the walls are only shutting
			// her in loosely. Either way she is a falling body inside it.
			state = .falling
			if animator.currentClip != "toss", animator.currentClip != "fall" {
				animator.play(velocity.y < 0 ? "toss" : "fall")
			}
		}

		// The capacity question — "is this box still big enough for her" — is asked
		// here rather than before ``resolve``. It is about size and not position, so
		// the order cannot change the answer; it sits at the end because the walls
		// had to run first to have a box at all. It reuses the rectangle read at the
		// top of this method.
		guard enclosureFitsTheBox(box) else { return true }

		// A box covered by a window in front of it is no longer a place she can be
		// seen standing in. Held for a moment first, because switching apps covers
		// a window and then uncovers it again.
		guard let cover = surfaceProvider.coveringWindow(of: current.windowID, body: bodyRect())
		else {
			enclosureCoveredSeconds = 0
			return true
		}
		enclosureCoveredSeconds += delta
		guard enclosureCoveredSeconds >= Self.enclosureCoverageGraceSeconds else { return true }

		// What is now in front of her could have held her had she been let go
		// inside it, so it does. She stays in play on the window the user is
		// actually looking at, instead of dropping out to the desktop.
		//
		// Checked against the container candidates, not against every body: the
		// window covering her may have no room for her at all — filling the display,
		// say — and moving her into it would seal her against the screen.
		if let bounds = surfaceProvider.windowBodies.enclosureCandidates[cover]?.bounds,
			WindowEnclosurePhysics.bodyFits(
				bodyRect(),
				in: bounds,
				inset: WindowEnclosurePhysics.wallInset * scale
			)
		{
			transferEnclosure(to: cover, bounds: bounds)
			return true
		}

		surrenderEnclosure(reason: "EnclosureCovered")
		beginFall(reason: "EnclosureCovered")
		return true
	}

	/// Hands her to the window that was covering the one she was in.
	///
	/// She is already drawn on top of that window and already between its walls,
	/// so this moves no pixel: only which rectangle the walls come from. Her
	/// velocity carries over, so whatever she was doing continues — a walk she was
	/// resting from simply falls to the new floor.
	private func transferEnclosure(to windowID: UInt32, bounds: PixelRect) {
		let from = enclosure?.windowID
		enclosure = Enclosure(windowID: windowID, previousBox: bounds, isResting: false)
		// The next cover earns its own grace rather than inheriting this one.
		enclosureCoveredSeconds = 0
		enclosureBoxAgeSeconds = 0
		DiagnosticsLog.shared.writeEvent(
			"WindowEnclosureTransferred",
			[("From", from.map(String.init) ?? "none"), ("To", "\(windowID)")]
		)
	}

	/// Puts her inside a window when she is let go wholly within one.
	///
	/// Stricter than the original, which asked only for her *centre* to be inside.
	/// A body hanging out of the frame would be visibly half in and half out, and
	/// the walls would shove her on the very first frame.
	///
	/// The **frontmost** window her body fits in is the one that takes her, since
	/// that is the one she is visibly standing inside. Choosing by size instead let
	/// a small window *behind* a larger one capture her, and the occlusion rule then
	/// handed her straight on to the larger one — two captures in a row, which reads
	/// as falling twice. Whether a window may hold her at all was decided when it
	/// was sampled.
	private func tryBeginWindowEnclosure(velocityX: Double, velocityY: Double) -> Bool {
		let body = bodyRect()
		let inset = WindowEnclosurePhysics.wallInset * displayScale
		let holders = surfaceProvider.windowBodies.enclosureCandidates.filter {
			WindowEnclosurePhysics.bodyFits(body, in: $0.value.bounds, inset: inset)
		}
		guard let fitted = holders.min(by: { $0.value.zIndex < $1.value.zIndex }) else {
			return false
		}

		// A window top between her feet and the box's floor is a landing, not a
		// reason to be swallowed whole: she comes down on it as she would anywhere
		// else, and only a box with nothing inside it to land on takes her in.
		//
		// Without this she fell straight past a window in front of the one holding
		// her — dropped above a small window while inside a large one, she went into
		// the large one and came to rest on its floor instead of on the small
		// window's top edge.
		let floor = fitted.value.bounds.bottom - inset
		guard
			surfaceProvider.landingSurface(
				footX: foot.x,
				fromY: foot.y,
				toY: floor,
				inset: Motion.landingInset
			) == nil
		else { return false }

		enclosure = Enclosure(
			windowID: fitted.key,
			previousBox: fitted.value.bounds,
			isResting: false
		)
		airborneSupportWindowID = nil
		airborneSupportTop = nil
		movementPurpose = .none
		state = .falling
		stateElapsed = 0
		velocity = PixelPoint(x: velocityX, y: velocityY)
		remainderX = 0
		remainderY = 0
		ignoredLandingWindow = nil
		ignoredLandingSeconds = 0
		enclosureCoveredSeconds = 0
		enclosureBoxAgeSeconds = 0
		releasePerch()
		animator.play(velocityY < -1 ? "toss" : "fall")
		DiagnosticsLog.shared.writeEvent(
			"WindowEnclosureEntered",
			[
				("Window", "\(fitted.key)"),
				(
					"Bounds",
					"\(Int(fitted.value.bounds.left)),\(Int(fitted.value.bounds.top)),\(Int(fitted.value.bounds.right)),\(Int(fitted.value.bounds.bottom))"
				),
				("Velocity", String(format: "%.0f,%.0f", velocityX, velocityY)),
			]
		)
		return true
	}

	/// Leaves the box without deciding what happens next.
	private func surrenderEnclosure(reason: String) {
		guard let current = enclosure else { return }
		enclosure = nil
		movementPurpose = .none
		DiagnosticsLog.shared.writeEvent(
			"WindowEnclosureReleased",
			[("Window", "\(current.windowID)"), ("Reason", reason)]
		)
	}

	/// Leaves the box to go and eat, through whichever wall faces the food.
	private func releaseEnclosureForMeal(target: PixelPoint) {
		guard let current = enclosure else { return }
		let body = bodyRect()
		let deltaX = target.x - body.centerX
		let deltaY = target.y - body.centerY
		let exitSide =
			abs(deltaX) >= abs(deltaY)
			? (deltaX < 0 ? "Left" : "Right")
			: (deltaY < 0 ? "Top" : "Bottom")
		surrenderEnclosure(reason: "MealEscape")
		DiagnosticsLog.shared.writeEvent(
			"WindowEnclosureMealEscape",
			[
				("Window", "\(current.windowID)"),
				("ExitSide", exitSide),
				("Target", "\(Int(target.x)),\(Int(target.y))"),
			]
		)
	}

	// MARK: - Window side impact

	/// A window's left or right edge sweeping sideways through her body throws her
	/// clear of it, rather than passing through her.
	private func updateWindowSideCollisions() {
		let version = surfaceProvider.bodyRefreshVersion
		guard version != processedBodyRefreshVersion else { return }
		processedBodyRefreshVersion = version

		guard enclosure == nil, !isDragging, state != .dragging, sideImpactCooldown <= 0
		else { return }

		let elapsed = surfaceProvider.bodySampleElapsed
		let body = bodyRect()
		var strongest: (id: UInt32, impact: WindowSideImpact)?

		for (windowID, current) in surfaceProvider.windowBodies {
			guard current.isEnclosureCandidate else { continue }
			guard let previous = surfaceProvider.previousWindowBodies[windowID],
				previous.isEnclosureCandidate
			else { continue }
			guard
				let impact = WindowSideCollisionPolicy.resolve(
					previous: previous.bounds,
					current: current.bounds,
					pet: body,
					elapsedSeconds: elapsed,
					scale: displayScale
				)
			else { continue }
			if strongest == nil
				|| abs(impact.edgeVelocityX) > abs(strongest!.impact.edgeVelocityX)
			{
				strongest = (windowID, impact)
			}
		}

		guard let strongest else { return }
		sideImpactCooldown = Self.sideImpactCooldownSeconds
		ignoredLandingWindow = strongest.id
		ignoredLandingSeconds = Self.sideImpactLandingGraceSeconds
		DiagnosticsLog.shared.writeEvent(
			"WindowSideImpact",
			[
				("Window", "\(strongest.id)"),
				("Direction", "\(strongest.impact.direction)"),
				("EdgeVelocityX", String(format: "%.0f", strongest.impact.edgeVelocityX)),
				("PetVelocityX", String(format: "%.0f", strongest.impact.petVelocityX)),
				("PetVelocityY", String(format: "%.0f", strongest.impact.petVelocityY)),
			]
		)
		announce(.platformLaunch, voice: .scream, priority: .critical)
		beginFall(
			reason: "WindowSideImpact",
			initialVelocityY: strongest.impact.petVelocityY,
			initialVelocityX: strongest.impact.petVelocityX
		)
	}

	private static let sideImpactCooldownSeconds: Double = 0.32
	private static let sideImpactLandingGraceSeconds: Double = 0.48

	// MARK: - State dispatch

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
	private var mouthPoint: PixelPoint {
		screenPoint(
			canvasX: profile.geometry.mouthCanvasX,
			canvasY: profile.geometry.mouthCanvasY
		)
	}

	private var lickPoint: PixelPoint {
		screenPoint(
			canvasX: profile.geometry.lickContactCanvasX,
			canvasY: profile.geometry.lickContactCanvasY
		)
	}

	/// Accepts deleted items, subject to the mode and queue limits, then starts
	/// eating if she is free.
	@discardableResult
	public func enqueueMeals(_ items: [DeletedItem]) -> Int {
		guard profile.supportsFood, PetModePolicy.allowsDeletionMeal(quietMode: quietMode) else {
			return 0
		}

		var accepted = 0
		for item in items {
			guard
				MealQueuePolicy.canAcceptDeletion(
					queuedCount: mealQueue.count,
					hasActiveDeletionMeal: activeMeal != nil
				)
			else {
				DiagnosticsLog.shared.writeEvent("MealQueueFull", [("Dropped", "1")])
				break
			}
			mealQueue.enqueue(item)
			accepted += 1
		}
		guard accepted > 0 else { return 0 }

		if burstTracker.register(detectedAt: Date()) {
			announce(.buffet, voice: .positive, priority: .important)
		} else {
			announce(.mealSpotted, voice: .question, priority: .normal)
		}

		// Being inside a window is no reason to sit out a meal: she leaves through
		// whichever wall faces the food and runs to it.
		let escaping = WindowEnclosureBehaviorPolicy.shouldEscapeForMeal(
			isEnclosed: enclosure != nil,
			pendingMeals: mealQueue.count
		)
		guard activeMeal == nil else { return accepted }
		if escaping {
			_ = beginNextMeal()
			return accepted
		}
		// A meal is not something she sleeps through: she is woken for it. The
		// other steps she can be interrupted at are the ones she is not already
		// busy eating in.
		switch state {
		case .sleeping:
			beginWake(forMeal: true)
		case .waking:
			wakeForMeal = true
		case .idle, .curious, .licking:
			_ = beginNextMeal()
		case .running where movementPurpose != .meal:
			_ = beginNextMeal()
		default:
			break
		}
		return accepted
	}

	/// Starts walking to the next queued meal. Returns false when there is none.
	@discardableResult
	private func beginNextMeal() -> Bool {
		guard activeMeal == nil, !quietMode else { return false }
		guard let item = mealQueue.dequeue() else { return false }

		wakeForMeal = false
		releaseEnclosureForMeal(target: item.anchor)
		activeMeal = item
		targetPoint = item.anchor
		state = .running
		movementPurpose = .meal
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		remainderY = 0
		animator.play("run")
		mealDelegate?.petController(self, didBeginMeal: item)
		DiagnosticsLog.shared.writeEvent(
			"MealRunStarted",
			[
				("Name", item.displayName),
				("Target", "\(Int(item.anchor.x)),\(Int(item.anchor.y))"),
			]
		)
		return true
	}

	/// Sends her to lick an icon when she is hungry but has nothing to eat.
	///
	/// - Parameter ignoringQuietMode: quiet mode is meant to stop this — the original's
	///   own menu item returns silently when it is on — so nothing that speaks for the
	///   user passes this. It is for the launch-argument demo, which has been asked for
	///   explicitly and has no other way to be seen.
	@discardableResult
	public func tryBeginIconLick(manual: Bool, ignoringQuietMode: Bool = false) -> Bool {
		guard profile.supportsFood, ignoringQuietMode || !quietMode else { return false }
		guard WindowEnclosureBehaviorPolicy.allowsIconLick(isEnclosed: enclosure != nil) else {
			DiagnosticsLog.shared.writeEvent(
				"IconLickSuppressedInEnclosure",
				[("Manual", "\(manual)")]
			)
			return false
		}

		let display = displaySpace.display(containing: foot) ?? displaySpace.displays.first
		guard let workArea = display?.visibleFrame else { return false }
		// The real Finder positions when Accessibility allows them; otherwise the
		// Finder-default layout approximation, which is not where the icons are.
		let realIcons = desktopIcons?.positions ?? []
		let candidates =
			realIcons.isEmpty ? DesktopIconGrid.positions(count: 12, in: workArea) : realIcons
		guard
			let target = IconLickTargetSelector.choose(
				candidates: candidates,
				origin: lickPoint,
				randomUnit: Double.random(in: 0..<1, using: &random)
			)
		else { return false }

		targetPoint = target
		state = .running
		movementPurpose = .iconLick
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		remainderY = 0
		animator.play("run")
		announce(
			manual ? .manualIconLick : .curiousIconLick,
			voice: manual ? .aggrieved : .question,
			priority: manual ? .important : .normal
		)
		return true
	}

	/// Walks in two dimensions to a free-standing target (a meal or an icon).
	private func updateMealRun(_ delta: Double) {
		let isMeal = movementPurpose == .meal
		let contact = isMeal ? mouthPoint : lickPoint

		let deltaX = targetPoint.x - contact.x
		let deltaY = targetPoint.y - contact.y
		let distance = (deltaX * deltaX + deltaY * deltaY).squareRoot()

		if distance < 18 || stateElapsed > 6.5 {
			foot.x += deltaX
			foot.y += deltaY
			if isMeal {
				beginChomp()
			} else {
				beginLickAnimation()
			}
			return
		}

		let speed =
			min(max(distance * 3.2, 250), isMeal ? 720 : 640) * displayScale
			* profile.movementSpeedMultiplier
		let desiredX = deltaX / distance * speed
		let desiredY = deltaY / distance * speed
		let response = min(1, delta * 7.5)
		velocity.x += (desiredX - velocity.x) * response
		velocity.y += (desiredY - velocity.y) * response

		let movementX = SubpixelMotion.takeWholePixels(velocity.x * delta, remainder: &remainderX)
		let movementY = SubpixelMotion.takeWholePixels(velocity.y * delta, remainder: &remainderY)
		foot.x += Double(movementX)
		foot.y += Double(movementY)
		if abs(velocity.x) > 8 { facing = velocity.x < 0 ? -1 : 1 }
	}

	private func beginChomp() {
		state = .chomping
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		remainderY = 0
		facing = 1
		animator.play("chomp")
		if let item = activeMeal, !item.exactAnchor {
			announce(.suction, voice: .positive, priority: .normal)
		}
	}

	private func beginLickAnimation() {
		state = .licking
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		remainderY = 0
		animator.play("lick")
	}

	private func beginHungryPlea() {
		state = .rolling
		movementPurpose = .none
		stateElapsed = 0
		transientDuration = 1.6
		velocity = .zero
		animator.play("hungry")
		announce(.hungryRoll, voice: .sad, priority: .important)
	}

	private func beginRoll() {
		state = .rolling
		movementPurpose = .none
		stateElapsed = 0
		transientDuration = animator.durationSeconds
		velocity = .zero
		animator.play("roll")
		announce(.hungryRoll, voice: .sad, priority: .important)
	}

	private func reportMealVisual() {
		guard state == .chomping, let item = activeMeal else { return }
		let geometry = profile.geometry
		var visual = MealConsumptionAnimation.visual(
			elapsed: stateElapsed,
			from: PixelPoint(x: geometry.mouthCanvasX, y: geometry.mouthCanvasY),
			to: PixelPoint(
				x: geometry.suctionMouthCanvasX,
				y: geometry.suctionMouthCanvasY
			)
		)
		// The path is authored in canvas units; the presenter draws in screen points.
		visual.center = screenPoint(canvasX: visual.center.x, canvasY: visual.center.y)
		mealDelegate?.petController(self, didUpdateMeal: item, visual: visual)
	}

	/// Turns an interrupted meal back into a queued one rather than losing it.
	///
	/// `reason` is only for the log: from the outside, a meal she abandoned and a
	/// meal she never went for look exactly the same.
	private func requeueActiveMeal(reason: String) {
		guard let item = activeMeal else { return }
		mealQueue.requeueAtFront(item)
		activeMeal = nil
		mealDelegate?.petController(self, didFinishMeal: item)
		DiagnosticsLog.shared.writeEvent(
			"MealRequeued",
			[("Name", item.displayName), ("Reason", reason)]
		)
	}

	private func completeActiveMeal() {
		guard let item = activeMeal else { return }
		activeMeal = nil

		life.registerMeal(
			path: item.originalPath,
			nourishment: Double.random(in: 6...14, using: &random)
		)
		persistLifeStateQuietly()
		mealDelegate?.petController(self, didFinishMeal: item)

		let stuffed = life.hunger <= 2
		announce(
			stuffed ? .stuffed : .tastedItem,
			voice: .affirmative,
			priority: .normal,
			itemName: item.displayName
		)

		state = .satisfied
		movementPurpose = .none
		stateElapsed = 0
		transientDuration = animator.durationSeconds
		velocity = .zero
		animator.play(stuffed ? "satisfied" : "satisfied_quick")
		DiagnosticsLog.shared.writeEvent(
			"MealCompleted",
			[
				("Name", item.displayName),
				("Hunger", String(format: "%.1f", life.hunger)),
				("Queued", "\(mealQueue.count)"),
			]
		)
	}

	/// What to do once a meal finishes: carry on down the queue, or settle.
	private func advanceAfterMeal() {
		if !mealQueue.isEmpty, beginNextMeal() { return }
		returnToIdle()
	}

	private func persistLifeStateQuietly() {
		try? lifeStore.save(life)
	}

	private func returnToIdle() {
		state = .idle
		movementPurpose = .none
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		wakeForMeal = false
		animator.play("idle")
		resetIdleTimer()
	}

	// MARK: - Ground movement

	private func beginGroundMove(purpose: MovementPurpose) {
		guard let surface = surfaceProvider.support(at: foot) else {
			beginFall()
			return
		}
		let run = perch.flatMap { surface.visibleRun(containingT: $0.t) } ?? surface.span
		let inset = 20 * displayScale
		let minimum = run.start + inset
		let maximum = max(minimum, run.end - inset)
		targetX = Double.random(in: minimum...maximum, using: &random)
		movementPurpose = purpose
		state = .running
		stateElapsed = 0
		animator.play("walk")
	}

	private func updateRunning(_ delta: Double) {
		// A meal or an icon lick is a free-standing two-dimensional walk.
		if movementPurpose == .meal || movementPurpose == .iconLick {
			updateMealRun(delta)
			return
		}

		guard let surface = perchSurface, let perched = perch,
			let run = surface.visibleRun(containingT: perched.t)
		else {
			beginFall()
			return
		}

		// Her feet are already on the ledge: the ride snaps her to it every frame,
		// so nothing further is needed here for vertical movement.
		targetX = min(max(targetX, run.start + 20), run.end - 20)
		let deltaX = targetX - foot.x
		if abs(deltaX) <= Motion.arrivalTolerance || stateElapsed > Motion.movementTimeout {
			foot.x += deltaX
			finishGroundMove()
			return
		}

		let speed =
			(movementPurpose == .explore ? Motion.exploreSpeed : Motion.walkSpeed)
			* displayScale * profile.movementSpeedMultiplier
		let desiredVelocity = (deltaX < 0 ? -1.0 : 1.0) * speed
		velocity.x += (desiredVelocity - velocity.x) * min(1, delta * Motion.groundResponse)

		var movementX = SubpixelMotion.takeWholePixels(velocity.x * delta, remainder: &remainderX)
		if Double(abs(movementX)) > abs(deltaX) {
			movementX = Int(deltaX.rounded())
		}
		foot.x += Double(movementX)
		// Fold her own walking back into the anchor, so the next tick's ride starts
		// from where she actually is.
		self.perch?.t = surface.t(atCoordinate: foot.x)
		facing = deltaX < 0 ? -1 : 1
	}

	/// States in which the pet is on the ground and should therefore ride whatever
	/// she is standing on.
	///
	/// Excluded on purpose: airborne and user-carried states; the scripted climb;
	/// the free-standing walks to a meal or an icon, which leave the surface
	/// behind and would otherwise be mistaken for a lost support; and the eating
	/// poses, which happen wherever the food was.
	private var ridesSupport: Bool {
		if movementPurpose == .meal || movementPurpose == .iconLick { return false }
		switch state {
		case .falling, .climbing, .dragging, .pinching,
			.chomping, .licking, .satisfied, .rolling, .waking:
			return false
		default:
			return true
		}
	}

	/// Keeps her attached to her support: follows it, is released by it, or falls
	/// when it goes away.
	private func maintainGroundSupport(_ delta: Double) {
		guard ridesSupport else { return }

		guard let perch else {
			acquirePerch()
			return
		}

		// She has left the edge she was anchored to: a walk to a meal or an icon
		// moves her feet off the surface without ever going through `beginFall`, so
		// the ride would otherwise write her back onto it. `lastPerchOffset` is where
		// the ride last put her, which is what makes this a question about her own
		// movement — a surface carrying her along reads as no drift at all, however
		// fast it is dragged.
		if let lastPerchOffset, abs(foot.y - lastPerchOffset) > Motion.perchDriftTolerance {
			guard let nearby = surfaceProvider.support(at: foot) else {
				handlePerchLost(delta: delta, reason: "off-perch")
				return
			}
			DiagnosticsLog.shared.writeEvent(
				"PerchReanchored",
				[
					("From", "\(perch.key.kind.rawValue):\(perch.key.owner)"),
					("To", "\(nearby.key.kind.rawValue):\(nearby.key.owner)"),
					("Foot", "\(Int(foot.x)),\(Int(foot.y))"),
				]
			)
			perchUnavailableSeconds = 0
			isInPerchGrace = false
			adopt(nearby)
			// Returned rather than falling through: `perch` is the edge she just left,
			// and the ride at the end of this function would put her back on it.
			return
		}

		// A missing, unreachable, or now-covered spot is a lost perch. The grace
		// covers a window that briefly vanishes from the window server's list. Each
		// condition is told apart here because they mean different things when a perch
		// is lost unexpectedly.
		guard let surface = currentSurface(for: perch) else {
			handlePerchLost(delta: delta, reason: "surface-gone")
			return
		}
		guard surface.isReachable else {
			handlePerchLost(delta: delta, reason: "unreachable")
			return
		}
		guard isPerchSpotVisible(perch) else {
			// Logged with the graph's own answer, because "covered" is the one perch
			// failure that cannot be seen from the outside: she is drawn over everything,
			// so a spot the graph calls covered and a spot nothing covers look identical
			// on screen. The runs and the windows in front are the only way to tell which
			// window the graph thinks is over her, and whether the edge it measured is the
			// one she is actually on.
			DiagnosticsLog.shared.writeEvent(
				"PerchCovered",
				[
					("Foot", "\(Int(foot.x)),\(Int(foot.y))"),
					("PerchT", String(format: "%.3f", perch.t)),
					("GraphTop", String(format: "%.1f", lastPerchOffset ?? -1)),
					("GraphSpan", Self.describe(surfaceProvider.surfaces, id: perch.key.owner)),
					("InFront", Self.describeBodies(surfaceProvider, inFrontOf: perch.key.owner)),
				]
			)
			handlePerchLost(delta: delta, reason: "covered")
			return
		}

		perchUnavailableSeconds = 0
		isInPerchGrace = false
		perchSurface = surface

		// The one explicit release rule: a surface that moves further than
		// `releaseDisplacement` in a single tick is yanked out from under her.
		let displacement = lastPerchOffset.map { surface.offset - $0 } ?? 0
		lastPerchOffset = surface.offset

		if abs(displacement) >= PlatformRidePhysics.releaseDisplacement {
			let velocityY = displacement / max(delta, 1.0 / 240)
			let upward = displacement < 0
			logRide(
				upward ? .launchUpward : .releaseDownward,
				displacement: displacement,
				velocityY: velocityY,
				surface: surface
			)
			releasePerch()
			// The window moved out from under her rather than her being thrown by
			// the user, so it is worth following for a moment: a ledge rising faster
			// than she flies would otherwise overtake her, swallow her, and drop her
			// past itself to the floor. Captured before `beginFall`, which clears it
			// for every other reason.
			let yankedWindowID = surface.key.kind == .windowTop ? surface.key.owner : nil
			if upward {
				// Thrown up, inheriting a fraction of the surface's speed.
				let initial = min(max(velocityY * 0.88, -1150 * displayScale), -300 * displayScale)
				DiagnosticsLog.shared.writeEvent(
					"PlatformLaunch",
					[
						("PetVelocityY", String(format: "%.0f", initial))
					]
				)
				announce(.platformLaunch, voice: .scream, priority: .critical)
				beginFall(reason: "PlatformLaunch", initialVelocityY: initial)
			} else {
				// Left behind rather than thrown down: she falls from rest and lands
				// on the ledge as it comes back up.
				beginFall(reason: "PlatformDownwardRelease")
			}
			airborneSupportWindowID = yankedWindowID
			airborneSupportTop = surface.offset
			return
		}

		if abs(displacement) >= 0.5 {
			logRide(
				.follow,
				displacement: displacement,
				velocityY: displacement / max(delta, 1.0 / 240),
				surface: surface
			)
		}

		// The ledge carries her, whether she is walking, standing or asleep.
		foot = perch.position(in: surface)
	}

	private func logRide(
		_ response: PlatformMotionResponse,
		displacement: Double,
		velocityY: Double,
		surface: Surface
	) {
		guard perchLogGate.emits(response) else { return }
		DiagnosticsLog.shared.writeEvent(
			"PlatformRide",
			[
				("Response", "\(response)"),
				("DisplacementY", String(format: "%.1f", displacement)),
				("VelocityY", String(format: "%.0f", velocityY)),
				("Top", String(format: "%.1f", surface.offset)),
				("Foot", "\(Int(foot.x)),\(Int(foot.y))"),
			]
		)
	}

	/// The window's top edge as it is right now.
	///
	/// The graph lags by up to half a second, which is the difference between
	/// riding a window and being punched through it, so anything that has to know
	/// where a window *is* reads it here — the same single-window query throughout.
	private func liveSurface(of windowID: UInt32) -> Surface? {
		if let debugLiveWindowSurfaceOverride { return debugLiveWindowSurfaceOverride(windowID) }
		return WindowSurfaceProvider.liveWindowSurface(
			windowID: windowID,
			monitors: displaySpace.displays
		)
	}

	/// The surface a perch points at, read fresh.
	///
	/// A window is resolved **by identity** from the window server, never by
	/// proximity: a dragged window leaves a proximity lookup behind within a frame,
	/// which would read as losing her support instead of riding it. The live read
	/// also comes first because the graph lags by up to half a second. A floor never
	/// moves, so the graph is the truth for it.
	private func currentSurface(for perch: Perch) -> Surface? {
		switch perch.key.kind {
		case .windowTop:
			// The live read gives the drag its precision; the graph is the authority
			// on whether the surface still exists at all.
			return liveSurface(of: perch.key.owner)
				?? surfaceProvider.surfaces.first { $0.key == perch.key }
		default:
			return surfaceProvider.surfaces.first { $0.key == perch.key }
		}
	}

	/// Whether the graph says a spot on an edge is clear of anything in front of it.
	///
	/// A live read cannot answer this: it reports the whole edge and does not recompute
	/// occlusion, so it would call every spot clear.
	private func isSpotVisible(
		for key: SurfaceKey,
		atCoordinate x: Double,
		inset: Double
	) -> Bool {
		// Not in the graph yet (a window that just appeared). Nothing says it is
		// covered, so let her stand until the next rebuild decides.
		guard let graphSurface = surfaceProvider.surfaces.first(where: { $0.key == key })
		else { return true }
		return graphSurface.isVisible(atCoordinate: x, inset: inset)
	}

	/// The graph's own description of one window's edges: where it is, its span, and the
	/// parts the graph believes are not covered.
	private static func describe(_ surfaces: [Surface], id: UInt32) -> String {
		guard let surface = surfaces.first(where: { $0.key == SurfaceKey(owner: id, kind: .windowTop) })
		else { return "absent" }
		let runs = surface.visible
			.map { "\(Int($0.start))-\(Int($0.end))" }
			.joined(separator: ",")
		return
			"top=\(Int(surface.offset)) span=\(Int(surface.span.start))-\(Int(surface.span.end)) visible=[\(runs)]"
	}

	/// Which windows the body sample puts in front of `owner`, and where they are.
	///
	/// The body sample is what the occlusion *policy* consults, and it runs at 10 Hz
	/// against the graph's 2 Hz, so the two can disagree about the same moment.
	private static func describeBodies(_ provider: SurfaceProvider, inFrontOf owner: UInt32) -> String
	{
		guard let host = provider.windowBodies[owner] else { return "owner-absent" }
		let front = provider.windowBodies
			.filter { $0.key != owner && $0.value.zIndex < host.zIndex }
			.map {
				"\($0.key)@\(Int($0.value.bounds.left)),\(Int($0.value.bounds.top)) \(Int($0.value.bounds.width))x\(Int($0.value.bounds.height))"
			}
		return front.isEmpty ? "none" : front.joined(separator: " ")
	}

	/// Whether the spot she is anchored to is not covered by another window.
	///
	/// Asked of the **graph**, never of the live read: the live read only reports the
	/// window's rectangle, so it would call every spot visible and she would happily
	/// keep standing on an edge another window had just covered.
	///
	/// Asked at her **world** position rather than at the perch's `t` mapped onto this
	/// surface. `t` is taken from whichever surface she landed on, and the live read and
	/// the graph can disagree about a window's span — a window dragged sideways has a
	/// different one in each — so mapping it here would ask about a point she is not
	/// standing on, and answer "covered" for a spot that is clear.
	private func isPerchSpotVisible(_ perch: Perch) -> Bool {
		guard let graphSurface = surfaceProvider.surfaces.first(where: { $0.key == perch.key })
		else {
			// Not in the graph yet (a window that just appeared). Nothing says it is
			// covered, so let her stand until the next rebuild decides.
			return true
		}
		return graphSurface.isVisible(atCoordinate: foot.x)
	}

	/// Picks up a perch for wherever her feet are, or starts a fall.
	private func acquirePerch() {
		guard let surface = surfaceProvider.support(at: foot) else {
			beginFall()
			return
		}
		adopt(surface)
	}

	/// Anchors her to a surface, working out `t` from her feet.
	private func adopt(_ surface: Surface) {
		let perch = Perch.at(foot, on: surface)
		self.perch = perch
		perchSurface = surface
		lastPerchOffset = surface.offset
		perchLogGate.reset()
		foot = perch.position(in: surface)
	}

	private func releasePerch() {
		perch = nil
		perchSurface = nil
		lastPerchOffset = nil
		perchLogGate.reset()
	}

	/// Her perch is gone: the surface vanished, became unreachable, or she is over
	/// a part of it another window now hides. Held briefly while the grace lasts,
	/// because a dragged window can blink out of the window server's list.
	/// - Parameter reason: which condition failed. A perch that goes unexpectedly is
	///   otherwise indistinguishable from one that was covered, vanished, or went out
	///   of reach, and the three have different causes.
	private func handlePerchLost(delta: Double, reason: String) {
		perchUnavailableSeconds += delta

		// The grace is for a dragged window blinking out of the window server's list
		// for a moment. A floor is a property of the display and cannot blink, so
		// holding her over one would only postpone a fall that is already due.
		if perch?.key.kind != .floor,
			PlatformRidePhysics.shouldPreserveTransientSupport(
				unavailableSeconds: perchUnavailableSeconds
			)
		{
			// Logged once per grace period rather than every frame.
			if !isInPerchGrace {
				isInPerchGrace = true
				DiagnosticsLog.shared.writeEvent(
					"PlatformSupportGrace",
					[
						("Footnote", "\(Int(foot.x)),\(Int(foot.y))"),
						("Top", lastPerchOffset.map { String(format: "%.1f", $0) } ?? "none"),
						("Reason", reason),
					]
				)
			}
			return
		}

		releasePerch()
		beginFall()
	}

	private func finishGroundMove() {
		let surface = surfaceProvider.support(at: foot)

		// Climb and descent approaches hand off to their own routines.
		if movementPurpose == .climbApproach, let pendingClimb {
			beginClimb(pendingClimb)
			return
		}
		if movementPurpose == .edgeSlideApproach, let surface {
			beginSlideDown(from: surface)
			return
		}
		if movementPurpose == .edgeJumpApproach, let surface {
			beginJumpDown(from: surface)
			return
		}

		if let surface, surface.key.kind != .floor,
			let action = terrainEdgeActionIfAtEdge(surface)
		{
			switch action {
			case .hop:
				beginHop()
				return
			case .slideDown:
				beginSlideDown(from: surface)
				return
			case .jumpDown:
				beginJumpDown(from: surface)
				return
			case .turnAround:
				beginGroundMove(purpose: .wander)
				return
			}
		}

		state = .curious
		movementPurpose = .none
		stateElapsed = 0
		transientDuration = 0.9
		velocity = .zero
		remainderX = 0
		animator.play("curious")
	}

	/// True when the pet has reached an end of its current platform.
	private func terrainEdgeActionIfAtEdge(_ surface: Surface) -> TerrainEdgeAction? {
		guard let perch, let run = surface.visibleRun(containingT: perch.t) else { return nil }
		let atEdge = foot.x <= run.start + 24 || foot.x >= run.end - 24
		guard atEdge else { return nil }
		return TerrainBehaviorPlanner.chooseAtEdge(
			isDesktopFloor: false,
			randomUnit: Double.random(in: 0..<1, using: &random)
		)
	}

	// MARK: - Falling

	/// The single way into the airborne state.
	///
	/// Everything that leaves the ground must come through here, because this is
	/// what clears the perch: a perch is resolved *by identity*, so a stale one
	/// would pull her back to its edge the moment she landed somewhere else.
	private func beginFall(
		reason: String = "support-lost",
		initialVelocityY: Double = 0,
		initialVelocityX: Double = 0,
		clip: String? = nil,
		purpose: MovementPurpose? = nil
	) {
		state = .falling
		stateElapsed = 0
		fallReason = reason
		fallStartFootY = foot.y
		fallRefreshRemaining = 0
		lastFallRefreshFootY = foot.y
		fallTickCount = 0
		fallRefreshCount = 0
		velocity = PixelPoint(x: initialVelocityX, y: initialVelocityY)
		remainderX = 0
		remainderY = 0
		if let purpose { movementPurpose = purpose }
		// Only a window that moved out from under her is worth following: a throw by
		// the user has put her somewhere else on purpose, and a catch-up would pin
		// her to the window she was dragged off.
		switch reason {
		case "PlatformLaunch", "PlatformDownwardRelease":
			airborneSupportWindowID =
				perch.flatMap { $0.key.kind == .windowTop ? $0.key.owner : nil }
			airborneSupportTop = perchSurface?.offset
		default:
			airborneSupportWindowID = nil
			airborneSupportTop = nil
		}
		// The catcher is discovered rather than inherited, so it is cleared and picked
		// afresh: the graph is rebuilt on the first falling frame anyway.
		catcherWindowID = nil
		catcherTop = nil
		caughtLogGate.reset()
		refreshAirborneCatcher()
		// She is airborne, so nothing holds her: the perch is dropped so a stale
		// surface cannot pull her back to its edge when she lands.
		//
		// Logged because a fall is the only way she leaves the ground, so when she
		// ends up somewhere unexpected this is the one record of why. Without it the
		// log shows a state change to falling and nothing about the cause.
		let from = perchSurface?.key
		DiagnosticsLog.shared.writeEvent(
			"FallStarted",
			[
				("Reason", reason),
				("Foot", "\(Int(foot.x)),\(Int(foot.y))"),
				("Velocity", String(format: "%.0f,%.0f", initialVelocityX, initialVelocityY)),
				("From", from.map { "\($0.kind.rawValue):\($0.owner)" } ?? "none"),
				("State", state.rawValue),
			]
		)
		releasePerch()
		animator.play(clip ?? (initialVelocityY < 0 ? "toss" : "fall"))
	}

	private func refreshForFalling(_ delta: Double) {
		fallRefreshRemaining -= delta
		let needsTimeRefresh = fallRefreshRemaining <= 0
		let needsDistanceRefresh =
			abs(foot.y - lastFallRefreshFootY) >= fallRefreshDistance * displayScale
		guard needsTimeRefresh || needsDistanceRefresh else { return }
		surfaceProvider.refresh(displaySpace: displaySpace)
		fallRefreshRemaining = fallRefreshInterval
		lastFallRefreshFootY = foot.y
		fallRefreshCount += 1
	}

	/// Picks the window she would land on next.
	///
	/// Chosen from the **body sample** rather than the graph. The sample runs at 10 Hz
	/// against the graph's 4, and what matters here is not where a window is — the live
	/// read answers that — but *which* window it is, and a window dragged at 2000 pt/s
	/// covers five hundred points between two graph rebuilds. That is enough to choose the
	/// wrong one, and choosing wrong lets her fall straight through the right one.
	///
	/// The one nearest her feet, on either side of them. A window that has just come up
	/// past them is the one that has just caught her, so it must not be dropped on that
	/// frame — which is exactly what "the nearest one below" would do, and it would let
	/// her through on the very frame the catch was due.
	private func refreshAirborneCatcher() {
		guard state == .falling else { return }
		let inset = Motion.landingInset
		let nearest = surfaceProvider.windowBodies
			.filter { _, body in
				body.bounds.left + inset <= foot.x && foot.x <= body.bounds.right - inset
					&& displaySpace.displays.contains {
						body.bounds.top >= $0.visibleFrame.top
							&& body.bounds.top < $0.visibleFrame.bottom
					}
			}
			.min { abs($0.value.bounds.top - foot.y) < abs($1.value.bounds.top - foot.y) }

		// The baseline is kept when it is still the same window, because the speed it
		// is rising at is measured from two consecutive readings and the sample runs ten
		// times a second — resetting here would mean never having two.
		if let nearest, nearest.key != catcherWindowID {
			catcherWindowID = nearest.key
			catcherTop = nil
		} else if nearest == nil {
			catcherWindowID = nil
			catcherTop = nil
		}
	}

	private func beginHop() {
		beginFall(
			reason: "TerrainHop",
			initialVelocityY: -Motion.hopVelocity * displayScale,
			clip: "jump",
			purpose: .wander
		)
		announce(.terrainHop, voice: .positive, priority: .ambient)
	}

	private func updateFalling(_ delta: Double) {
		fallTickCount += 1
		// Every frame, because the choice is made from the body sample and not from the
		// graph: it is a filter over the windows already sampled for the collision pass.
		refreshAirborneCatcher()
		let scale = displayScale
		velocity.x *= exp(-Motion.horizontalAirDrag * delta)
		velocity.y = min(
			Motion.terminalVelocity * scale,
			velocity.y + Motion.gravity * scale * delta
		)

		// The toss sheet covers the rising half; the fall sheet the rest.
		if velocity.y >= 0, animator.currentClip == "toss" {
			animator.play("fall")
		}

		var movementX = SubpixelMotion.takeWholePixels(velocity.x * delta, remainder: &remainderX)
		let movementY = SubpixelMotion.takeWholePixels(velocity.y * delta, remainder: &remainderY)
		var nextFootX = foot.x + Double(movementX)
		let nextFootY = foot.y + Double(movementY)

		if let display = displaySpace.display(containing: PixelPoint(x: nextFootX, y: nextFootY)) {
			let correction = AirborneBoundaryPolicy.resolveHorizontal(
				proposedFootX: nextFootX,
				velocityX: velocity.x,
				monitorLeft: display.frame.left,
				monitorRight: display.frame.right,
				margin: Motion.boundaryMargin * display.scale
			)
			if correction.corrected {
				velocity.x = correction.velocityX
				movementX = Int((correction.nextFootX - foot.x).rounded())
				nextFootX = foot.x + Double(movementX)
				remainderX = 0
			}
		}

		if resolveAirborneSupport(footX: nextFootX, delta: delta) {
			// She is back on the edge she was thrown from, so this frame's fall is
			// discarded rather than applied and then corrected.
			foot.x = nextFootX
			applyCeiling()
			if abs(velocity.x) > 8 { facing = velocity.x < 0 ? -1 : 1 }
			return
		}

		if movementY > 0 {
			let graphLanding = surfaceProvider.landingSurface(
				footX: nextFootX,
				fromY: foot.y,
				toY: nextFootY,
				inset: Motion.landingInset
			)
			.flatMap { isLandingIgnored($0) ? nil : $0 }
			if let landing = firstLanding(
				live: catcherLanding(footX: nextFootX, reachedY: nextFootY),
				graph: graphLanding
			) {
				// Logged because the two candidates disagree when the graph is stale, and
				// which of them landed her is not otherwise recoverable afterwards.
				DiagnosticsLog.shared.writeEvent(
					"Landed",
					[
						("Surface", "\(landing.surface.key.kind.rawValue):\(landing.surface.key.owner)"),
						("Top", String(format: "%.1f", landing.surface.offset)),
						("Source", landing.source),
						("Footnote", "\(Int(nextFootX)),\(Int(nextFootY))"),
						("FallStartY", String(format: "%.0f", fallStartFootY)),
					]
				)
				foot.x = nextFootX
				foot.y = landing.surface.offset
				land(on: landing.surface)
				return
			}
		}

		foot.x = nextFootX
		foot.y = nextFootY
		applyCeiling()
		if abs(velocity.x) > 8 { facing = velocity.x < 0 ? -1 : 1 }
	}

	/// The surface she meets first out of the two landing candidates, and which of the
	/// two found it.
	///
	/// The higher of the two is the one she reaches first, so they are compared rather
	/// than one being preferred.
	private func firstLanding(
		live: Surface?,
		graph: Surface?
	) -> (surface: Surface, source: String)? {
		switch (live, graph) {
		case let (live?, graph?):
			return live.offset <= graph.offset ? (live, "live") : (graph, "graph")
		case let (live?, nil):
			return (live, "live")
		case let (nil, graph?):
			return (graph, "graph")
		default:
			return nil
		}
	}

	/// Records for a moment that a window she was just thrown clear of must not
	/// catch her on its own top edge.
	private func isLandingIgnored(_ surface: Surface) -> Bool {
		ignoredLandingSeconds > 0 && surface.key.owner == ignoredLandingWindow
	}

	private func tickCooldowns(_ delta: Double) {
		sideImpactCooldown = max(0, sideImpactCooldown - delta)
		ignoredLandingSeconds = max(0, ignoredLandingSeconds - delta)
	}

	/// A window rising faster than she can fly must not pass through her.
	///
	/// The counterpart of the release rule, and a restoration of the original's
	/// `resolveAirborneContact`, which went with the rest of the velocity matching.
	/// Without it the release is one-sided: a window dragged upward faster than she
	/// is thrown overtakes her from below, swallows her, and she drops past it to
	/// the floor. She is put back on its edge, and given its speed unless she
	/// already has a faster one of her own.
	///
	/// Two windows can do it: the one she was just thrown clear of, which is armed
	/// deliberately because the graph cannot be trusted to have caught up with a
	/// window that has just been yanked, and the one the graph says is nearest her
	/// feet, which is read live.
	private func resolveAirborneSupport(footX: Double, delta: Double) -> Bool {
		if catchUpIfRising(
			windowID: airborneSupportWindowID,
			lastTop: &airborneSupportTop,
			footX: footX,
			delta: delta
		) {
			return true
		}

		// Skipped when it is the same window, which the deliberate arming has just
		// looked at.
		guard catcherWindowID != airborneSupportWindowID else { return false }
		return catchUpIfRising(
			windowID: catcherWindowID,
			lastTop: &catcherTop,
			footX: footX,
			delta: delta
		)
	}

	/// Reads one candidate window live and, if it has risen to her feet while still
	/// rising, puts her back on its edge.
	///
	/// A **state**, not a crossing: "its top is at or above my feet, and it is still
	/// coming up". A window can cross her between two samples, so asking whether it
	/// crossed during this frame only answers yes when a sample happened to fall
	/// inside the window's path — which is how a fast window came to swallow her.
	///
	/// - Parameter lastTop: the previous reading, updated in place. The first reading
	///   of a window only establishes the baseline its speed is measured from, and
	///   nothing can be caught from a single reading.
	private func catchUpIfRising(
		windowID: UInt32?,
		lastTop: inout Double?,
		footX: Double,
		delta: Double
	) -> Bool {
		guard let windowID, let live = liveSurface(of: windowID), live.isReachable else {
			return false
		}
		let previousTop = lastTop
		lastTop = live.offset
		guard let previousTop else { return false }

		let scale = displayScale
		let wallVelocity = (live.offset - previousTop) / max(delta, 1.0 / 240)

		// It has come up to her feet, she is over it, and it is still rising fast
		// enough to be doing it. Without the span check a window rising beside her
		// would lift her onto an edge she is not above; without the landing check a
		// window that has just swept her sideways would take her straight back.
		guard live.offset <= foot.y, live.span.contains(footX),
			wallVelocity <= -Motion.airborneCatchUpSpeed * scale, !isLandingIgnored(live)
		else { return false }

		// Logged because this is the one path that puts her *upward* while she is
		// falling, and it fires too rarely to be reproduced on demand: without a
		// record, "she was lifted onto a window" and "she fell through one" look the
		// same in the log afterwards.
		if caughtLogGate.emits(windowID) {
			DiagnosticsLog.shared.writeEvent(
				"AirborneCaught",
				[
					("Window", "\(windowID)"),
					("Source", windowID == airborneSupportWindowID ? "yanked" : "discovered"),
					("Top", String(format: "%.0f", live.offset)),
					("Foot", "\(Int(foot.x)),\(Int(foot.y))"),
					("WallVelocityY", String(format: "%.0f", wallVelocity)),
				]
			)
		}

		foot.y = live.offset
		velocity.y = min(
			velocity.y,
			min(max(wallVelocity * 0.88, -1150 * scale), -300 * scale)
		)
		remainderY = 0
		return true
	}

	/// Whether she has come down onto the window the graph says is nearest her feet.
	///
	/// Read live, so a graph a third of a second old cannot put her through a window
	/// that has since moved under her. That is the other half of the same failure: the
	/// landing test asks where the graph *thinks* the edge is, so a window that moved
	/// is judged against a position it no longer has.
	private func catcherLanding(footX: Double, reachedY: Double) -> Surface? {
		guard let windowID = catcherWindowID, let live = liveSurface(of: windowID),
			live.isReachable, live.offset > fallStartFootY, live.offset <= reachedY + 1,
			live.span.contains(footX), !isLandingIgnored(live),
			// Where the edge *is* comes from the live read, but what covers it can only
			// come from the graph. Landing her on a covered spot is worse than not landing
			// at all: the perch is rejected on the very next frame and she drops again from
			// a standstill, which reads as landing, pausing, and falling.
			isSpotVisible(for: live.key, atCoordinate: footX, inset: Motion.landingInset)
		else { return nil }
		return live
	}

	/// She must not fly out of the top of the screen.
	///
	/// A fast upward drag can throw her further than the sky above her: at the
	/// launch ceiling she rises about 400 pt, which from a high window is off the
	/// display entirely. Bouncing off that ceiling reads better than vanishing.
	private func applyCeiling() {
		guard velocity.y < 0, let display = displaySpace.display(containing: foot) else { return }
		let ceiling = display.visibleFrame.top
		guard foot.y <= ceiling else { return }
		foot.y = ceiling
		velocity.y = 0
		remainderY = 0
	}

	private func land(on surface: Surface?) {
		let fallDistance = max(0, foot.y - fallStartFootY)
		let impactSpeed = max(0, velocity.y)
		// What the fall cost, and the rate the graph was actually rebuilt at during it:
		// the two triggers trade against each other, so neither constant alone says what
		// rate was achieved.
		if fallTickCount > 0 {
			DiagnosticsLog.shared.writeEvent(
				"FallProfile",
				[
					("Ticks", "\(fallTickCount)"),
					("Refreshes", "\(fallRefreshCount)"),
					(
						"RefreshHz",
						String(format: "%.1f", Double(fallRefreshCount) * 60 / Double(fallTickCount))
					),
					("Distance", String(format: "%.0f", fallDistance)),
				]
			)
		}
		// She is down, so no window is following her any more.
		airborneSupportWindowID = nil
		airborneSupportTop = nil
		catcherWindowID = nil
		catcherTop = nil
		caughtLogGate.reset()
		let shouldReact = LandingVoicePolicy.shouldReact(
			fallDistancePixels: fallDistance,
			downwardImpactSpeed: impactSpeed,
			reason: fallReason,
			displayScale: displayScale
		)

		// Adopt what she landed on straight away, so the first frame back on a
		// moving window is already anchored to it rather than to nothing.
		if let surface {
			adopt(surface)
		} else {
			releasePerch()
		}

		state = .landing
		stateElapsed = 0
		transientDuration = animator.durationSeconds
		velocity = .zero
		remainderX = 0
		remainderY = 0
		animator.play("land")
		if shouldReact {
			announce(.hardLanding, voice: .landing, priority: .important)
		}
	}

	// MARK: - Climbing

	/// Returns true when the pet has committed to a climb.
	private func tryBeginClimb() -> Bool {
		guard !quietMode, let support = surfaceProvider.support(at: foot),
			let plan = WindowClimbPlanner.choose(
				surfaces: surfaceProvider.surfaces,
				currentSupport: support,
				footX: foot.x,
				scale: displayScale,
				randomUnit: Double.random(in: 0..<1, using: &random)
			)
		else { return false }

		pendingClimb = plan
		movementPurpose = .climbApproach
		state = .running
		stateElapsed = 0
		targetX = plan.approachX
		animator.play("walk")
		// A taller wall is worth a more cautious line.
		let cautious = plan.height > 400 * displayScale
		announce(cautious ? .carefulClimb : .confidentClimb, voice: .positive, priority: .normal)
		return true
	}

	private func beginClimb(_ plan: WindowClimbPlan) {
		pendingClimb = nil
		activeClimb = plan
		climbStart = foot
		climbProgress = 0

		// She leaps up to the window's lower corner first — a window floating
		// above the floor has no wall beside her until she reaches its bottom.
		climbWallStartY = min(climbStart.y, plan.targetBottom)
		let hopDistance = max(0, climbStart.y - climbWallStartY)
		let hopSeconds = hopDistance > 1 ? min(0.9, max(0.28, hopDistance / 900)) : 0
		let ascentSeconds = WindowClimbPlanner.climbDuration(
			height: max(0, climbWallStartY - plan.targetTop),
			scale: displayScale,
			speedMultiplier: profile.movementSpeedMultiplier
		)
		climbDuration = hopSeconds + ascentSeconds
		climbHopFraction = climbDuration > 0 ? hopSeconds / climbDuration : 0

		// The original succeeds most of the time, less often on a very tall wall,
		// and can slip part way up.
		let successChance = plan.height > 700 * displayScale ? 0.58 : 0.74
		climbWillSucceed = Double.random(in: 0..<1, using: &random) < successChance
		climbSlipAt = 0.56 + Double.random(in: 0..<0.20, using: &random)

		state = .climbing
		movementPurpose = .none
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		remainderY = 0
		// The wall is on the side she approached from.
		facing = plan.side == .left ? 1 : -1
		animator.play(hopSeconds > 0 ? "jump" : "climb")
		DiagnosticsLog.shared.writeEvent(
			"ClimbBegin",
			[
				("Target", "\(plan.targetSurfaceID)"),
				("Side", "\(plan.side)"),
				("Start", "\(Int(climbStart.x)),\(Int(climbStart.y))"),
				("WallStartY", "\(Int(climbWallStartY))"),
				("LandingX", "\(Int(plan.landingX))"),
				("TargetTop", "\(Int(plan.targetTop))"),
				("Surface", Self.describe(surfaceID: plan.targetSurfaceID, in: surfaceProvider.surfaces)),
			]
		)
	}

	private func updateClimbing(_ delta: Double) {
		// The window she is climbing can be moved or closed mid-climb.
		guard let plan = activeClimb,
			surfaceProvider.surfaces.contains(where: { $0.key.owner == plan.targetSurfaceID })
		else {
			activeClimb = nil
			beginFall(reason: "ClimbSlip")
			return
		}

		climbProgress = min(1, climbProgress + delta / max(0.1, climbDuration))
		if !climbWillSucceed, climbProgress >= climbSlipAt {
			activeClimb = nil
			announce(.climbSlip, voice: .aggrieved, priority: .important)
			beginFall(reason: "ClimbSlip")
			return
		}

		if climbProgress < climbHopFraction {
			// Rising to the wall's lower corner, close beside it.
			let t = climbHopFraction > 0 ? climbProgress / climbHopFraction : 1
			foot = PixelPoint(
				x: plan.approachX,
				y: climbStart.y + (climbWallStartY - climbStart.y) * t.smoothstep()
			)
		} else {
			if animator.currentClip != "climb" { animator.play("climb") }
			let span = max(0.0001, 1 - climbHopFraction)
			let t = (climbProgress - climbHopFraction) / span
			// y follows the wall; x stays against it and only steps inward on top,
			// so she is never seen climbing thin air beside the window.
			let easedY = t.smoothstep()
			let easedX = t * t
			foot = PixelPoint(
				x: plan.approachX + (plan.landingX - plan.approachX) * easedX,
				y: climbWallStartY + (plan.targetTop - climbWallStartY) * easedY
			)
		}

		if climbProgress >= 1 {
			activeClimb = nil
			foot = PixelPoint(x: plan.landingX, y: plan.targetTop)
			transientDuration = animator.durationSeconds
			fallStartFootY = foot.y
			fallReason = "ClimbSuccess"
			land(on: surfaceProvider.surfaces.first { $0.key.owner == plan.targetSurfaceID })
			announce(.climbSuccess, voice: .affirmative, priority: .normal)
		}
	}

	// MARK: - Descending

	/// A controlled descent: faster than walking, slower than a fall, and she
	/// stays against the wall.
	private func beginSlideDown(from surface: Surface) {
		guard let target = surfaceProvider.surfaceBelow(footX: foot.x, currentTop: surface.offset)
		else {
			beginFall(reason: "EdgeSlide", clip: "slide")
			return
		}
		beginFall(
			reason: "EdgeSlide",
			initialVelocityY: target.offset > foot.y ? 260 : 120,
			clip: "slide"
		)
		announce(.edgeSlide, voice: .calm, priority: .ambient)
	}

	/// A hop off the edge, arcing outwards so she clears the window she was on.
	private func beginJumpDown(from surface: Surface) {
		let outward = foot.x <= surface.span.start + surface.span.length / 2 ? -1.0 : 1.0
		beginFall(
			reason: "EdgeJump",
			initialVelocityY: -120 * displayScale,
			initialVelocityX: outward * 90 * displayScale,
			clip: "jump"
		)
		facing = outward
		announce(.terrainJumpDown, voice: .scream, priority: .ambient)
	}

	// MARK: - Sleep

	private func beginSleep() {
		wakeForMeal = false
		state = .sleeping
		stateElapsed = 0
		velocity = .zero
		sleepRemaining = min(60, max(LifeBehaviorPolicy.minimumNapSeconds, life.sleepiness / 36 * 60))
		animator.play("sleep_enter")
		announce(.sleep, voice: .calm, priority: .important)
	}

	private var sleepRemaining: Double = 0
	/// Whether the wake-up in progress should end in a meal.
	private var wakeForMeal = false

	/// Starts the get-up animation. A wake already running just records the reason.
	private func beginWake(forMeal: Bool) {
		let starting = state != .waking
		wakeForMeal = wakeForMeal || forMeal
		guard starting else { return }
		state = .waking
		movementPurpose = .none
		stateElapsed = 0
		transientDuration = animator.durationSeconds
		velocity = .zero
		animator.play("sleep_exit")
		if forMeal {
			announce(.wakeForFood, voice: .question, priority: .normal)
		}
	}

	private func updateSleeping(_ delta: Double) {
		if animator.currentClip == "sleep_enter", animator.isCompleted {
			animator.play("sleep")
		}
		sleepRemaining -= delta
		if sleepRemaining <= 0, life.sleepiness <= 10 {
			beginWake(forMeal: false)
		}
	}

	/// Ends a wake-up, whichever way it ended. Woken for a meal, she goes for it;
	/// woken on her own, she simply says so. Both entry points must agree, so the
	/// decision lives here rather than at each of them.
	private func finishWaking() {
		let wokenForMeal = wakeForMeal
		wakeForMeal = false
		if wokenForMeal, beginNextMeal() { return }
		announce(.wakeNormally, voice: .calm)
		returnToIdle()
	}

	// MARK: - Cheek pinch

	/// The cheek anchors in the view's own point space.
	public var cheekGeometryInView: CheekPinchGeometry {
		let geometry = CheekPinchGeometry.geometry(for: profile)
		let scale = canvasScale
		return CheekPinchGeometry(
			leftX: geometry.leftX * scale,
			rightX: geometry.rightX * scale,
			cheekY: geometry.cheekY * scale,
			hitRadiusX: geometry.hitRadiusX * scale,
			hitRadiusY: geometry.hitRadiusY * scale,
			mouthX: geometry.mouthX * scale,
			mouthY: geometry.mouthY * scale
		)
	}

	public var isPinching: Bool { cheek.isActive }

	/// The pinch overlay's current appearance, or `nil` when no cheek is pulled.
	public var cheekPinchState: CheekPinchState? {
		guard cheek.isActive else { return nil }
		return CheekPinchState(geometry: CheekPinchGeometry.geometry(for: profile), dynamics: cheek)
	}

	/// How far the body leans, in degrees: a cheek being pulled, or being flung
	/// across the inside of a window.
	public var bodyLeanDegrees: Double {
		if cheek.isActive {
			// The offset is authored, but the lean is read off the screen, so it
			// has to be mirrored with her — as upstream does with its ScaleX.
			let pull = -cheek.x / CheekPinchDynamics.maximumHorizontal * 3.5 * facing
			return min(max(pull, -3.5), 3.5)
		}
		guard enclosure != nil else { return 0 }
		return min(max(velocity.x / (1200 * displayScale) * 10, -10), 10)
	}

	/// A point in the pet's own square, mirrored back into the authored space the
	/// cheek rig, the renderer and the sprite all live in. She is drawn mirrored
	/// when she faces left, so without this a pinch is taken from the cheek on the
	/// other side of her face and drawn on the wrong side of it.
	private func authoredPoint(_ viewPoint: CGPoint) -> CGPoint {
		guard facing < 0 else { return viewPoint }
		return CGPoint(x: CGFloat(petSize) - viewPoint.x, y: viewPoint.y)
	}

	/// The cheek under a point in the view's own point space, if any.
	public func cheekHitTest(viewPoint: CGPoint) -> CheekSide? {
		guard CheekPinchInteractionPolicy.canStart(from: state) || state == .pinching else {
			return nil
		}
		let point = authoredPoint(viewPoint)
		return cheekGeometryInView.hitTest(x: Double(point.x), y: Double(point.y))
	}

	public func beginPinch(side: CheekSide, at viewPoint: CGPoint) {
		guard !cheek.isActive, CheekPinchInteractionPolicy.canStart(from: state) else { return }
		cheek.begin(side: side)
		pinchOrigin = authoredPoint(viewPoint)
		state = .pinching
		movementPurpose = .none
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		remainderY = 0
		announce(.pickedUp, voice: .aggrieved, priority: .normal)
		notifyCheekPinch()
	}

	public func updatePinch(to viewPoint: CGPoint) {
		guard cheek.isActive else { return }
		let point = authoredPoint(viewPoint)
		let scale = max(0.0001, canvasScale)
		cheek.drag(
			x: Double(point.x - pinchOrigin.x) / scale,
			y: Double(point.y - pinchOrigin.y) / scale
		)
	}

	public func endPinch() {
		guard cheek.isActive else { return }
		cheek.release()
	}

	private func updatePinchFrame(_ delta: Double) {
		guard cheek.isActive else { return }
		cheek.tick(delta)
		if !cheek.isActive {
			// The spring settled and reset itself.
			if state == .pinching { returnToIdle() }
			notifyCheekPinch()
			return
		}
		notifyCheekPinch()
	}

	/// Tells the presenter how the overlay looks now, or that it is gone.
	private func notifyCheekPinch() {
		delegate?.petController(self, didUpdateCheekPinch: cheekPinchState)
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

	/// Her hittable body rectangle, as the collision and enclosure code sees it.
	func debugBodyRect() -> PixelRect { bodyRect() }

	/// Advances only the enclosure step, as one frame would.
	func debugUpdateEnclosure(delta: Double) -> Bool {
		updateWindowEnclosure(delta)
	}

	/// Places her on a known surface and anchors her to it.
	func debugPlaceOnSurface(_ surface: Surface) {
		state = .idle
		movementPurpose = .none
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

	/// Triggers a hop, which is normally chosen by the autonomy planner.
	func debugBeginHop() {
		beginHop()
	}

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

	// MARK: - Dragging

	public func canBeginDrag() -> Bool { DragInteractionPolicy.canStart(from: state) }

	public var isBeingDragged: Bool { isDragging }

	public func beginDrag(at cursor: PixelPoint) {
		guard canBeginDrag() else { return }
		// Picked up: whatever box was holding her no longer does, and no window is
		// following her.
		surrenderEnclosure(reason: "PickedUp")
		airborneSupportWindowID = nil
		airborneSupportTop = nil
		// Being picked up interrupts a meal; it is re-queued so she finishes it
		// after landing.
		if movementPurpose == .meal {
			requeueActiveMeal(reason: "PickedUp")
		}
		isDragging = true
		state = .dragging
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		remainderY = 0
		dragOffset = PixelPoint(x: foot.x - cursor.x, y: foot.y - cursor.y)
		dragTracker.reset(point: cursor, atSeconds: CFAbsoluteTimeGetCurrent())
		animator.play("drag")
		announce(.pickedUp, voice: .question, priority: .normal)
	}

	/// Exposed for tests: the offset between the foot and the grab point.
	var dragOffsetForTesting: PixelPoint { dragOffset }

	private static func describe(surfaceID: UInt32, in surfaces: [Surface]) -> String {
		guard let surface = surfaces.first(where: { $0.key.owner == surfaceID }) else {
			return "missing"
		}
		let bottom = surface.ownerBounds?.bottom ?? surface.offset
		return "L\(Int(surface.span.start)) R\(Int(surface.span.end)) B\(Int(bottom))"
	}

	public func updateDrag(to cursor: PixelPoint) {
		guard isDragging else { return }
		var next = PixelPoint(x: cursor.x + dragOffset.x, y: cursor.y + dragOffset.y)
		// Dragging her below the floor leaves her with nothing to land on, because
		// the floor is above her: on release she would fall straight out of the
		// screen. She is put on the floor instead.
		if let floor = floorOffset(near: next), next.y > floor {
			next.y = floor
		}
		foot = next
		dragTracker.add(point: cursor, atSeconds: CFAbsoluteTimeGetCurrent())
	}

	/// The bottom of the work area of the display nearest a point: where that
	/// display's floor is, and the lowest place the pet may be.
	private func floorOffset(near point: PixelPoint) -> Double? {
		displaySpace.display(containing: point)?.visibleFrame.bottom
	}

	public func endDrag(at cursor: PixelPoint) {
		guard isDragging else { return }
		isDragging = false
		let release = dragTracker.release(
			point: cursor,
			atSeconds: CFAbsoluteTimeGetCurrent(),
			scale: displayScale
		)
		// Whether the window under her is somewhere she can land, or somewhere that
		// swallows her, is read from the terrain graph — so it is asked fresh here
		// rather than trusting a map up to half a second old. The original forced
		// its map at exactly this point, for the same reason.
		surfaceProvider.refresh(displaySpace: displaySpace)
		// Through `beginFall`, so the window she was riding stops being tracked —
		// otherwise it would pull her back to its top once she landed.
		//
		// Let go wholly inside a window and it takes her in instead. `beginFall`
		// stays the only other way into the air, so the two cannot both apply.
		if !tryBeginWindowEnclosure(velocityX: release.velocityX, velocityY: release.velocityY) {
			beginFall(
				reason: release.hasInertia ? "DragThrow" : "released",
				initialVelocityY: release.velocityY,
				initialVelocityX: release.velocityX,
				clip: release.hasInertia && release.velocityY < 0 ? "toss" : "fall",
				purpose: MovementPurpose.none
			)
		}
		// A weak release is a drop, not a throw; only a real flick earns the
		// louder reaction.
		if release.hasInertia, release.speed > 700 * displayScale {
			announce(.dragThrow, voice: .scream, priority: .important)
		} else {
			announce(.released, voice: .aggrieved, priority: .normal)
		}
		// A deletion that arrived while she was being held has to be honoured now
		// that she is somewhere she can leave from.
		if WindowEnclosureBehaviorPolicy.shouldEscapeForMeal(
			isEnclosed: enclosure != nil,
			pendingMeals: mealQueue.count
		) {
			_ = beginNextMeal()
		}
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

	private func announce(
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

	/// The panel's top-left corner in global top-left coordinates.
	public var windowTopLeft: PixelPoint {
		PixelPoint(x: foot.x - footInset.x, y: foot.y - footInset.y)
	}

	/// The pet panel's full frame, in global top-left coordinates.
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
			// She drops from the icon's height rather than snapping back to the edge
			// she set off from; `purpose` is cleared so the ride resumes on landing.
			beginFall(reason: "IconLickFinished", purpose: MovementPurpose.none)
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
