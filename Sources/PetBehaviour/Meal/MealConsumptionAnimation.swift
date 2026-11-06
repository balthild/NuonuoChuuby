import Foundation
import PetFoundation

/// One frame of the fake icon's flight while she eats it.
public struct MealConsumptionVisual: Equatable, Sendable {
	/// The icon's centre, in whatever space the animation was built from.
	public var center: PixelPoint
	public var scaleX: Double
	public var scaleY: Double
	public var rotationDegrees: Double
	public var opacity: Double
	/// The rectangle the icon is drawn inside over the **whole** animation, in the same
	/// space as ``center``.
	///
	/// It is the same rectangle on every frame — it says where the icon *will* go, not where
	/// it is. A renderer that gives the icon a window of its own shapes that window from it
	/// once and then only moves the layer inside: a layer's position is free, a window's is
	/// not. Whoever drives the animation fills it in
	/// (see ``MealConsumptionAnimation/box(from:to:halfExtent:)``); a renderer that draws
	/// into a window it already has ignores it.
	public var box: PixelRect?

	public init(
		center: PixelPoint,
		scaleX: Double,
		scaleY: Double,
		rotationDegrees: Double,
		opacity: Double,
		box: PixelRect? = nil
	) {
		self.center = center
		self.scaleX = scaleX
		self.scaleY = scaleY
		self.rotationDegrees = rotationDegrees
		self.opacity = opacity
		self.box = box
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
	/// The extra the path puts on top of the centre's own travel: `sin(progress · 3π) · 5` on
	/// the way in, and `(1 - progress) · 4` as it vanishes.
	private static let flightWobbleY: Double = 5
	private static let vanishWobbleY: Double = 4
	/// The widest the path stretches the icon — `1 + 0.12` on the way in, against the
	/// shiver's own 1.035 — and the furthest it turns it: 12° on the way in plus the shiver's
	/// own 4°.
	private static let widestScale: Double = 1.12
	private static let widestTurnDegrees: Double = 16

	/// The rectangle the icon is drawn inside over the whole animation, in canvas units.
	///
	/// Closed form rather than a walk over the frames, because it is asked for on every frame
	/// of the chew: the two anchors' own span, widened by the reach of the wobble the path
	/// adds to it, and then by the widest squashed-and-turned outline the icon itself
	/// reaches. The factors below are what ``visual(elapsed:from:to:)`` applies, and
	/// `MealConsumptionAnimationTests` samples that path against this rectangle — a change to
	/// the path cannot leave it quietly too small.
	///
	/// - Parameter halfExtent: the drawn icon's half-size, **in canvas units**. The icon is
	///   measured in points (the desktop's own 56), so the caller scales it; everything here
	///   is canvas units, like the anchors every other path is authored in.
	public static func box(
		from start: PixelPoint,
		to end: PixelPoint,
		halfExtent: Double
	) -> PixelRect {
		// The shiver is the only thing that takes the centre outside the span of the two
		// anchors, and the wobbles — 5 on the way in, 4 at the very end — are larger than its
		// own 3 × 2. The first leg stays inside that span: it reaches `midX`, which is on the
		// way to the end.
		let reachX = shakeX
		let reachY = max(shakeY, flightWobbleY, vanishWobbleY)
		let centres = PixelRect(
			x: min(start.x, end.x) - reachX,
			y: min(start.y, end.y) - reachY,
			width: abs(end.x - start.x) + 2 * reachX,
			height: abs(end.y - start.y) + 2 * reachY
		)

		// The icon is whole and upright at its widest, and it is turned at its furthest while
		// already shrunk, so multiplying the two peaks over-states the corner — which is the
		// direction a window can afford to be wrong in.
		let radians = widestTurnDegrees * .pi / 180
		let wiggle = widestScale * (abs(cos(radians)) + abs(sin(radians)))
		let grown = halfExtent * wiggle

		return PixelRect(
			x: centres.x - grown,
			y: centres.y - grown,
			width: centres.width + 2 * grown,
			height: centres.height + 2 * grown
		)
	}

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
