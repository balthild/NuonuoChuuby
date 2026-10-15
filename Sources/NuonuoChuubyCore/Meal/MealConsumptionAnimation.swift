import Foundation

/// One frame of the fake icon's flight while she eats it.
public struct MealConsumptionVisual: Equatable, Sendable {
	/// The icon's centre, in whatever space the animation was built from.
	public var center: PixelPoint
	public var scaleX: Double
	public var scaleY: Double
	public var rotationDegrees: Double
	public var opacity: Double

	public init(
		center: PixelPoint,
		scaleX: Double,
		scaleY: Double,
		rotationDegrees: Double,
		opacity: Double
	) {
		self.center = center
		self.scaleX = scaleX
		self.scaleY = scaleY
		self.rotationDegrees = rotationDegrees
		self.opacity = opacity
	}
}

/// The path the fake icon takes while she eats it.
///
/// Ported from the original's chomping food animation: the icon shivers where it
/// stands, then — as her mouth opens — is drawn to the suction point, shrinking and
/// turning on the way, and vanishes at the end. The anchors are canvas units, like
/// every other sprite anchor, so the whole path scales with her.
///
/// The timings are the original's and are **independent of the chewing clip**, which
/// runs on for another second past the swallow: she finishes the last mouthfuls of an
/// empty mouth. That is deliberate, not an oversight to be tidied up.
public enum MealConsumptionAnimation {
	/// Shivering in place, before the mouth opens.
	public static let shakeSeconds: Double = 0.55
	/// The swallow: shrinking and turning as it is drawn in.
	public static let flightSeconds: Double = 1.22
	/// Fully gone.
	public static let vanishSeconds: Double = 1.35

	/// The shiver's reach, in canvas units.
	private static let shakeX: Double = 3
	private static let shakeY: Double = 2
	private static let shakeTurnDegrees: Double = 4
	private static let shakePulse: Double = 0.035
	/// The horizontal trip is crossed in two legs; this is the first leg's share of
	/// it (105 and then 41 canvas units in the original).
	private static let firstLegShare: Double = 105.0 / 146.0
	private static let flightDuration: Double = flightSeconds - shakeSeconds
	private static let vanishDuration: Double = 0.12
	/// How far into the leg the shrink starts, so the icon is still whole when it
	/// leaves the desktop.
	private static let shrinkStartShare: Double = 0.20
	private static let suctionScale: Double = 0.48
	private static let smallestScale: Double = 0.04

	public static func visual(
		elapsed: Double,
		from start: PixelPoint,
		to end: PixelPoint
	) -> MealConsumptionVisual {
		if elapsed <= shakeSeconds {
			let progress = max(0, elapsed) / shakeSeconds
			return MealConsumptionVisual(
				center: PixelPoint(
					x: start.x + sin(progress * .pi * 5) * shakeX,
					y: start.y + sin(progress * .pi * 4) * shakeY
				),
				scaleX: 1 + sin(progress * .pi * 4) * shakePulse,
				scaleY: 1 + sin(progress * .pi * 4) * shakePulse,
				rotationDegrees: sin(progress * .pi * 5) * shakeTurnDegrees,
				opacity: 1
			)
		}

		// The horizontal target of the swallow's first leg. Note the vertical has
		// already arrived by the end of it — only the horizontal is split.
		let midX = start.x + (end.x - start.x) * firstLegShare

		if elapsed <= flightSeconds {
			let progress = smoothStep((elapsed - shakeSeconds) / flightDuration)
			let shrink = smoothStep((progress - shrinkStartShare) / (1 - shrinkStartShare))
			let suction = 1 + (suctionScale - 1) * shrink
			return MealConsumptionVisual(
				center: PixelPoint(
					x: start.x + (midX - start.x) * progress,
					y: start.y + (end.y - start.y) * progress + sin(progress * .pi * 3) * 5
				),
				scaleX: suction * (1 + 0.12 * progress),
				scaleY: suction * (1 - 0.12 * progress),
				rotationDegrees: -12 * progress + sin(progress * .pi * 3) * shakeTurnDegrees,
				opacity: 1
			)
		}

		let progress = smoothStep((elapsed - flightSeconds) / vanishDuration)
		let vanish = suctionScale + (smallestScale - suctionScale) * progress
		return MealConsumptionVisual(
			center: PixelPoint(
				x: midX + (end.x - midX) * progress,
				y: end.y + sin(progress * .pi * 3) * (1 - progress) * 4
			),
			scaleX: vanish * (1.18 - 0.46 * progress),
			scaleY: vanish * (0.82 + 0.26 * progress),
			rotationDegrees: -12 + 12 * progress,
			opacity: 1 - pow(progress, 4)
		)
	}

	private static func smoothStep(_ progress: Double) -> Double {
		let t = min(max(progress, 0), 1)
		return t * t * (3 - 2 * t)
	}
}
