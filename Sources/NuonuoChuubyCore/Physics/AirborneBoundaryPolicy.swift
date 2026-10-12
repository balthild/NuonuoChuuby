import Foundation

public struct AirborneHorizontalCorrection: Sendable, Equatable {
	public var corrected: Bool
	public var nextFootX: Double
	public var velocityX: Double
}

public enum AirborneBoundaryPolicy {
	private static let bounceRetention = 0.46

	public static func resolveHorizontal(
		proposedFootX: Double,
		velocityX: Double,
		monitorLeft: Double,
		monitorRight: Double,
		margin: Double
	) -> AirborneHorizontalCorrection {
		guard monitorRight > monitorLeft else {
			return AirborneHorizontalCorrection(
				corrected: false, nextFootX: proposedFootX, velocityX: velocityX)
		}

		let effectiveMargin = max(0, margin)
		let minimum = min(monitorRight - 1, monitorLeft + effectiveMargin)
		let maximum = max(minimum, monitorRight - 1 - effectiveMargin)
		let correctedX = min(max(proposedFootX, minimum), maximum)
		guard abs(correctedX - proposedFootX) >= 0.01 else {
			return AirborneHorizontalCorrection(
				corrected: false, nextFootX: proposedFootX, velocityX: velocityX)
		}

		let hitLeft = proposedFootX < minimum
		let correctedVelocity: Double
		if hitLeft {
			correctedVelocity = velocityX > 0 ? velocityX : abs(velocityX) * bounceRetention
		} else {
			correctedVelocity = velocityX < 0 ? velocityX : -abs(velocityX) * bounceRetention
		}
		return AirborneHorizontalCorrection(
			corrected: true, nextFootX: correctedX, velocityX: correctedVelocity)
	}
}
