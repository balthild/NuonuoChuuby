import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The climb is split into a leap up to the wall's lower corner and an ascent
/// along the wall. This mirrors `PetController.updateClimbing`, which is private
/// so the geometry is restated here as a pure function.
@Suite("Climb path geometry")
struct ClimbPathTests {
	private struct Plan {
		var approachX: Double
		var landingX: Double
		var targetTop: Double
		var targetBottom: Double
		var start: PixelPoint
	}

	private func smoothstep(_ t: Double) -> Double {
		let c = min(max(t, 0), 1)
		return c * c * (3 - 2 * c)
	}

	private func position(_ plan: Plan, progress: Double, hopFraction: Double) -> PixelPoint {
		let wallStartY = min(plan.start.y, plan.targetBottom)
		if progress < hopFraction {
			let t = hopFraction > 0 ? progress / hopFraction : 1
			return PixelPoint(
				x: plan.approachX,
				y: plan.start.y + (wallStartY - plan.start.y) * smoothstep(t)
			)
		}
		let span = max(0.0001, 1 - hopFraction)
		let t = (progress - hopFraction) / span
		return PixelPoint(
			x: plan.approachX + (plan.landingX - plan.approachX) * (t * t),
			y: wallStartY + (plan.targetTop - wallStartY) * smoothstep(t)
		)
	}

	// The measured case: standing on the floor, a window whose bottom is well
	// above the floor and whose right edge is just past her.
	private let plan = Plan(
		approachX: 1604,
		landingX: 1556,
		targetTop: 258,
		targetBottom: 752,
		start: PixelPoint(x: 1604, y: 1117)
	)
	private let hopFraction = 0.25

	@Test("The ascent never happens below the window's bottom edge")
	func neverClimbsBelowTheWall() {
		for step in 0...100 {
			let progress = Double(step) / 100
			let point = position(plan, progress: progress, hopFraction: hopFraction)
			// Either she is still below the corner (leaping), or she is at or
			// above the window's bottom — never "climbing" thin air below it.
			if progress >= hopFraction {
				#expect(point.y <= plan.targetBottom + 0.001)
			}
		}
	}

	@Test("She reaches the wall's corner at the end of the hop")
	func hopEndsAtTheCorner() {
		let corner = position(plan, progress: hopFraction, hopFraction: hopFraction)
		#expect(abs(corner.x - plan.approachX) < 0.001)
		#expect(abs(corner.y - plan.targetBottom) < 0.001)
	}

	@Test("She hugs the wall for the body of the ascent")
	func hugsTheWall() {
		// A tenth of the way into the ascent she has barely moved inward.
		let early = position(
			plan,
			progress: hopFraction + (1 - hopFraction) * 0.1,
			hopFraction: hopFraction
		)
		#expect(abs(early.x - plan.approachX) < 2)

		// Halfway up she is still within a pet's body width of the wall.
		let middle = position(
			plan,
			progress: hopFraction + (1 - hopFraction) * 0.5,
			hopFraction: hopFraction
		)
		#expect(abs(middle.x - plan.approachX) <= 14)
	}

	@Test("She finishes on the window's top edge")
	func finishesOnTop() {
		let end = position(plan, progress: 1, hopFraction: hopFraction)
		#expect(abs(end.x - plan.landingX) < 0.001)
		#expect(abs(end.y - plan.targetTop) < 0.001)
	}

	@Test("With no leap needed she climbs straight away")
	func noHopWhenAlreadyAtTheWall() {
		// Standing above the window's bottom, so the wall starts at her feet.
		let close = Plan(
			approachX: 500,
			landingX: 452,
			targetTop: 300,
			targetBottom: 900,
			start: PixelPoint(x: 500, y: 600)
		)
		let start = position(close, progress: 0, hopFraction: 0)
		#expect(abs(start.x - close.approachX) < 0.001)
		#expect(abs(start.y - close.start.y) < 0.001)
	}
}
