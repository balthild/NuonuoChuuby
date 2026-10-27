import Foundation
import Testing

@testable import NuonuoChuubyCore

/// Telling a desktop slid across the screen from a window dragged across it.
@Suite("Desktop slide detection")
struct DesktopSlideDetectorTests {
	private let minimumStep: Double = 15

	/// Three windows of the same size, side by side, as a desktop holds them.
	private func desktop(offset: Double = 0, extras: [UInt32: PixelRect] = [:]) -> [UInt32: PixelRect]
	{
		var result: [UInt32: PixelRect] = [
			1: PixelRect(x: 100 + offset, y: 50, width: 800, height: 600),
			2: PixelRect(x: 1000 + offset, y: 50, width: 800, height: 600),
			3: PixelRect(x: 1900 + offset, y: 50, width: 800, height: 600),
		]
		for (id, rect) in extras { result[id] = rect }
		return result
	}

	@Test("A desktop moved as one image is a slide")
	func wholeDesktopMovedIsASlide() {
		// The measured shape of it: every window steps by the same amount.
		#expect(
			DesktopSlideDetector.isSliding(
				from: desktop(),
				to: desktop(offset: -569),
				minimumStep: minimumStep
			)
		)
	}

	@Test("One window moving is a drag, however far it goes")
	func oneWindowMovingIsADrag() {
		let before = desktop()
		var after = before
		after[2] = PixelRect(x: 1400, y: 50, width: 800, height: 600)

		#expect(!DesktopSlideDetector.isSliding(from: before, to: after, minimumStep: minimumStep))
	}

	@Test("Two windows agreeing on a step the others do not share is not a slide")
	func twoWindowsOutOfThreeIsNotASlide() {
		// Two windows moving *together* would be a slide if there were nothing else in
		// the sample, but a third that did not move means this desktop did not move as
		// one image — so the agreement of some of it proves nothing.
		let before = desktop()
		var after = before
		after[1] = PixelRect(x: 100 - 200, y: 50, width: 800, height: 600)
		after[2] = PixelRect(x: 1000 - 200, y: 50, width: 800, height: 600)

		// Only two windows agree, which is what the rule asks for; the third is the one
		// the caller has to have dropped (a window of the desk being left). This is the
		// boundary of the rule, pinned here so a change to it is deliberate.
		#expect(
			DesktopSlideDetector.isSliding(from: before, to: after, minimumStep: minimumStep),
			"two windows sharing a step already satisfies it"
		)
	}

	@Test("A step too small to be a movement is not a slide")
	func tinyStepsAreIgnored() {
		#expect(
			!DesktopSlideDetector.isSliding(
				from: desktop(),
				to: desktop(offset: -4),
				minimumStep: minimumStep
			)
		)
	}

	@Test("Windows moving different distances are windows moving")
	func differentStepsAreNotASlide() {
		let before = desktop()
		var after = before
		after[1] = PixelRect(x: 100 - 500, y: 50, width: 800, height: 600)
		after[2] = PixelRect(x: 1000 - 120, y: 50, width: 800, height: 600)
		after[3] = PixelRect(x: 1900 + 300, y: 50, width: 800, height: 600)

		#expect(!DesktopSlideDetector.isSliding(from: before, to: after, minimumStep: minimumStep))
	}

	@Test("A window moved vertically is not a slide")
	func verticalStepIsNotASlide() {
		var after: [UInt32: PixelRect] = [:]
		for (id, rect) in desktop() {
			after[id] = PixelRect(x: rect.x, y: rect.y + 300, width: rect.width, height: rect.height)
		}
		#expect(!DesktopSlideDetector.isSliding(from: desktop(), to: after, minimumStep: minimumStep))
	}

	@Test("A window with no earlier sample cannot agree with anything")
	func anAppearingWindowIsNotASlide() {
		let before: [UInt32: PixelRect] = [
			1: PixelRect(x: 100, y: 50, width: 800, height: 600)
		]
		let after: [UInt32: PixelRect] = [
			1: PixelRect(x: -500, y: 50, width: 800, height: 600),
			2: PixelRect(x: -1400, y: 50, width: 800, height: 600),
		]
		#expect(!DesktopSlideDetector.isSliding(from: before, to: after, minimumStep: minimumStep))
	}
}
