import AppKit
import PetBehaviour
import PetFoundation

@MainActor
extension PetController {
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
		// The rig's anchors are authored against the idle pose, so the cel under the
		// overlay has to be that pose. An interrupted clip — a landing bounce, a fall —
		// draws her face elsewhere, and both the pulled cheek and the mouth the overlay
		// covers for her would land somewhere she is not.
		animator.play("idle")
		pinchOrigin = authoredPoint(viewPoint)
		enter(.pinching, purpose: MovementPurpose.unset)
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

	func updatePinchFrame(_ delta: Double) {
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
		enter(.dragging, clip: "drag")
		remainderX = 0
		remainderY = 0
		dragOffset = PixelPoint(x: foot.x - cursor.x, y: foot.y - cursor.y)
		dragTracker.reset(point: cursor, atSeconds: CFAbsoluteTimeGetCurrent())
		announce(.pickedUp, voice: .question, priority: .normal)
	}

	/// Exposed for tests: the offset between the foot and the grab point.
	var dragOffsetForTesting: PixelPoint { dragOffset }

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
		let release =
			debugReleaseMotionOverride
			?? dragTracker.release(
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
				purpose: MovementPurpose.unset
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
}
