import AppKit
import PetDesktop
import PetFoundation

@MainActor
extension PetController {
	/// The window's rectangle right now, read fresh.
	///
	/// The graph lags by up to half a second, which inside a box is the difference
	/// between being carried by a wall and being punched through it, so the walls
	/// come from the window server — the same single-window query the ride uses.
	/// ``updateWindowEnclosure(_:)`` decides how often that has to happen.
	func liveBounds(of windowID: UInt32) -> PixelRect? {
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
	func enclosureFitsTheBox(_ box: PixelRect?) -> Bool {
		guard let current = enclosure else { return true }
		guard let box else {
			surrenderEnclosure(reason: "WindowUnavailable")
			beginFall(
				reason: "EnclosureWindowLost",
				initialVelocityY: velocity.y,
				initialVelocityX: velocity.x
			)
			return false
		}
		// A window on another desktop is still a window, and it keeps every one of its
		// edges: switching Spaces moves the desktop, not the window. So none of the
		// checks below would notice that she is inside one she can no longer be seen
		// in, and none of them can — the rectangle is unchanged and is still on the
		// display. Presence in the on-screen sample is the answer, and the geometry
		// below is only a second opinion for the moment a box slides off the display.
		//
		// She falls out of it, giving up only her own vertical speed: a swap moves the
		// world, not her, so it must not hand her a sideways one.
		guard surfaceProvider.isOnThisDesktop(current.windowID),
			displaySpace.displays.shows(box)
		else {
			surrenderEnclosure(reason: "NotOnThisDesktop")
			beginFall(
				reason: "EnclosureWindowLost",
				initialVelocityY: velocity.y,
				initialVelocityX: 0
			)
			return false
		}
		guard
			WindowEnclosurePhysics.boxHasRoom(
				for: enclosureBodyRect,
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
	func enclosureFitsTheBox() -> Bool {
		guard let current = enclosure else { return true }
		return enclosureFitsTheBox(liveBounds(of: current.windowID))
	}

	/// Steps her as a free body inside the window's walls.
	///
	/// Returns true while the box holds her, which is the signal to skip the whole
	/// terrain path for this frame: inside a box its four walls are the world.
	func updateWindowEnclosure(_ delta: Double) -> Bool {
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
		// A box that has grown around her is a window being made bigger. Position
		// changes do not move either edge of the rectangle, so only a real resize
		// counts; the gate turns a drag-resize, which grows it a little every
		// frame, into one remark. It has to be shown every frame to notice the
		// growth ending, so it is asked before the answer is used.
		let growing =
			box.width > current.previousBox.width + Self.boxGrowthTolerance
			|| box.height > current.previousBox.height + Self.boxGrowthTolerance
		if boxGrowthGate.emits(growing), growing {
			announce(.windowMaximized, voice: .scream, priority: .normal)
		}

		let scale = displayScale
		let step = WindowEnclosurePhysics.resolve(
			pet: enclosureBodyRect,
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

		// A window top that has come under her since she was let go is where she
		// lands, rather than something the box carries her past on the way down to its
		// floor. Entry asks the same question, but only once, at the moment of release
		// — and a throw can carry her up over a window that was not under her then, so
		// the box swallowed a descent that should have ended on that edge.
		//
		// She is handed back to the open desktop rather than landed here, so which
		// surface she meets and where it is are read exactly as they are for any other
		// fall: live, and again on every frame.
		if velocity.y > 0, landingInsideTheBox(footX: foot.x, box: box) != nil {
			surrenderEnclosure(reason: "EnclosureLanding")
			beginFall(
				reason: "EnclosureLanding",
				initialVelocityY: velocity.y,
				initialVelocityX: velocity.x
			)
			return false
		}

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
		} else if step.isResting, !wasResting || state == .falling {
			// Resting is what ends a fall, including one that never left the floor: a
			// side wall can knock her while the floor goes on holding her, and then
			// `wasResting` is already true, so a transition-only test never fires and
			// the knock's fall animation stays on for as long as she is in the box.
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
				enclosureBodyRect,
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
	func tryBeginWindowEnclosure(velocityX: Double, velocityY: Double) -> Bool {
		let body = enclosureBodyRect
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
		//
		// Asked here about the moment of release only. The descent inside the box asks
		// the same question again, because a throw carries her up over windows that were
		// not under her then; see ``updateWindowEnclosure(_:)``.
		guard landingInsideTheBox(footX: foot.x, box: fitted.value.bounds) == nil else {
			return false
		}

		enclosure = Enclosure(
			windowID: fitted.key,
			previousBox: fitted.value.bounds,
			isResting: false
		)
		airborneSupportWindowID = nil
		airborneSupportTop = nil
		enter(
			.falling,
			purpose: MovementPurpose.unset,
			velocity: PixelPoint(x: velocityX, y: velocityY)
		)
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

	/// A standable surface between her feet and the box's floor: something inside the
	/// box she would come down on, rather than fall past to its floor.
	///
	/// **One question, asked at both ends of a box's life.** Entry refuses a box that
	/// has one, so she is not swallowed while a ledge is under her; the descent inside
	/// the box leaves for that same ledge. Sharing the helper is what keeps the two from
	/// disagreeing about which surfaces count and how far down the box reaches.
	///
	/// The floor is the window's own bottom edge, not one pulled in with the walls
	/// (``WindowEnclosurePhysics/walls(of:inset:)``) — the feet rest on the edge itself.
	private func landingInsideTheBox(footX: Double, box: PixelRect) -> Surface? {
		surfaceProvider.landingSurface(
			footX: footX,
			fromY: foot.y,
			toY: box.bottom - WindowEnclosurePhysics.wallInset * displayScale,
			inset: Motion.landingInset
		)
	}

	/// Leaves the box without deciding what happens next.
	func surrenderEnclosure(reason: String) {
		guard let current = enclosure else { return }
		enclosure = nil
		movementPurpose = .unset
		boxGrowthGate.reset()
		DiagnosticsLog.shared.writeEvent(
			"WindowEnclosureReleased",
			[("Window", "\(current.windowID)"), ("Reason", reason)]
		)
	}

	/// Leaves the box to go and eat, through whichever wall faces the food.
	func releaseEnclosureForMeal(target: PixelPoint) {
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
	func updateWindowSideCollisions() {
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
}
