import Foundation

/// One frame of the pet as a free body inside a window's rectangle.
public struct WindowEnclosureStep: Sendable, Equatable {
	public var offsetX: Double
	public var offsetY: Double
	public var velocityX: Double
	public var velocityY: Double
	public var hitLeft: Bool
	public var hitTop: Bool
	public var hitRight: Bool
	public var hitBottom: Bool
	public var isResting: Bool
	public var impactSpeed: Double

	public var hitHorizontal: Bool { hitLeft || hitRight }
	public var hitVertical: Bool { hitTop || hitBottom }
	public var hitAny: Bool { hitHorizontal || hitVertical }
}

/// The pet as a free body inside a moving window rectangle: she keeps her
/// inertia until a wall reaches her, then bounces **relative to that wall**.
///
/// Every constant is ported unchanged from the original Windows implementation
/// so the two behave the same at the same frame rate.
public enum WindowEnclosurePhysics {
	/// How far inside the window's frame the walls sit. Without it she would
	/// visually clip through the window's shadow and rounded corners.
	public static let wallInset: Double = 6

	private enum Motion {
		static let maximumStep: Double = 0.08
		static let gravity: Double = 1650
		static let terminalVelocity: Double = 1400
		static let horizontalDamping: Double = 0.32
		static let maximumWallVelocityX: Double = 900
		static let maximumWallVelocityY: Double = 850
		static let horizontalRestitution: Double = 0.68
		static let topRestitution: Double = 0.58
		static let bottomRestitution: Double = 0.48
		/// Below this the landing is a settle; above it, a bounce worth hearing.
		static let restRelativeSpeed: Double = 115
		static let restWallSpeed: Double = 90
		static let restDamping: Double = 2.2
		static let maximumVelocityX: Double = 1350
		static let maximumVelocityY: Double = 1200
	}

	/// Whether the whole body sits inside the walls at this position.
	///
	/// This is the **entry** question: she is put in only if every part of her is
	/// in, so she is never left visibly hanging out of the window.
	public static func bodyFits(
		_ body: PixelRect,
		in box: PixelRect,
		inset: Double
	) -> Bool {
		box.insetBy(inset).contains(body)
	}

	/// Whether the box has room for a body that size at all, wherever it sits.
	///
	/// This is the **ongoing** question, and it is deliberately about dimensions
	/// rather than position: keeping her between the walls is what ``resolve``
	/// does every frame, and a subpixel remainder can legitimately leave her a
	/// fraction of a point past a wall for a single frame. Asking about position
	/// here would throw her out of a box she is still perfectly inside.
	///
	/// It is exactly the condition ``resolve`` uses for a box too narrow to hold
	/// her, so the two agree by construction.
	public static func boxHasRoom(
		for body: PixelRect,
		in box: PixelRect,
		inset: Double
	) -> Bool {
		let inner = box.insetBy(inset)
		return inner.width >= body.width && inner.height >= body.height
	}

	public static func resolve(
		pet: PixelRect,
		previousBox: PixelRect,
		currentBox: PixelRect,
		velocityX: Double,
		velocityY: Double,
		elapsedSeconds: Double,
		scale: Double
	) -> WindowEnclosureStep {
		guard elapsedSeconds > 0, currentBox.width > 0, currentBox.height > 0 else {
			return WindowEnclosureStep(
				offsetX: 0,
				offsetY: 0,
				velocityX: velocityX,
				velocityY: velocityY,
				hitLeft: false,
				hitTop: false,
				hitRight: false,
				hitBottom: false,
				isResting: false,
				impactSpeed: 0
			)
		}

		// A long frame (a stall, a display wake) must not fling her across the box.
		let delta = min(elapsedSeconds, Motion.maximumStep)
		let scale = max(0.5, scale)
		let inset = wallInset * scale

		let leftBoundary = currentBox.left + inset
		let topBoundary = currentBox.top + inset
		let rightBoundary = currentBox.right - inset
		let bottomBoundary = currentBox.bottom - inset
		let petWidth = pet.right - pet.left
		let petHeight = pet.bottom - pet.top

		var velocityX = velocityX * exp(-Motion.horizontalDamping * delta)
		var velocityY = min(
			Motion.terminalVelocity * scale,
			velocityY + Motion.gravity * scale * delta
		)
		var offsetX = velocityX * delta
		var offsetY = velocityY * delta

		// How fast each wall itself is moving, which is what a bounce is relative
		// to. A wall dragged faster than the clamp is treated as the clamp.
		func wallVelocity(_ current: Double, _ previous: Double, maximum: Double) -> Double {
			let raw = (current - previous) / delta
			return min(max(raw, -maximum), maximum)
		}
		let leftWallVelocity = wallVelocity(
			currentBox.left,
			previousBox.left,
			maximum: Motion.maximumWallVelocityX * scale
		)
		let rightWallVelocity = wallVelocity(
			currentBox.right,
			previousBox.right,
			maximum: Motion.maximumWallVelocityX * scale
		)
		let topWallVelocity = wallVelocity(
			currentBox.top,
			previousBox.top,
			maximum: Motion.maximumWallVelocityY * scale
		)
		let bottomWallVelocity = wallVelocity(
			currentBox.bottom,
			previousBox.bottom,
			maximum: Motion.maximumWallVelocityY * scale
		)

		var hitLeft = false
		var hitTop = false
		var hitRight = false
		var hitBottom = false
		var isResting = false
		var impactSpeed = 0.0

		if rightBoundary - leftBoundary < petWidth {
			// The box is too narrow to hold her: centre her and let the walls
			// carry her, rather than leaving her embedded in one of them.
			offsetX = (leftBoundary + rightBoundary - pet.left - pet.right) / 2
			velocityX = (leftWallVelocity + rightWallVelocity) / 2
			hitLeft = true
			hitRight = true
		} else {
			let nextLeft = pet.left + offsetX
			let nextRight = pet.right + offsetX
			if nextLeft < leftBoundary {
				offsetX += leftBoundary - nextLeft
				let relativeVelocity = velocityX - leftWallVelocity
				impactSpeed = max(impactSpeed, abs(relativeVelocity))
				if relativeVelocity < 0 {
					velocityX = leftWallVelocity - relativeVelocity * Motion.horizontalRestitution
				}
				hitLeft = true
			} else if nextRight > rightBoundary {
				offsetX -= nextRight - rightBoundary
				let relativeVelocity = velocityX - rightWallVelocity
				impactSpeed = max(impactSpeed, abs(relativeVelocity))
				if relativeVelocity > 0 {
					velocityX = rightWallVelocity - relativeVelocity * Motion.horizontalRestitution
				}
				hitRight = true
			}
		}

		if bottomBoundary - topBoundary < petHeight {
			offsetY = (topBoundary + bottomBoundary - pet.top - pet.bottom) / 2
			velocityY = (topWallVelocity + bottomWallVelocity) / 2
			hitTop = true
			hitBottom = true
		} else {
			let nextTop = pet.top + offsetY
			let nextBottom = pet.bottom + offsetY
			if nextTop < topBoundary {
				offsetY += topBoundary - nextTop
				let relativeVelocity = velocityY - topWallVelocity
				impactSpeed = max(impactSpeed, abs(relativeVelocity))
				if relativeVelocity < 0 {
					velocityY = topWallVelocity - relativeVelocity * Motion.topRestitution
				}
				hitTop = true
			} else if nextBottom > bottomBoundary {
				offsetY -= nextBottom - bottomBoundary
				let relativeVelocity = velocityY - bottomWallVelocity
				impactSpeed = max(impactSpeed, abs(relativeVelocity))
				if relativeVelocity > 0,
					relativeVelocity < Motion.restRelativeSpeed * scale,
					abs(bottomWallVelocity) < Motion.restWallSpeed * scale
				{
					// A gentle touch on a nearly still floor settles her instead of
					// bouncing her forever.
					velocityY = bottomWallVelocity
					isResting = true
				} else if relativeVelocity > 0 {
					velocityY = bottomWallVelocity - relativeVelocity * Motion.bottomRestitution
				}
				hitBottom = true
			}
		}

		if isResting {
			velocityX *= exp(-Motion.restDamping * delta)
		}
		velocityX = min(
			max(velocityX, -Motion.maximumVelocityX * scale),
			Motion.maximumVelocityX * scale
		)
		velocityY = min(
			max(velocityY, -Motion.maximumVelocityY * scale),
			Motion.maximumVelocityY * scale
		)

		return WindowEnclosureStep(
			offsetX: offsetX,
			offsetY: offsetY,
			velocityX: velocityX,
			velocityY: velocityY,
			hitLeft: hitLeft,
			hitTop: hitTop,
			hitRight: hitRight,
			hitBottom: hitBottom,
			isResting: isResting,
			impactSpeed: impactSpeed
		)
	}
}
