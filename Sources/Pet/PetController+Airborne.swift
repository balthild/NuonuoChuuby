import Foundation
import PetDesktop
import PetFoundation
import PetMedia

@MainActor
extension PetController {
	/// The single way into the airborne state.
	///
	/// Everything that leaves the ground must come through here, because this is
	/// what clears the perch: a perch is resolved *by identity*, so a stale one
	/// would pull her back to its edge the moment she landed somewhere else.
	func beginFall(
		reason: String = "support-lost",
		initialVelocityY: Double = 0,
		initialVelocityX: Double = 0,
		clip: String? = nil,
		purpose: MovementPurpose? = nil
	) {
		enter(
			.falling,
			purpose: purpose,
			velocity: PixelPoint(x: initialVelocityX, y: initialVelocityY)
		)
		fallReason = reason
		fallStartFootY = foot.y
		fallRefreshRemaining = 0
		lastFallRefreshFootY = foot.y
		fallTickCount = 0
		fallRefreshCount = 0
		remainderX = 0
		remainderY = 0
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

	func refreshForFalling(_ delta: Double) {
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

	/// A leap that goes sideways as well as up, so she can cross a gap onto a
	/// neighbouring surface. `nil` picks a direction at random, which is what the
	/// original does for a hop she chose herself; a hop at an edge goes the way she
	/// was already walking.
	func beginHop(direction: Int? = nil) {
		let direction =
			direction ?? (Double.random(in: 0..<1, using: &random) < 0.5 ? -1 : 1)
		beginFall(
			reason: "TerrainHop",
			initialVelocityY: -Motion.hopVelocityY * displayScale,
			initialVelocityX: Double(direction) * Motion.hopVelocityX * displayScale,
			clip: "jump",
			purpose: .wander
		)
		announce(.terrainHop, voice: .positive, priority: .ambient)
	}

	func updateFalling(_ delta: Double) {
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
		case (let live?, let graph?):
			return live.offset <= graph.offset ? (live, "live") : (graph, "graph")
		case (let live?, nil):
			return (live, "live")
		case (nil, let graph?):
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

	func tickCooldowns(_ delta: Double) {
		sideImpactCooldown = max(0, sideImpactCooldown - delta)
		terrainActionCooldown = max(0, terrainActionCooldown - delta)
		ignoredLandingSeconds = max(0, ignoredLandingSeconds - delta)
		selfReportRemaining -= delta
		if selfReportRemaining <= 0 {
			selfReportRemaining = Self.selfReportInterval(using: &random)
			reportOwnMood()
		}
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

	func land(on surface: Surface?) {
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

		enter(.landing, clip: "land", transientSeconds: animator.durationSeconds)
		remainderX = 0
		remainderY = 0
		if shouldReact {
			announce(.hardLanding, voice: .landing, priority: .important)
		}
	}

	// MARK: - Climbing

	/// Returns true when the pet has committed to a climb.
	func tryBeginClimb() -> Bool {
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
		enter(.running, clip: "walk", purpose: .climbApproach, velocity: nil)
		targetX = plan.approachX
		// A taller wall is worth a more cautious line.
		let cautious = plan.height > 400 * displayScale
		announce(cautious ? .carefulClimb : .confidentClimb, voice: .positive, priority: .normal)
		return true
	}

	func beginClimb(_ plan: WindowClimbPlan) {
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

		enter(
			.climbing,
			clip: hopSeconds > 0 ? "jump" : "climb",
			purpose: MovementPurpose.unset,
			facing: plan.side == .left ? 1 : -1
		)
		remainderX = 0
		remainderY = 0
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

	func updateClimbing(_ delta: Double) {
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
	func beginSlideDown(from surface: Surface) {
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
	/// Like ``beginHop`` it carries her sideways, which is what lets her reach a
	/// lower window rather than dropping straight down the side she left.
	func beginJumpDown() {
		let direction = facing < 0 ? -1.0 : 1.0
		beginFall(
			reason: "EdgeJump",
			initialVelocityY: -Motion.jumpDownVelocityY * displayScale,
			initialVelocityX: direction * Motion.jumpDownVelocityX * displayScale,
			clip: "jump"
		)
		facing = direction
		announce(.terrainJumpDown, voice: .scream, priority: .ambient)
	}

	// MARK: - Sleep
}
