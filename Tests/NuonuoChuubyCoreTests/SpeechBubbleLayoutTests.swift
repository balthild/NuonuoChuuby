import Foundation
import Testing

@testable import NuonuoChuubyCore

@Suite("Speech bubble layout")
struct SpeechBubbleLayoutTests {
	// A 1440x900 display whose menu bar takes the top 25 points.
	private let workArea = PixelRect(x: 0, y: 25, width: 1440, height: 875)

	private func place(
		petX: Double,
		petY: Double,
		petSize: Double = 220,
		bubbleWidth: Double = 70,
		bubbleHeight: Double = 34
	) -> PixelPoint {
		SpeechBubbleLayout.topLeft(
			petFrame: PixelRect(x: petX, y: petY, width: petSize, height: petSize),
			bubbleWidth: bubbleWidth,
			bubbleHeight: bubbleHeight,
			workArea: workArea
		)
	}

	@Test("The bubble is centred on the pet when there is room")
	func centred() {
		let topLeft = place(petX: 600, petY: 500)
		#expect(abs(topLeft.x - (600 + 110 - 35)) < 0.001)
	}

	@Test("The bubble sits above the pet, its bottom inside the panel top")
	func aboveThePet() {
		let topLeft = place(petX: 600, petY: 500)
		// 500 + 0.16*220 = 535.2 → rounded 535, minus the bubble height.
		#expect(abs(topLeft.y - (535 - 34)) < 0.001)
		#expect(topLeft.y + 34 < 500 + 220)
	}

	@Test("A pet at the left edge does not push the bubble off screen")
	func leftEdgeClamp() {
		let topLeft = place(petX: -60, petY: 500)
		#expect(topLeft.x >= workArea.left)
	}

	@Test("A pet at the right edge does not push the bubble off screen")
	func rightEdgeClamp() {
		let topLeft = place(petX: 1380, petY: 500)
		#expect(topLeft.x + 70 <= workArea.right)
	}

	@Test("No room above tucks the bubble into the pet and beside it")
	func fallsBackBesideThePet() {
		// The pet is high enough that its own top is above the work area, so the
		// bubble cannot sit above it.
		let topLeft = place(petX: 600, petY: -100)
		#expect(topLeft.y == workArea.top)
		// With room on the right, it moves there.
		#expect(topLeft.x == 600 + 220 + 6)
	}

	@Test("With no room on either side the fallback keeps it on screen")
	func fallbackStaysOnScreen() {
		// A pet filling most of the width leaves no side room.
		let topLeft = SpeechBubbleLayout.topLeft(
			petFrame: PixelRect(x: 0, y: 25, width: 1440, height: 220),
			bubbleWidth: 70,
			bubbleHeight: 34,
			workArea: workArea
		)
		#expect(topLeft.x >= workArea.left)
		#expect(topLeft.x + 70 <= workArea.right)
		#expect(topLeft.y >= workArea.top)
	}

	@Test("A bubble taller than the work area still lands on screen")
	func oversizedBubble() {
		let topLeft = SpeechBubbleLayout.topLeft(
			petFrame: PixelRect(x: 600, y: 25, width: 220, height: 220),
			bubbleWidth: 70,
			bubbleHeight: 2000,
			workArea: workArea
		)
		#expect(topLeft.y == workArea.top)
	}
}
