import Foundation

/// A window edge sweeping sideways through the pet's body, and what to do about it.
public struct WindowSideImpact: Sendable, Equatable {
	/// `+1` for a right edge moving right, `-1` for a left edge moving left.
	public var direction: Int
	public var edgeVelocityX: Double
	/// How far to nudge the pet out of the edge she was caught by.
	public var correctionX: Double
	public var petVelocityX: Double
	public var petVelocityY: Double
}

/// Resolves a horizontal window-edge sweep against the pet's body.
///
/// A window dragged sideways past her should knock her out of the way rather
/// than pass through her. Only the edge that actually reached her counts, and
/// the throw is relative to how fast the window was moving.
public enum WindowSideCollisionPolicy {
	/// A shallow corner contact still counts, as long as it reaches the body.
	/// The caller's body rectangle already excludes the feet, so standing on a
	/// top edge cannot be misread as a side hit.
	public static let requiredVerticalOverlap: Double = 4
	public static let contactTolerance: Double = 3
	public static let minimumEdgeSpeed: Double = 22
	private static let maximumEdgeSpeed: Double = 1100
	/// Beyond this the sweep is a teleport (a window restored or snapped), not a
	/// drag, and must not become a throw.
	private static let maximumElapsed: Double = 0.5

	public static func resolve(
		previous: PixelRect,
		current: PixelRect,
		pet: PixelRect,
		elapsedSeconds: Double,
		scale: Double
	) -> WindowSideImpact? {
		guard previous.width > 0, previous.height > 0,
			current.width > 0, current.height > 0,
			elapsedSeconds > 0, elapsedSeconds <= maximumElapsed
		else { return nil }

		let scale = max(0.5, scale)

		let verticalOverlap = max(
			overlap(previous.top, previous.bottom, pet.top, pet.bottom),
			overlap(current.top, current.bottom, pet.top, pet.bottom)
		)
		guard verticalOverlap >= requiredVerticalOverlap * scale else { return nil }

		let tolerance = contactTolerance * scale
		let minimumSpeed = minimumEdgeSpeed * scale
		let rightEdgeDelta = current.right - previous.right
		let leftEdgeDelta = current.left - previous.left
		let maximumCorrection = (pet.right - pet.left) * 0.45

		var rightImpact: WindowSideImpact?
		let rightEdgeVelocity = rightEdgeDelta / elapsedSeconds
		if rightEdgeDelta > 0, rightEdgeVelocity >= minimumSpeed,
			previous.right <= pet.left + tolerance,
			current.right >= pet.left - tolerance
		{
			rightImpact = createImpact(
				direction: 1,
				edgeVelocityX: rightEdgeVelocity,
				correctionX: min(
					maximumCorrection,
					max(0, current.right - pet.left + 2 * scale)
				),
				scale: scale
			)
		}

		var leftImpact: WindowSideImpact?
		let leftEdgeVelocity = leftEdgeDelta / elapsedSeconds
		if leftEdgeDelta < 0, leftEdgeVelocity <= -minimumSpeed,
			previous.left >= pet.right - tolerance,
			current.left <= pet.right + tolerance
		{
			leftImpact = createImpact(
				direction: -1,
				edgeVelocityX: leftEdgeVelocity,
				correctionX: max(
					-maximumCorrection,
					min(0, current.left - pet.right - 2 * scale)
				),
				scale: scale
			)
		}

		switch (rightImpact, leftImpact) {
		case let (.some(right), .some(left)):
			// Unreachable for a well-formed rectangle: both edges hitting would
			// need the window to be narrower than twice the contact tolerance.
			// Kept because it is what the original does.
			return abs(right.edgeVelocityX) >= abs(left.edgeVelocityX) ? right : left
		case let (.some(right), .none):
			return right
		case let (.none, .some(left)):
			return left
		case (.none, .none):
			return nil
		}
	}

	private static func createImpact(
		direction: Int,
		edgeVelocityX: Double,
		correctionX: Double,
		scale: Double
	) -> WindowSideImpact {
		let speed = min(abs(edgeVelocityX), maximumEdgeSpeed * scale)
		let horizontalSpeed = min(
			max(speed * 0.92 + 100 * scale, 230 * scale),
			1450 * scale
		)
		let upwardSpeed = min(
			max(105 * scale + speed * 0.035, 125 * scale),
			220 * scale
		)
		return WindowSideImpact(
			direction: direction,
			edgeVelocityX: Double(direction) * speed,
			correctionX: correctionX,
			petVelocityX: Double(direction) * horizontalSpeed,
			petVelocityY: -upwardSpeed
		)
	}

	private static func overlap(
		_ firstStart: Double,
		_ firstEnd: Double,
		_ secondStart: Double,
		_ secondEnd: Double
	) -> Double {
		max(0, min(firstEnd, secondEnd) - max(firstStart, secondStart))
	}
}
