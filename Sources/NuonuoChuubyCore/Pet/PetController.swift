import AppKit

@MainActor
public protocol PetControllerDelegate: AnyObject {
	func petController(_ controller: PetController, didProduceFrame image: CGImage)
	func petControllerDidChangePlacement(_ controller: PetController)
	func petControllerDidRequestMenu(_ controller: PetController)
}

/// The pet's brain: it owns the simulation position, the behavioural state
/// machine and the sprite animator, and reports where the window should be.
///
/// All coordinates are in **points**, top-left origin, Y down (see
/// ``DisplaySpace``). Working in points means the original's DIP constants carry
/// over unchanged, so `displayScale` stays 1.
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
	}

	/// Actions whose behaviour exists in this build. Food actions arrive with the
	/// meal system.
	private static let implementedActions: Set<AutonomousAction> = [
		.rest, .wander, .explore, .sleep, .hop,
	]

	public let profile: PetCharacterProfile
	public weak var delegate: PetControllerDelegate?
	/// Optional speech; when absent the pet stays silent.
	public weak var speech: PetSpeechCoordinator?

	public private(set) var state: PetState = .idle {
		didSet {
			guard state != oldValue else { return }
			DiagnosticsLog.shared.writeEvent("StateTransition", [
				("From", oldValue.rawValue),
				("To", state.rawValue),
				("Foot", "\(Int(foot.x)),\(Int(foot.y))"),
			])
		}
	}
	public private(set) var life: PetLifeState
	public private(set) var petSize: Double
	public private(set) var foot: PixelPoint
	/// -1 faces left, +1 faces right.
	public private(set) var facing: Double = 1

	/// Mode flags, kept in step with ``PetSettings``.
	public var fastingMode = false
	public var quietMode = false {
		didSet {
			// Turning quiet mode on mid-walk should stop the pet where it is.
			if quietMode, state == .running { returnToIdle() }
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
	private var dragTracker = DragMotionTracker()
	private var dragOffset = PixelPoint.zero
	private var isDragging = false
	private var targetX: Double = 0
	private var movementPurpose: MovementPurpose = .none
	private var fallStartFootY: Double = 0
	private var fallReason = "support-lost"
	private var pendingClimb: WindowClimbPlan?
	private var activeClimb: WindowClimbPlan?
	private var climbProgress: Double = 0
	private var climbStart: PixelPoint = .zero
	private var climbDuration: Double = 3
	private var climbWillSucceed = true
	private var climbSlipAt: Double = 1

	/// How long a transient state (landing, curious, waking) lasts before idle.
	private var transientDuration: Double = 0

	private let displayScale: Double = 1
	private var timer: Timer?
	private var lastTick: CFAbsoluteTime = 0
	private var lastNotifiedFoot: PixelPoint?
	private var lastNotifiedSize: Double?

	public init(
		catalog: AssetCatalog,
		surfaceProvider: SurfaceProvider,
		lifeStore: PetLifeStateStore,
		displaySpace: DisplaySpace,
		profile: PetCharacterProfile = .nuonuo,
		petSize: Double = PetSizePolicy.defaultSize
	) {
		self.profile = profile
		self.catalog = catalog
		self.surfaceProvider = surfaceProvider
		self.lifeStore = lifeStore
		self.displaySpace = displaySpace
		self.petSize = PetSizePolicy.clampPreferredSize(petSize)
		self.life = lifeStore.load()

		let animator = SpriteAnimator(catalog: catalog, profile: profile)
		self.animator = animator

		// Start standing on the primary display's floor, centred.
		let home = displaySpace.displays.first?.visibleFrame ?? PixelRect(x: 0, y: 0, width: 1440, height: 900)
		self.foot = PixelPoint(x: home.centerX, y: home.bottom)
		self.idleRemaining = Double.random(in: 0.5...1.6)

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
		// Other apps move their windows underneath her, so the terrain map is
		// re-read on an interval rather than only at startup.
		surfaceProvider.refreshIfStale(displaySpace: displaySpace, delta: simulation)

		switch state {
		case .idle: updateIdle(simulation)
		case .running: updateRunning(simulation)
		case .falling: updateFalling(simulation)
		case .climbing: updateClimbing(simulation)
		case .landing, .curious, .waking:
			// These play out for a fixed dwell, then return to idle.
			if stateElapsed >= transientDuration {
				if state == .waking { announce(.wakeNormally, voice: .calm) }
				returnToIdle()
			}
		case .sleeping: updateSleeping(simulation)
		default: break
		}

		animator.tick(timing.animationSeconds)
		notifyPlacementIfChanged()
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

		let hasSupport = surfaceProvider.support(footX: foot.x, footY: foot.y) != nil

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
			randomUnit: Double.random(in: 0..<1),
			profile: profile
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
		case .rest, .askForFood, .lickIcon, .roll:
			// `.rest` and anything not yet implemented simply extends the idle.
			resetIdleTimer(factor: 1.4)
		}
	}

	private func resetIdleTimer(factor: Double = 1) {
		idleRemaining = Double.random(in: 1.2...profile.maximumIdleSeconds) * factor
	}

	private func returnToIdle() {
		state = .idle
		movementPurpose = .none
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		animator.play("idle")
		resetIdleTimer()
	}

	// MARK: - Ground movement

	private func beginGroundMove(purpose: MovementPurpose) {
		guard let surface = surfaceProvider.support(footX: foot.x, footY: foot.y) else {
			beginFall()
			return
		}
		let inset = 20 * displayScale
		let minimum = surface.left + inset
		let maximum = max(minimum, surface.right - inset)
		targetX = Double.random(in: minimum...maximum)
		movementPurpose = purpose
		state = .running
		stateElapsed = 0
		animator.play("walk")
	}

	private func updateRunning(_ delta: Double) {
		guard let surface = surfaceProvider.support(footX: foot.x, footY: foot.y) else {
			beginFall()
			return
		}

		// Step up or down a small ledge to stay on the surface.
		let verticalGap = surface.top - foot.y
		if abs(verticalGap) >= 1 {
			foot.y += verticalGap
		}

		targetX = min(max(targetX, surface.left + 20), surface.right - 20)
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
		facing = deltaX < 0 ? -1 : 1
	}

	private func finishGroundMove() {
		let surface = surfaceProvider.support(footX: foot.x, footY: foot.y)

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

		// On a window top, running out of surface is an edge decision rather than
		// a plain stop; on the desktop floor she simply looks around.
		if let surface, !surface.isDesktopFloor,
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
	private func terrainEdgeActionIfAtEdge(_ surface: SupportSurface) -> TerrainEdgeAction? {
		let atEdge = foot.x <= surface.left + 24 || foot.x >= surface.right - 24
		guard atEdge else { return nil }
		return TerrainBehaviorPlanner.chooseAtEdge(
			isDesktopFloor: false, randomUnit: Double.random(in: 0..<1))
	}

	// MARK: - Falling

	private func beginFall(reason: String = "support-lost") {
		state = .falling
		stateElapsed = 0
		fallReason = reason
		fallStartFootY = foot.y
		animator.play("fall")
	}

	private func beginHop() {
		velocity.y = -Motion.hopVelocity * displayScale
		fallStartFootY = foot.y
		fallReason = "TerrainHop"
		state = .falling
		movementPurpose = .wander
		stateElapsed = 0
		animator.play("jump")
		announce(.terrainHop, voice: .positive, priority: .ambient)
	}

	private func updateFalling(_ delta: Double) {
		let scale = displayScale
		velocity.x *= exp(-Motion.horizontalAirDrag * delta)
		velocity.y = min(
			Motion.terminalVelocity * scale,
			velocity.y + Motion.gravity * scale * delta)

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

		if movementY > 0,
			let landing = surfaceProvider.landingSurface(
				footX: nextFootX, fromY: foot.y, toY: nextFootY, inset: Motion.landingInset)
		{
			foot.x = nextFootX
			foot.y = landing.top
			land()
			return
		}

		foot.x = nextFootX
		foot.y = nextFootY
		if abs(velocity.x) > 8 { facing = velocity.x < 0 ? -1 : 1 }
	}

	private func land() {
		let fallDistance = max(0, foot.y - fallStartFootY)
		let impactSpeed = max(0, velocity.y)
		let shouldReact = LandingVoicePolicy.shouldReact(
			fallDistancePixels: fallDistance,
			downwardImpactSpeed: impactSpeed,
			reason: fallReason,
			displayScale: displayScale)
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
		guard !quietMode, let support = surfaceProvider.support(footX: foot.x, footY: foot.y),
			let plan = WindowClimbPlanner.choose(
				surfaces: surfaceProvider.surfaces,
				currentSupport: support,
				footX: foot.x,
				scale: displayScale,
				randomUnit: Double.random(in: 0..<1))
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
		// The original succeeds most of the time, less often on a very tall wall,
		// and can slip part way up.
		let successChance = plan.height > 700 * displayScale ? 0.58 : 0.74
		climbWillSucceed = Double.random(in: 0..<1) < successChance
		climbSlipAt = 0.56 + Double.random(in: 0..<0.20)
		climbDuration = WindowClimbPlanner.climbDuration(
			height: plan.height, scale: displayScale,
			speedMultiplier: profile.movementSpeedMultiplier)
		state = .climbing
		movementPurpose = .none
		stateElapsed = 0
		velocity = .zero
		remainderX = 0
		remainderY = 0
		facing = plan.side == .left ? 1 : -1
		animator.play("climb")
	}

	private func updateClimbing(_ delta: Double) {
		// The window she is climbing can be moved or closed mid-climb.
		guard let plan = activeClimb,
			surfaceProvider.surfaces.contains(where: { $0.sourceID == plan.targetSurfaceID })
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

		// Up the visible side, then step inward onto the top edge.
		let eased = climbProgress * climbProgress * (3 - 2 * climbProgress)
		let x = climbStart.x + (plan.landingX - climbStart.x) * eased
		let y = climbStart.y + (plan.targetTop - climbStart.y) * eased
		foot = PixelPoint(x: x, y: y)

		if climbProgress >= 1 {
			activeClimb = nil
			foot = PixelPoint(x: plan.landingX, y: plan.targetTop)
			fallStartFootY = foot.y
			fallReason = "ClimbSuccess"
			land()
			announce(.climbSuccess, voice: .affirmative, priority: .normal)
		}
	}

	// MARK: - Descending

	/// A controlled descent: faster than walking, slower than a fall, and she
	/// stays against the wall.
	private func beginSlideDown(from surface: SupportSurface) {
		guard let target = surfaceProvider.surfaceBelow(footX: foot.x, currentTop: surface.top) else {
			beginFall(reason: "EdgeSlide")
			return
		}
		state = .falling
		movementPurpose = .none
		stateElapsed = 0
		fallStartFootY = foot.y
		fallReason = "EdgeSlide"
		velocity = PixelPoint(x: 0, y: target.top > foot.y ? 260 : 120)
		remainderX = 0
		remainderY = 0
		animator.play("slide")
		announce(.edgeSlide, voice: .calm, priority: .ambient)
	}

	/// A hop off the edge, arcing outwards so she clears the window she was on.
	private func beginJumpDown(from surface: SupportSurface) {
		let outward = foot.x <= surface.centerX ? -1.0 : 1.0
		state = .falling
		movementPurpose = .none
		stateElapsed = 0
		fallStartFootY = foot.y
		fallReason = "EdgeJump"
		velocity = PixelPoint(x: outward * 90 * displayScale, y: -120 * displayScale)
		remainderX = 0
		remainderY = 0
		facing = outward
		animator.play("jump")
		announce(.terrainJumpDown, voice: .scream, priority: .ambient)
	}

	// MARK: - Sleep

	private func beginSleep() {
		state = .sleeping
		stateElapsed = 0
		velocity = .zero
		sleepRemaining = min(60, max(LifeBehaviorPolicy.minimumNapSeconds, life.sleepiness / 36 * 60))
		animator.play("sleep_enter")
		announce(.sleep, voice: .calm, priority: .important)
	}

	private var sleepRemaining: Double = 0

	private func updateSleeping(_ delta: Double) {
		if animator.currentClip == "sleep_enter", animator.isCompleted {
			animator.play("sleep")
		}
		sleepRemaining -= delta
		if sleepRemaining <= 0, life.sleepiness <= 10 {
			state = .waking
			stateElapsed = 0
			transientDuration = animator.durationSeconds
			animator.play("sleep_exit")
		}
	}

	// MARK: - Dragging

	public func canBeginDrag() -> Bool { DragInteractionPolicy.canStart(from: state) }

	public func beginDrag(at cursor: PixelPoint) {
		guard canBeginDrag() else { return }
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

	public func updateDrag(to cursor: PixelPoint) {
		guard isDragging else { return }
		foot = PixelPoint(x: cursor.x + dragOffset.x, y: cursor.y + dragOffset.y)
		dragTracker.add(point: cursor, atSeconds: CFAbsoluteTimeGetCurrent())
		notifyPlacementIfChanged()
	}

	public func endDrag(at cursor: PixelPoint) {
		guard isDragging else { return }
		isDragging = false
		let release = dragTracker.release(
			point: cursor, atSeconds: CFAbsoluteTimeGetCurrent(), scale: displayScale)
		velocity = PixelPoint(x: release.velocityX, y: release.velocityY)
		remainderX = 0
		remainderY = 0
		fallStartFootY = foot.y
		fallReason = release.hasInertia ? "DragThrow" : "released"
		state = .falling
		stateElapsed = 0
		animator.play(release.hasInertia && velocity.y < 0 ? "toss" : "fall")
		// A weak release is a drop, not a throw; only a real flick earns the
		// louder reaction.
		if release.hasInertia, release.speed > 700 * displayScale {
			announce(.dragThrow, voice: .scream, priority: .important)
		} else {
			announce(.released, voice: .aggrieved, priority: .normal)
		}
	}

	// MARK: - External commands

	public func bringHome() {
		guard let home = displaySpace.displays.first?.visibleFrame else { return }
		foot = PixelPoint(x: home.centerX, y: home.bottom)
		velocity = .zero
		remainderX = 0
		remainderY = 0
		returnToIdle()
		notifyPlacementIfChanged()
		announce(.home, voice: .affirmative, priority: .normal)
	}

	/// Announces the startup line once, after the first frame is on screen.
	public func announceStartup() {
		announce(.startup, voice: .neutral, priority: .normal)
	}

	private func announce(_ cue: DialogueCue, voice: VoiceCue, priority: VoicePriority = .normal) {
		speech?.react(cue, voice: voice, priority: priority)
	}

	public func setSize(_ size: Double) {
		petSize = PetSizePolicy.clampPreferredSize(size)
		notifyPlacementIfChanged()
	}

	/// Rebuilds the coordinate space after a display change and re-clamps the pet
	/// so it cannot be left off every screen.
	public func updateDisplaySpace(_ space: DisplaySpace) {
		displaySpace = space
		if let display = space.display(containing: foot) {
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
			y: petSize * profile.geometry.footCanvasY / SpriteGeometry.canvasSize)
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
		delegate?.petController(self, didProduceFrame: frame)
	}

	public func spriteAnimator(_ animator: SpriteAnimator, didFinishClip clip: String) {
		switch clip {
		case "land", "curious", "sleep_exit", "satisfied", "satisfied_quick":
			if state == .landing || state == .curious || state == .waking {
				returnToIdle()
			}
		default:
			break
		}
	}
}
