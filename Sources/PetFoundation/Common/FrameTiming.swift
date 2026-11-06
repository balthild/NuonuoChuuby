import Foundation

public struct FrameTiming: Sendable, Equatable {
	public var simulationSeconds: Double
	public var animationSeconds: Double

	public init(simulationSeconds: Double, animationSeconds: Double) {
		self.simulationSeconds = simulationSeconds
		self.animationSeconds = animationSeconds
	}

	/// The cap ``fromElapsed(_:maximumAnimationStep:)`` uses by default: three frames
	/// at 60 Hz, so an ordinary hitch cannot skip a whole animation cycle.
	public static let defaultMaximumAnimationStep: Double = 0.05

	/// Simulation sees the full step; animation is clamped so a hitch cannot skip
	/// a whole animation cycle.
	///
	/// The cap is only ever about a step that was **longer** than the tick it belongs
	/// to. A tick that is deliberately slow is not a hitch: at 10 Hz the default cap
	/// would make every clip play at half speed, so a caller ticking slowly passes its
	/// own interval as the cap.
	public static func fromElapsed(
		_ elapsedSeconds: Double,
		maximumAnimationStep: Double = FrameTiming.defaultMaximumAnimationStep
	) -> FrameTiming {
		let simulation = max(0, elapsedSeconds)
		let animation = min(max(simulation, 0), maximumAnimationStep)
		return FrameTiming(simulationSeconds: simulation, animationSeconds: animation)
	}
}
