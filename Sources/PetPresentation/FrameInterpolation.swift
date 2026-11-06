import QuartzCore

/// The short layer animation that carries the pet from one tick's position to the
/// next.
///
/// The simulation ticks at 60 Hz, so without this her position on screen is a
/// staircase: each step is held for two frames of a 120 Hz display. A layer
/// animation hands the render server two positions and a duration, and it samples
/// that between them at the display's own rate instead.
///
/// The cost is lag, and it is not negotiable — anything that smooths a signal
/// delays it. A layer given `duration` to reach each new target trails that target
/// by `velocity * duration`, so at one tick a drag at 2000 px/s leaves her 33 px
/// behind the cursor. That is the entire trade: everything on screen runs half a
/// step behind, and tuning cannot separate the two halves of it.
///
/// Measured, because the obvious way to write this silently does nothing: a
/// `CABasicAnimation` template left in a layer's `actions` dictionary does **not**
/// interpolate at all — `presentation()` sits exactly one commit behind the model,
/// at any duration. Only the transaction's duration works.
///
/// **One frame, one commit.** A frame moves her and, from inside that same closure,
/// her bubble — a layer of the very window the frame is moving. A wrapper opened
/// inside the first would commit that frame a second time, so a nested call does
/// nothing but run its body: the outermost call decides, and everything inside it
/// lands in its transaction. That is what a nested transaction would have given the
/// inner call anyway (a transaction's unset properties are inherited from the one
/// that encloses it), minus the commit.
@MainActor
public enum FrameInterpolation {
	/// One simulation tick, so the interpolation exactly spans the gap between two
	/// ticks. Longer would add lag without adding smoothness, shorter would finish
	/// early and stall until the next target arrives.
	public static let duration: CFTimeInterval = 1.0 / 60

	/// How many of these wrappers are running. Only the outermost one opens a
	/// transaction — see the note above.
	private static var nesting = 0

	/// Runs `body` with the follow animation in effect.
	///
	/// Only properties *without* an `NSNull` in the layer's `actions` are affected,
	/// which is how the pet keeps its picture and its lean landing in the frame they
	/// were set in.
	public static func animate(_ body: () -> Void) {
		if nesting > 0 {
			body()
			return
		}
		nesting += 1
		CATransaction.begin()
		CATransaction.setAnimationDuration(duration)
		CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
		body()
		CATransaction.commit()
		nesting -= 1
	}

	/// Runs `body` with implicit animations suppressed, for a layer being put
	/// somewhere for the first time: a bubble appearing should arrive where it
	/// belongs, not slide in from wherever it was last seen.
	public static func withoutAnimation(_ body: () -> Void) {
		if nesting > 0 {
			body()
			return
		}
		nesting += 1
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		body()
		CATransaction.commit()
		nesting -= 1
	}
}
