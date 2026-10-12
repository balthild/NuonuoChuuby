import Foundation

public struct DragReleaseMotion: Sendable, Equatable {
	public var hasInertia: Bool
	public var velocityX: Double
	public var velocityY: Double
	public var speed: Double
	public var sampleSeconds: Double

	public static let none = DragReleaseMotion(
		hasInertia: false, velocityX: 0, velocityY: 0, speed: 0, sampleSeconds: 0)
}

/// Keeps only the tail of a drag gesture so release velocity follows the user's
/// final flick instead of being diluted by the whole drag path.
public struct DragMotionTracker: Sendable {
	private struct Sample: Sendable {
		var point: PixelPoint
		var atSeconds: Double
	}

	private var samples: [Sample] = []

	public init() {}

	public mutating func reset(point: PixelPoint, atSeconds: Double) {
		samples = [Sample(point: point, atSeconds: atSeconds)]
	}

	public mutating func add(point: PixelPoint, atSeconds: Double) {
		guard let first = samples.first else {
			reset(point: point, atSeconds: atSeconds)
			return
		}
		if atSeconds < first.atSeconds {
			reset(point: point, atSeconds: atSeconds)
			return
		}

		if let last = samples.last, last.point == point, atSeconds - last.atSeconds < 0.004 {
			return
		}

		samples.append(Sample(point: point, atSeconds: atSeconds))
		while samples.count > 2,
			(atSeconds - samples[0].atSeconds > 0.14 || samples.count > 12)
		{
			samples.removeFirst()
		}
	}

	public mutating func release(point: PixelPoint, atSeconds: Double, scale: Double) -> DragReleaseMotion {
		add(point: point, atSeconds: atSeconds)
		guard samples.count >= 2, let newest = samples.last else {
			return .none
		}
		if atSeconds - newest.atSeconds > 0.10 {
			return .none
		}

		let oldest = samples[0]
		let sampleSeconds = newest.atSeconds - oldest.atSeconds
		guard sampleSeconds >= 0.012 else {
			return DragReleaseMotion(
				hasInertia: false, velocityX: 0, velocityY: 0, speed: 0, sampleSeconds: sampleSeconds)
		}

		let rawX = (newest.point.x - oldest.point.x) / sampleSeconds
		let rawY = (newest.point.y - oldest.point.y) / sampleSeconds
		let rawSpeed = (rawX * rawX + rawY * rawY).squareRoot()
		let safeScale = max(0.75, scale)
		let threshold = 430 * safeScale
		guard rawSpeed >= threshold else {
			return DragReleaseMotion(
				hasInertia: false, velocityX: 0, velocityY: 0, speed: rawSpeed, sampleSeconds: sampleSeconds)
		}

		let transfer = min(max((rawSpeed - threshold) / (850 * safeScale), 0.38), 0.82)
		let velocityX = min(max(rawX * transfer, -1750 * safeScale), 1750 * safeScale)
		let velocityY = min(max(rawY * transfer, -1350 * safeScale), 1100 * safeScale)
		let speed = (velocityX * velocityX + velocityY * velocityY).squareRoot()
		return DragReleaseMotion(
			hasInertia: true, velocityX: velocityX, velocityY: velocityY, speed: speed,
			sampleSeconds: sampleSeconds)
	}
}
