import Foundation
import Testing

@testable import PetBehaviour
@testable import PetDesktop
@testable import PetFoundation

@Suite("Speech bubble layout")
struct SpeechBubbleLayoutTests {
	// A 1440x900 display whose menu bar takes the top 25 points.
	private let display = Monitor(
		id: 1,
		frame: PixelRect(x: 0, y: 0, width: 1440, height: 900),
		visibleFrame: PixelRect(x: 0, y: 25, width: 1440, height: 875),
		scale: 1
	)
	private var workArea: PixelRect { SpeechBubbleLayout.area(for: display) }
	private let tailHeight = 7.0

	private func place(
		petX: Double,
		petY: Double,
		petSize: Double = 220,
		bodyWidth: Double = 70,
		bodyHeight: Double = 34
	) -> SpeechBubblePlacement {
		SpeechBubbleLayout.place(
			petFrame: PixelRect(x: petX, y: petY, width: petSize, height: petSize),
			contentWidth: bodyWidth,
			contentHeight: bodyHeight,
			tailHeight: tailHeight,
			area: workArea
		)
	}

	@Test("The bubble is centred on the pet when there is room")
	func centred() {
		let placement = place(petX: 600, petY: 500)
		#expect(abs(placement.topLeft.x - (600 + 110 - 35)) < 0.001)
	}

	@Test("The bubble sits above the pet, its body bottom inside the panel top")
	func aboveThePet() {
		let placement = place(petX: 600, petY: 500)
		// 500 + 0.16*220 = 535.2 → rounded 535, minus the body and the tail.
		#expect(abs(placement.topLeft.y - (535 - 34 - 7)) < 0.001)
		#expect(placement.topLeft.y + 34 < 500 + 220)
		#expect(placement.tail == .down)
	}

	@Test("A pet at the left edge lets the bubble run off the display")
	func leftEdgeOverflows() {
		// Deliberate: it stays centred on her rather than being pushed inward, and the
		// line loses a character or two to the screen edge.
		let placement = place(petX: -60, petY: 500, bodyWidth: 200)
		#expect(placement.topLeft.x < workArea.left)
		// Still centred on her: half her panel, less half the bubble.
		#expect(abs(placement.topLeft.x - (-60 + 110 - 100)) < 0.001)
	}

	@Test("A Dock on the left does not hold the bubble away from her")
	func dockStripIsUsable() {
		// She is drawn over the Dock and can be dragged into it, so the bubble must
		// be able to sit there too. The work area starts 85 points in.
		let docked = Monitor(
			id: 2,
			frame: PixelRect(x: 0, y: 0, width: 1440, height: 900),
			visibleFrame: PixelRect(x: 85, y: 25, width: 1355, height: 875),
			scale: 1
		)
		let area = SpeechBubbleLayout.area(for: docked)
		#expect(area.left == docked.frame.left)
		#expect(area.right == docked.frame.right)
		#expect(area.top == docked.visibleFrame.top)

		// Centred on her, not pushed to the work area's edge.
		let placement = SpeechBubbleLayout.place(
			petFrame: PixelRect(x: 0, y: 500, width: 220, height: 220),
			contentWidth: 200,
			contentHeight: 34,
			tailHeight: tailHeight,
			area: area
		)
		#expect(abs(placement.topLeft.x - (110 - 100)) < 0.001)
		#expect(placement.topLeft.x < docked.visibleFrame.left)
	}

	@Test("A pet at the right edge lets the bubble run off the display")
	func rightEdgeOverflows() {
		let placement = place(petX: 1380, petY: 500, bodyWidth: 200)
		#expect(placement.topLeft.x + 200 > workArea.right)
	}

	@Test("Her head off the screen moves the bubble underneath her, tail up")
	func belowWhenHerHeadIsOffScreen() {
		// 125 points of her panel are above the work area, so the bubble cannot sit
		// above her head — there is nowhere there to put it.
		let placement = place(petX: 600, petY: -100)
		#expect(placement.tail == .up)
		// The tail's tip starts at her feet and the body is centred on her.
		#expect(placement.topLeft.y == -100 + 220)
		#expect(abs(placement.topLeft.x - (710 - 35)) < 0.001)
	}

	@Test("A bubble with no room above goes under her feet, never beside her")
	func neverBesideHer() {
		// Her panel's top is above the work area, so the bubble does not fit above her —
		// and beside her is not an option at any position.
		let placement = place(petX: 600, petY: 10)
		#expect(placement.tail == .up)
		#expect(placement.topLeft.y == 10 + 220)
		#expect(abs(placement.topLeft.x - (710 - 35)) < 0.001)
	}

	@Test("A bubble wider than the room beside her still goes above her")
	func wideBubbleStillGoesAbove() {
		// The old layout would have moved this one to a side, or dropped its tail; both
		// needed horizontal room, which is what the position no longer depends on.
		let placement = SpeechBubbleLayout.place(
			petFrame: PixelRect(x: 0, y: 500, width: 220, height: 220),
			contentWidth: 400,
			contentHeight: 34,
			tailHeight: tailHeight,
			area: workArea
		)
		#expect(placement.tail == .down)
		#expect(abs(placement.topLeft.x - (110 - 200)) < 0.001)
	}

	@Test("A bubble taller than the work area still lands on screen")
	func oversizedBubble() {
		let placement = SpeechBubbleLayout.place(
			petFrame: PixelRect(x: 600, y: 25, width: 220, height: 220),
			contentWidth: 70,
			contentHeight: 2000,
			tailHeight: tailHeight,
			area: workArea
		)
		#expect(placement.topLeft.y == workArea.top)
	}
}
