import Foundation
import PetBehaviour
import PetDesktop
import PetFoundation

@MainActor
extension PetController {
	/// Starts an autonomous walk.
	///
	/// A walk is a chain of legs, and each leg is decided when the previous one ends
	/// rather than up front: out to an edge ([`edgeLegChance`]), which is where the
	/// edge decisions — hop, slide, jump off — live, or a stroll to a point she
	/// settles at, which is what gives the walk an ending at all.
	///
	/// The port used to draw a uniform random point from the middle of the run, which
	/// on a window a thousand points wide lands within reach of an end a few percent
	/// of the time, so she only ever paced up and down the middle and the edge
	/// decisions never ran. The original instead targets the ends
	/// (`ChooseNextPatrolTarget`), which is what makes its edge behaviour visible.
	@discardableResult
	func beginAutonomousWalk(preferClimb: Bool, strollPurpose: MovementPurpose) -> Bool {
		self.strollPurpose = strollPurpose
		guard surfaceProvider.support(at: foot) != nil else {
			beginFall()
			return false
		}
		if beginNextLeg(preferClimb: preferClimb) { return true }
		returnToIdle()
		return false
	}

	/// Decides the next leg of an autonomous walk.
	///
	/// Returns false when she cannot walk from here at all, which is a run too short
	/// to cross rather than anything wrong with her.
	@discardableResult
	private func beginNextLeg(preferClimb: Bool = false) -> Bool {
		let looksForClimb = preferClimb || Double.random(in: 0..<1, using: &random) < 0.34
		if looksForClimb, tryBeginClimb() { return true }
		if rollIsEdgeLeg(), beginPatrolLeg() { return true }
		return beginStroll(purpose: strollPurpose)
	}

	func rollIsEdgeLeg() -> Bool {
		debugForcedEdgeLeg
			?? (Double.random(in: 0..<1, using: &random) < Self.edgeLegChance)
	}

	/// Walks her to the far end of her run, where the edge decisions happen.
	func beginPatrolLeg() -> Bool {
		guard let next = nextPatrolTargetX() else { return false }
		targetX = next
		enter(.running, clip: "walk", purpose: .patrol, facing: patrolDirection)
		remainderX = 0
		patrolNeedCheckRemaining = LifeBehaviorPolicy.patrolNeedCheckSeconds
		DiagnosticsLog.shared.writeEvent(
			"PatrolStarted",
			[
				("TargetX", "\(Int(targetX))"),
				("Support", perchSurface?.key.kind.rawValue ?? "none"),
			]
		)
		return true
	}

	/// Walks her to a point she then settles at rather than walking on from.
	///
	/// This is the original's menu walk (`StartGroundMove`), the only one it has that
	/// ends somewhere other than an edge.
	private func beginStroll(purpose: MovementPurpose) -> Bool {
		guard let next = nextStrollTargetX() else { return false }
		targetX = next
		enter(.running, clip: "walk", purpose: purpose, facing: next < foot.x ? -1 : 1)
		remainderX = 0
		DiagnosticsLog.shared.writeEvent(
			"StrollStarted",
			[
				("Purpose", purpose.rawValue),
				("TargetX", "\(Int(targetX))"),
			]
		)
		return true
	}

	/// The far end she should walk to now, or nil when her run is too short to cross.
	private func nextPatrolTargetX() -> Double? {
		guard let run = currentRun() else { return nil }
		let margin = patrolStopMargin
		let minimumX = run.start + margin
		let maximumX = run.end - margin
		guard maximumX - minimumX >= 42 else { return nil }

		if patrolDirection == 0 {
			patrolDirection = Double.random(in: 0..<1, using: &random) < 0.5 ? -1 : 1
		}
		var next = patrolDirection < 0 ? minimumX : maximumX
		// Setting out for the end she is already at would be a walk of zero length.
		if abs(next - foot.x) < 20 {
			patrolDirection *= -1
			next = patrolDirection < 0 ? minimumX : maximumX
		}
		return next
	}

	/// A stroll's destination: a drawn distance in a drawn direction, away from where
	/// she already is.
	///
	/// Drawn rather than picked uniformly along the run, because a uniform point lands
	/// near her about as often as not, and a stroll that goes nowhere is not a walk
	/// she can be seen to make.
	private func nextStrollTargetX() -> Double? {
		guard let run = currentRun() else { return nil }
		let margin = patrolStopMargin
		let minimumX = run.start + margin
		let maximumX = run.end - margin
		guard maximumX - minimumX >= 42 else { return nil }

		let travel = Double.random(in: 80...241, using: &random)
		let direction: Double = Double.random(in: 0..<1, using: &random) < 0.5 ? -1 : 1
		var next = min(max(foot.x + direction * travel, minimumX), maximumX)
		// Too close to be a walk: head for the far end instead, as the original does
		// when its own drawn distance lands on top of her.
		if abs(next - foot.x) < 36 {
			let toLeft = abs(minimumX - foot.x)
			let toRight = abs(maximumX - foot.x)
			next = toLeft > toRight ? minimumX : maximumX
		}
		guard abs(next - foot.x) >= 24 else { return nil }
		return next
	}

	/// The stretch of the edge she is standing on, inset to exclude anywhere another
	/// window hides. Nil when she has no support at all.
	private func currentRun() -> Span? {
		guard let surface = surfaceProvider.support(at: foot) else { return nil }
		return perch.flatMap { surface.visibleRun(containingT: $0.t) } ?? surface.span
	}

	/// How far short of an end of her run she stops.
	///
	/// Scaled off her own width like the original, which measures the pet window
	/// instead. The arrival is not tested against this: reaching the end is whatever
	/// this walk decides, so the two cannot disagree about where the end is.
	var patrolStopMargin: Double {
		min(max(petSize * 0.20, 24), 72)
	}

	/// A pressing need stops the walk she is in the middle of.
	///
	/// A patrol runs for minutes — she only turns around at an end — so without this
	/// she would walk straight through being exhausted or starving: nothing else
	/// looks at her needs while she is walking. Only the urgent end of each need
	/// counts, which is why falling asleep mid-walk is rare rather than constant.
	///
	/// Returns true when she has been handed off to something else.
	private func tryInterruptPatrolForNeed() -> Bool {
		guard !quietMode else { return false }

		// A meal outranks every need above, and was already the one thing allowed to
		// take her off a walk when it arrived.
		if beginNextMeal() { return true }

		var available: Set<AutonomousAction> = []
		func add(_ action: AutonomousAction, _ condition: Bool) {
			guard condition,
				PetModePolicy.allowsAutonomousAction(
					action,
					fastingMode: fastingMode,
					quietMode: quietMode
				),
				actionReadyAt[action, default: 0] <= elapsedSeconds,
				LifeBehaviorPolicy.isHungerReactionReady(
					action,
					now: elapsedSeconds,
					nextHungerReactionAt: nextHungerReactionAt
				)
			else { return }
			available.insert(action)
		}
		add(.sleep, life.sleepiness >= LifeBehaviorPolicy.sleepInterruptionThreshold)
		add(.askForFood, life.hunger >= LifeBehaviorPolicy.foodAppealInterruptionThreshold)
		add(.lickIcon, life.hunger >= LifeBehaviorPolicy.lickInterruptionThreshold)
		add(.roll, life.hunger >= LifeBehaviorPolicy.rollInterruptionThreshold)
		guard !available.isEmpty else { return false }

		let action = AutonomousBehaviorPlanner.choose(
			life: life,
			hasGroundSupport: true,
			availableActions: available,
			randomUnit: Double.random(in: 0..<1, using: &random),
			profile: profile
		)
		// Logged because a walk that stops and a walk that simply has not turned
		// around yet look identical from outside, and "she was hungry" is the whole
		// content of the difference.
		DiagnosticsLog.shared.writeEvent(
			"PatrolInterrupted",
			[
				("Action", action.rawValue),
				("Hunger", String(format: "%.0f", life.hunger)),
				("Sleepiness", String(format: "%.0f", life.sleepiness)),
			]
		)

		switch action {
		case .sleep:
			actionReadyAt[.sleep] = elapsedSeconds + 90
			beginSleep()
			return true
		case .askForFood:
			actionReadyAt[.askForFood] = elapsedSeconds + 55
			markHungerReaction()
			beginHungryPlea()
			return true
		case .lickIcon:
			actionReadyAt[.lickIcon] = elapsedSeconds + 55
			markHungerReaction()
			if tryBeginIconLick(manual: false) { return true }
			// No icon she can reach: she rolls on the spot instead, as the original
			// does rather than resuming the walk.
			beginRoll()
			return true
		case .roll:
			actionReadyAt[.roll] = elapsedSeconds + 42
			markHungerReaction()
			beginRoll()
			return true
		default:
			return false
		}
	}

	/// The hunger-driven actions share one cooldown, so she does not run through
	/// pleading, licking and rolling back to back.
	private func markHungerReaction() {
		nextHungerReactionAt =
			elapsedSeconds + LifeBehaviorPolicy.hungerReactionCooldownSeconds
	}

	func updateRunning(_ delta: Double) {
		// A meal or an icon lick is a free-standing two-dimensional walk.
		if movementPurpose == .meal || movementPurpose == .iconLick {
			updateMealRun(delta)
			return
		}

		// A patrol lasts as long as it takes to cross the surface, which is minutes
		// on a wide window. Without this she would walk through being exhausted or
		// starving, because nothing else asks during a walk.
		if movementPurpose == .patrol {
			patrolNeedCheckRemaining -= delta
			if patrolNeedCheckRemaining <= 0 {
				patrolNeedCheckRemaining = LifeBehaviorPolicy.patrolNeedCheckSeconds
				if tryInterruptPatrolForNeed() { return }
			}
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
		// No give-up timeout: a walk that reaches for a window's edge can be long, and
		// bounding it would teleport her the rest of the way instead of finishing it.
		if abs(deltaX) <= Motion.arrivalTolerance {
			foot.x += deltaX
			finishGroundMove()
			return
		}

		let speed =
			(movementPurpose.usesExplorePace ? Motion.exploreSpeed : Motion.walkSpeed)
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
	func maintainGroundSupport(_ delta: Double) {
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
		//
		// The threshold is that displacement **read over the tick that measured it**,
		// because what it really is is a speed — 900 pt/s. A tick six times as long
		// covers six times the ground, and comparing that raw would read an ordinary
		// drag as a flick; asleep, where the tick is deliberately slow, she would be
		// thrown off a window that is merely being moved.
		let displacement = lastPerchOffset.map { surface.offset - $0 } ?? 0
		lastPerchOffset = surface.offset

		if abs(displacement) >= PlatformRidePhysics.yankDisplacement(overSeconds: delta) {
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
	///
	/// Where it is still leaves open whether it is hers to stand on: a window of a
	/// desk she has switched away from keeps every one of its edges. See
	/// ``SurfaceProvider/isOnThisDesktop(_:)``.
	func liveSurface(of windowID: UInt32) -> Surface? {
		if let debugLiveWindowSurfaceOverride { return debugLiveWindowSurfaceOverride(windowID) }
		return WindowSurfaceProvider.liveWindowSurface(
			windowID: windowID,
			monitors: displaySpace.displays,
			isOnThisDesktop: surfaceProvider.isOnThisDesktop(windowID)
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
	func isSpotVisible(
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
	static func describe(_ surfaces: [Surface], id: UInt32) -> String {
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
	func adopt(_ surface: Surface) {
		let perch = Perch.at(foot, on: surface)
		self.perch = perch
		perchSurface = surface
		lastPerchOffset = surface.offset
		perchLogGate.reset()
		foot = perch.position(in: surface)
	}

	func releasePerch() {
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
		if movementPurpose == .edgeJumpApproach {
			beginJumpDown()
			return
		}

		// She arrives at an end of the run, which is the only place an edge action
		// is decided. With no action to take — the draw said to turn around, or the
		// wait before another one has not elapsed — the rest of the walk is decided
		// afresh rather than turning back out of habit.
		if movementPurpose == .patrol {
			if let surface, let action = terrainEdgeAction(at: surface) {
				switch action {
				case .hop:
					// Backwards off the desktop floor, forwards off a window — the
					// original's rule, and the reason the floor hop looks like a start.
					let direction = surface.key.kind == .floor ? -patrolDirection : patrolDirection
					beginHop(direction: direction < 0 ? -1 : 1)
					return
				case .slideDown:
					beginSlideDown(from: surface)
					return
				case .jumpDown:
					beginJumpDown()
					return
				case .turnAround:
					break
				}
			}
			patrolDirection *= -1
			if beginNextLeg() { return }
			returnToIdle()
			return
		}

		enter(.curious, clip: "curious", purpose: MovementPurpose.unset, transientSeconds: 0.9)
		remainderX = 0
	}

	/// The edge action she takes on reaching the end of her run, or nil when the draw
	/// says to turn around or the cooldown is still running.
	private func terrainEdgeAction(at surface: Surface) -> TerrainEdgeAction? {
		guard terrainActionCooldown <= 0 else { return nil }
		let action =
			debugForcedTerrainEdgeAction
			?? TerrainBehaviorPlanner.chooseAtEdge(
				isDesktopFloor: surface.key.kind == .floor,
				randomUnit: Double.random(in: 0..<1, using: &random)
			)
		guard action != .turnAround else { return nil }
		terrainActionCooldown = Self.terrainActionInterval
		// Logged because a hop and a turn-around look the same until she leaves the
		// ground, and what she chose is not otherwise recoverable.
		DiagnosticsLog.shared.writeEvent(
			"TerrainEdgeActionChosen",
			[
				("Action", "\(action)"),
				("Support", surface.key.kind.rawValue),
				("Direction", "\(Int(patrolDirection))"),
			]
		)
		return action
	}

	// MARK: - Falling

	static func describe(surfaceID: UInt32, in surfaces: [Surface]) -> String {
		guard let surface = surfaces.first(where: { $0.key.owner == surfaceID }) else {
			return "missing"
		}
		let bottom = surface.ownerBounds?.bottom ?? surface.offset
		return "L\(Int(surface.span.start)) R\(Int(surface.span.end)) B\(Int(bottom))"
	}
}
