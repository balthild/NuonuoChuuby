import Foundation
import Testing

@testable import NuonuoChuubyCore

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

	@Test("A pet at the left edge does not push the bubble off screen")
	func leftEdgeClamp() {
		let placement = place(petX: -60, petY: 500)
		#expect(placement.topLeft.x >= workArea.left)
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

	@Test("A pet at the right edge does not push the bubble off screen")
	func rightEdgeClamp() {
		let placement = place(petX: 1380, petY: 500)
		#expect(placement.topLeft.x + 70 <= workArea.right)
	}

	@Test("No room above moves the bubble to the right of the pet, tail left")
	func fallsBackToTheRightSide() {
		// The pet is high enough that its own top is above the work area, so the
		// bubble cannot sit above it.
		let placement = place(petX: 600, petY: -100)
		// Pushed down only as far as the menu bar, which it must not cover.
		#expect(placement.topLeft.y == display.visibleFrame.top)
		#expect(placement.topLeft.x == 600 + 220 + 6)
		// The tail is on the bubble's left edge, so it points back at the pet.
		#expect(placement.tail == .left)
	}

	@Test("With no room on the right the bubble moves to the pet's left, tail right")
	func fallsBackToTheLeftSide() {
		// The pet's right edge is too close to the display's edge for the bubble
		// to fit beside it.
		let placement = place(petX: 1280, petY: -100, petSize: 160)
		#expect(placement.tail == .right)
		// The tail's tip stops one gap short of the pet's left edge.
		#expect(placement.topLeft.x + 70 + tailHeight == 1280 - 6)
	}

	@Test("With no room on either side the tail points down and stays on screen")
	func fallbackStaysOnScreen() {
		// A pet filling most of the width leaves no side room.
		let placement = SpeechBubbleLayout.place(
			petFrame: PixelRect(x: 0, y: 25, width: 1440, height: 220),
			contentWidth: 70,
			contentHeight: 34,
			tailHeight: tailHeight,
			area: workArea
		)
		#expect(placement.tail == .down)
		#expect(placement.topLeft.x >= workArea.left)
		#expect(placement.topLeft.x + 70 <= workArea.right)
		#expect(placement.topLeft.y >= workArea.top)
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
