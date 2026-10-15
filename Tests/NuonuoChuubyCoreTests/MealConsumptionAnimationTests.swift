import Testing

@testable import NuonuoChuubyCore

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

	/// A phase seam that does not line up shows up as a jump far larger than a
	/// frame's travel, which is at most ~9 canvas units.
	@Test("The path has no jumps between frames")
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
