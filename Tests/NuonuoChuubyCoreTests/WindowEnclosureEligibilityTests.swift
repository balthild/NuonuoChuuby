import Foundation
import Testing

@testable import NuonuoChuubyCore

/// Which windows may be an enclosure. A screen-sized window is a background, not
/// a box: the pet put inside one would be sealed against the whole display.
@Suite("Window enclosure eligibility")
struct WindowEnclosureEligibilityTests {
	private let monitor = Monitor(
		id: 1,
		frame: PixelRect(x: 0, y: 0, width: 1440, height: 900),
		visibleFrame: PixelRect(x: 0, y: 25, width: 1440, height: 875),
		scale: 1
	)

	@Test("An ordinary window is a bounded body")
	func ordinaryWindow() {
		#expect(
			WindowEnclosureEligibilityPolicy.isBoundedBody(
				PixelRect(x: 200, y: 300, width: 800, height: 500),
				monitors: [monitor]
			)
		)
	}

	@Test("A window filling the display frame is not")
	func fullscreenIsNot() {
		#expect(
			!WindowEnclosureEligibilityPolicy.isBoundedBody(
				PixelRect(x: 0, y: 0, width: 1440, height: 900),
				monitors: [monitor]
			)
		)
	}

	@Test("A maximised window filling the work area is not")
	func maximisedIsNot() {
		#expect(
			!WindowEnclosureEligibilityPolicy.isBoundedBody(
				PixelRect(x: 0, y: 25, width: 1440, height: 875),
				monitors: [monitor]
			)
		)
	}

	@Test("Covering the area without being anchored to it is still a box")
	func coverageWithoutAlignment() {
		// The same size, but starting elsewhere: a window that big is not chrome.
		#expect(
			WindowEnclosureEligibilityPolicy.isBoundedBody(
				PixelRect(x: 200, y: 200, width: 1440, height: 875),
				monitors: [monitor]
			)
		)
	}

	@Test("A degenerate rectangle is never a bounded body")
	func degenerate() {
		#expect(
			!WindowEnclosureEligibilityPolicy.isBoundedBody(
				PixelRect(x: 200, y: 300, width: 0, height: 500),
				monitors: [monitor]
			)
		)
	}

	@Test("Without any display every window is bounded")
	func noDisplays() {
		#expect(
			WindowEnclosureEligibilityPolicy.isBoundedBody(
				PixelRect(x: 0, y: 0, width: 1440, height: 900),
				monitors: []
			)
		)
	}
}
