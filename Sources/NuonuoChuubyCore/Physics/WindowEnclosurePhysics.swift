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
	/// How far inside the window's frame the walls sit. Without it her **body** would
	/// visually clip through the window's shadow and rounded corners. See ``walls(of:inset:)``
	/// for why the floor is not inset with the rest.
	public static let wallInset: Double = 6

	/// The walls, as a rectangle: the window's frame with its **sides and ceiling**
	/// pulled in by `inset`, and its **floor left on the window's own bottom edge**.
	///
	/// The sides and the ceiling need the margin, because her body is a rounded shape
	/// drawn over the window's own rounded corners. The feet do not: the sprite's
	/// lowest opaque row *is* the foot anchor (``SpriteGeometry/footCanvasY``), so an
	/// inset floor leaves her visibly hovering a margin above the window's bottom edge,
	/// by an amount that grows with her size.
	public static func walls(of box: PixelRect, inset: Double) -> PixelRect {
		PixelRect(
			x: box.left + inset,
			y: box.top + inset,
			width: box.width - inset * 2,
			height: box.height - inset
		)
	}

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
		/// Below this she is settling onto a floor rather than hitting one.
		static let restRelativeSpeed: Double = 115
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
		walls(of: box, inset: inset).contains(body)
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
		let inner = walls(of: box, inset: inset)
		return inner.width >= body.width && inner.height >= body.height
	}

	public static func resolve(
		pet: PixelRect,
		previousBox: PixelRect,
		currentBox: PixelRect,
		baselineSeconds: Double? = nil,
		velocityX: Double,
		velocityY: Double,
		wasOnFloor: Bool,
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
		// How long ago the position in `previousBox` was read. One frame normally;
		// longer when the box has not been looked at every frame, in which case the
		// walls have to be judged by how fast they were going over that whole
		// interval rather than by how far they got.
		let baseline = max(baselineSeconds ?? delta, delta)
		let scale = max(0.5, scale)
		let inset = wallInset * scale

		let inner = walls(of: currentBox, inset: inset)
		let leftBoundary = inner.left
		let topBoundary = inner.top
		let rightBoundary = inner.right
		let bottomBoundary = inner.bottom
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
			let raw = (current - previous) / baseline
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

		// A box dragged further in one tick than a perch may move is thrown rather
		// than carried, so a quick jerk flings her while an ordinary drag takes her
		// along. The same rule as the ride — the perch's own displacement, read over
		// however long the two rectangles actually span — so the two surfaces cannot
		// disagree about what counts as a yank.
		let minimumYank = PlatformRidePhysics.yankDisplacement(overSeconds: baseline)
		let horizontalYank =
			abs(currentBox.left - previousBox.left) >= minimumYank
			|| abs(currentBox.right - previousBox.right) >= minimumYank
		let verticalYank = abs(currentBox.top - previousBox.top) >= minimumYank
		// A box too shallow to hold her never lets her stand, so the floor rules
		// below do not apply and she is carried by both walls instead.
		let boxHoldsHer = bottomBoundary - topBoundary >= petHeight

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
				// A jerked wall knocks her; a dragged one only pushes her along, at its
				// own speed. Reporting an impact for the push made every ordinary drag
				// count as a hit, which the controller reads as a reason to scream.
				if horizontalYank, relativeVelocity < 0 {
					impactSpeed = max(impactSpeed, abs(relativeVelocity))
					velocityX = leftWallVelocity - relativeVelocity * Motion.horizontalRestitution
				} else {
					velocityX = leftWallVelocity
				}
				hitLeft = true
			} else if nextRight > rightBoundary {
				offsetX -= nextRight - rightBoundary
				let relativeVelocity = velocityX - rightWallVelocity
				if horizontalYank, relativeVelocity > 0 {
					impactSpeed = max(impactSpeed, abs(relativeVelocity))
					velocityX = rightWallVelocity - relativeVelocity * Motion.horizontalRestitution
				} else {
					velocityX = rightWallVelocity
				}
				hitRight = true
			}
		}

		if !boxHoldsHer {
			offsetY = (topBoundary + bottomBoundary - pet.top - pet.bottom) / 2
			velocityY = (topWallVelocity + bottomWallVelocity) / 2
			hitTop = true
			hitBottom = true
		} else if wasOnFloor, !verticalYank {
			// She is standing on the floor, and it is not being yanked, so it
			// carries her — rising or falling — exactly as a ledge carries her
			// outside a box: her feet stay on it and her speed is its speed.
			//
			// Handing her the floor's speed and then letting her keep it was the
			// bug behind "a bounce on every drag": when the drag stopped or
			// reversed, she went on travelling at the speed the floor *used* to
			// have, left the floor, and came back down hard enough to be read as a
			// landing — a fall animation and a startled line on every slow drag.
			offsetY = bottomBoundary - pet.bottom
			velocityY = bottomWallVelocity
			hitBottom = true
			isResting = true
		} else if wasOnFloor, verticalYank, bottomWallVelocity < 0 {
			// The floor was yanked **up** into her: put her back on it and throw her
			// with it. The perch's rule for a rising ledge.
			offsetY = bottomBoundary - pet.bottom
			velocityY = bottomWallVelocity
			hitBottom = true
			impactSpeed = abs(bottomWallVelocity)
		} else if wasOnFloor, verticalYank {
			// The floor was yanked **down** out from under her. She is not touched by
			// it at all, so she does not move this frame: she is left standing in
			// mid-air and falls from rest, which is what the perch does when a ledge
			// drops away and what a fall should feel like.
			//
			// Her velocity has to be dropped with it. While she was resting the floor
			// carried her, and carrying meant *assigning* the wall's speed to her; that
			// speed is the floor's, not hers, so keeping it would fling her downwards
			// with the drag instead of dropping her.
			offsetY = 0
			velocityY = 0
		} else {
			let nextTop = pet.top + offsetY
			let nextBottom = pet.bottom + offsetY
			if nextTop < topBoundary {
				offsetY += topBoundary - nextTop
				let relativeVelocity = velocityY - topWallVelocity
				if relativeVelocity < 0 {
					// She ran into the ceiling, so she bounces off it — unless it is the
					// ceiling that came down onto her, in which case it only carries her
					// down with it.
					if velocityY <= -Motion.restRelativeSpeed * scale {
						impactSpeed = max(impactSpeed, abs(relativeVelocity))
						velocityY = topWallVelocity - relativeVelocity * Motion.topRestitution
					} else {
						velocityY = topWallVelocity
					}
				}
				hitTop = true
			} else if nextBottom > bottomBoundary {
				offsetY -= nextBottom - bottomBoundary
				let relativeVelocity = velocityY - bottomWallVelocity
				if relativeVelocity > 0 {
					// She is airborne, so the floor is judged by how fast *she* is
					// coming down onto it, not by how fast the floor itself moves. A
					// floor arriving at 300 pt/s under something standing still is
					// still just a floor: it takes her with it.
					let settling =
						velocityY < Motion.restRelativeSpeed * scale
						&& abs(bottomWallVelocity) < Motion.restRelativeSpeed * scale
					if settling {
						velocityY = bottomWallVelocity
						isResting = true
					} else {
						impactSpeed = max(impactSpeed, abs(relativeVelocity))
						velocityY = bottomWallVelocity - relativeVelocity * Motion.bottomRestitution
					}
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
