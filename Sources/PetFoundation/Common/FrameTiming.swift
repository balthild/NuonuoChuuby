import Foundation

public struct FrameTiming: Sendable, Equatable {
	public var simulationSeconds: Double
	public var animationSeconds: Double

	public init(simulationSeconds: Double, animationSeconds: Double) {
		self.simulationSeconds = simulationSeconds
		self.animationSeconds = animationSeconds
	}

	/// Simulation sees the full step; animation is clamped so a hitch cannot skip
	/// a whole animation cycle.
	public static func fromElapsed(
		_ elapsedSeconds: Double,
		maximumAnimationStep: Double = 0.05
	) -> FrameTiming {
		let simulation = max(0, elapsedSeconds)
		let animation = min(max(simulation, 0), maximumAnimationStep)
		return FrameTiming(simulationSeconds: simulation, animationSeconds: animation)
	}
}
