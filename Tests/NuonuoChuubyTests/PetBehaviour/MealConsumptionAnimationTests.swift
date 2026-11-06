import Foundation
import Testing

@testable import PetBehaviour
@testable import PetFoundation

/// The fake icon's flight while she eats it. Anchors are the original's own for
/// 糯糯: her mouth and the point inside it the food is drawn to.
struct MealConsumptionAnimationTests {
	private static let mouth = PixelPoint(x: 45, y: 267)
	private static let suction = PixelPoint(x: 191, y: 304)
	private static let frame = 1.0 / 60

	private func visual(at elapsed: Double) -> MealConsumptionVisual {
		MealConsumptionAnimation.visual(
			elapsed: elapsed,
			from: Self.mouth,
			to: Self.suction
		)
	}

	@Test("It starts on the desktop icon, whole and upright")
	func startsOnTheIcon() {
		let visual = visual(at: 0)
		#expect(visual.center == Self.mouth)
		#expect(visual.scaleX == 1)
		#expect(visual.scaleY == 1)
		#expect(visual.rotationDegrees == 0)
		#expect(visual.opacity == 1)
	}

	/// The first phase is a shiver in place, not a move: it is what tells the user
	/// the icon is about to be eaten rather than just sitting there.
	@Test("It only shivers before the mouth opens")
	func shiversWhereItStands() {
		for step in 0...66 {
			let elapsed = Double(step) / 120
			let visual = visual(at: elapsed)
			#expect(visual.center.distance(to: Self.mouth) <= 4, "at \(elapsed)")
			#expect(visual.opacity == 1, "at \(elapsed)")
			#expect(abs(visual.rotationDegrees) <= 4.001, "at \(elapsed)")
			#expect(abs(visual.scaleX - 1) <= 0.036, "at \(elapsed)")
		}
	}

	@Test("It shrinks and turns as it is drawn to the mouth")
	func isDrawnInAsTheMouthOpens() {
		let visual = visual(at: 1.0)
		#expect(visual.opacity == 1, "still whole on the way in")
		#expect(visual.scaleX < 1)
		#expect(visual.scaleY < 1)
		#expect(visual.rotationDegrees < 0, "it tips as it goes")
		#expect(visual.center.x > Self.mouth.x + 20, "it has clearly left the icon")
		#expect(visual.center.x < Self.suction.x)
		#expect(visual.center.y > Self.mouth.y)
		#expect(visual.center.y < Self.suction.y + 6)
	}

	/// The animation is over a second before the chewing clip is: the original ends
	/// the food at 1.35 s and keeps chewing on an empty mouth.
	@Test("It is swallowed and gone by the end of the animation")
	func isSwallowedByTheEnd() {
		for elapsed in [MealConsumptionAnimation.vanishSeconds, 1.6, 2.4] {
			let visual = visual(at: elapsed)
			#expect(visual.center == Self.suction, "at \(elapsed)")
			#expect(visual.opacity == 0, "at \(elapsed)")
		}
	}

	@Test("It never comes back once it starts fading")
	func opacityNeverComesBack() {
		var previous = 1.0
		for step in 0...144 {
			let opacity = visual(at: Double(step) / 60).opacity
			#expect(opacity <= previous + 0.0001)
			previous = opacity
		}
	}

	/// The renderer that has to give the icon a window of its own shapes that window from
	/// this rectangle once and then leaves it alone, so the rectangle has to hold the drawn
	/// icon for the whole animation — a frame that pokes out is a frame that gets cut off.
	///
	/// Sampled against the path rather than checked field by field: the three phases reach
	/// their widest at different moments (upright and stretched on the way in, turned and
	/// shrunken at the end), and this is the claim the window actually depends on.
	@Test("The animation's box holds it for every frame")
	func boxHoldsTheWholePath() {
		let half = 28.0
		let box = MealConsumptionAnimation.box(from: Self.mouth, to: Self.suction, halfExtent: half)

		for step in 0...270 {
			let elapsed = Double(step) / 120
			let visual = visual(at: elapsed)
			let radians = visual.rotationDegrees * .pi / 180
			// The icon's own turned and stretched outline, as the transform applies it.
			let reach = half * (abs(cos(radians)) * visual.scaleX + abs(sin(radians)) * visual.scaleY)
			let drawn = PixelRect(
				x: visual.center.x - reach,
				y: visual.center.y - reach,
				width: 2 * reach,
				height: 2 * reach
			)
			#expect(
				box.contains(drawn),
				"at \(elapsed): the icon is drawn outside the box it was given"
			)
		}
	}

	/// A phase seam that does not line up shows up as a jump far larger than a
	/// frame's travel, which is at most ~9 canvas units.	@Test("The path has no jumps between frames")
	func thePathIsContinuous() {
		var previous = visual(at: 0)
		for step in 1...144 {
			let visual = visual(at: Double(step) * Self.frame)
			#expect(
				visual.center.distance(to: previous.center) < 10,
				"jumped at \(Double(step) * Self.frame)"
			)
			previous = visual
		}
	}
}
