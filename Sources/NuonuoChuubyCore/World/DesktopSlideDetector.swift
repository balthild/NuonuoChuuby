import Foundation

/// A desktop being slid across the screen by a Space transition, told apart from a
/// window being dragged.
///
/// Measured on this machine (`_ignored/space-probe`): during a transition the whole
/// desktop moves as one image, so every window on it shares the same horizontal step.
/// Four windows reported `-848→-1417`, `-864→-1433`, `-2706→-3275` and
/// `-4449→-5018` in a single sample — the same `-569` to the point, while the list
/// changed size twice a second around them.
///
/// A drag moves exactly **one** window, because the mouse can only hold one. So a step
/// that two windows agree on is the desktop moving, and none of it is something that
/// hit her.
public enum DesktopSlideDetector {
	/// How far apart two windows' steps may be and still count as the same step. The
	/// transition moves them as one image, so they share it exactly; the tolerance is
	/// only there because this compares reads rather than a computation.
	public static let tolerance: Double = 3

	/// Whether these two samples are one desktop moved, rather than windows moved.
	///
	/// False unless at least two windows present in both samples stepped horizontally,
	/// by the same distance.
	///
	/// The vertical step is deliberately a disqualifier rather than something to
	/// compare: a transition of this kind is sideways, and a window dragged diagonally
	/// is one window — excluded here instead of ending the question for the others.
	///
	/// - Parameter minimumStep: the smallest horizontal step worth calling a step,
	///   in points. Passed in because it is a **speed**: it has to be scaled by however
	///   long the two samples actually span, exactly as the side collision does.
	public static func isSliding(
		from previous: [UInt32: PixelRect],
		to current: [UInt32: PixelRect],
		minimumStep: Double
	) -> Bool {
		guard minimumStep > 0 else { return false }

		var agreedStep: Double?
		for (id, now) in current {
			guard let then = previous[id] else { continue }
			let stepX = now.left - then.left
			guard abs(stepX) >= minimumStep, abs(now.top - then.top) < tolerance else { continue }

			guard let agreedStep else {
				agreedStep = stepX
				continue
			}
			if abs(stepX - agreedStep) <= tolerance { return true }
		}
		return false
	}
}
