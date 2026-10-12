import Foundation

public enum WindowClimbSide: Sendable, Equatable {
	case left
	case right
}

public struct WindowClimbPlan: Sendable, Equatable {
	public var targetSurfaceID: UInt32
	public var side: WindowClimbSide
	/// Where she stands at the foot of the wall.
	public var approachX: Double
	/// Where she steps once on top.
	public var landingX: Double
	public var targetTop: Double
	public var targetBottom: Double
	public var height: Double
}

public enum WindowClimbPlanner {
	public static func choose(
		surfaces: [Surface],
		currentSupport: Surface,
		footX: Double,
		scale: Double,
		randomUnit: Double
	) -> WindowClimbPlan? {
		let scale = min(max(scale, 0.5), 4)
		let minimumHeight = (64 * scale).rounded()
		let maximumHeight = (1320 * scale).rounded()
		let sideGap = max(8, (14 * scale).rounded())
		let landingInset = max(20, (34 * scale).rounded())
		// She can make a small exaggerated hop to catch a floating window's lower
		// corner before climbing the visible side.
		let floorReachTolerance = (420 * scale).rounded()

		var candidates: [(plan: WindowClimbPlan, score: Double)] = []

		for target in surfaces {
			guard target.key.kind == .windowTop else { continue }
			let targetID = target.key.owner
			guard targetID != currentSupport.key.owner else { continue }

			let bottom = target.ownerBounds?.bottom ?? target.offset
			let height = currentSupport.offset - target.offset
			guard height >= minimumHeight, height <= maximumHeight else { continue }
			guard bottom >= currentSupport.offset - floorReachTolerance else { continue }

			addSide(
				id: targetID,
				target: target,
				side: .left,
				approachX: target.span.start - sideGap,
				landingX: target.span.start + landingInset,
				height: height
			)
			addSide(
				id: targetID,
				target: target,
				side: .right,
				approachX: target.span.end + sideGap,
				landingX: target.span.end - landingInset,
				height: height
			)
		}

		func addSide(
			id: UInt32,
			target: Surface,
			side: WindowClimbSide,
			approachX: Double,
			landingX: Double,
			height: Double
		) {
			guard currentSupport.isVisible(atCoordinate: approachX, inset: 18) else { return }
			guard target.isVisible(atCoordinate: landingX, inset: 8) else { return }

			let horizontalDistance = abs(approachX - footX)
			let score = horizontalDistance + height * 0.16
			candidates.append(
				(
					WindowClimbPlan(
						targetSurfaceID: id,
						side: side,
						approachX: approachX,
						landingX: landingX,
						targetTop: target.offset,
						targetBottom: target.ownerBounds?.bottom ?? target.offset,
						height: height
					),
					score
				)
			)
		}

		let pool =
			candidates
			.sorted { lhs, rhs in
				if lhs.score != rhs.score { return lhs.score < rhs.score }
				return lhs.plan.targetTop < rhs.plan.targetTop
			}
			.prefix(4)
		guard !pool.isEmpty else { return nil }

		let index = min(
			pool.count - 1,
			Int((min(max(randomUnit, 0), 0.999999) * Double(pool.count)).rounded(.down))
		)
		return pool[index].plan
	}

	/// Taller climbs take longer, bounded so the animation never drags.
	public static func climbDuration(height: Double, scale: Double, speedMultiplier: Double) -> Double
	{
		let perSecond = 175 * max(0.5, scale) * max(0.5, speedMultiplier)
		return min(max(height / perSecond, 2.0), 6.4)
	}
}
