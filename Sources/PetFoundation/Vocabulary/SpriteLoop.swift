import CoreGraphics

/// A looping clip handed to the render server to play.
///
/// The frames of a clip can be played by `CAKeyframeAnimation` instead of being stepped
/// by the simulation's tick, and for a clip that never finishes there is nothing to step:
/// the render server can hold the whole cycle and play it at the display's own rate. That
/// matters because **the tick is where the cadence currently comes from**, so a slower
/// tick quantises every frame's dwell to a multiple of it — which is why she could not be
/// slowed down while idle (see `Docs/Internal/rendering.md`).
///
/// Only looping clips are handed over. A clip that finishes has to *tell* someone it
/// finished — that is the tick's `didFinishClip`, which drives the state machine — so
/// those keep being stepped one frame at a time.
public struct SpriteLoop {
	/// The clip this cycle belongs to, for the caller's own bookkeeping.
	public let clip: String
	/// One full cycle, in play order. A ping-pong clip is already expanded, so the
	/// render server only ever has to repeat this.
	public let frames: [CGImage]
	public let frameSeconds: Double

	public init(clip: String, frames: [CGImage], frameSeconds: Double) {
		self.clip = clip
		self.frames = frames
		self.frameSeconds = frameSeconds
	}

	public var cycleSeconds: Double {
		Double(frames.count) * frameSeconds
	}
}
