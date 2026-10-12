import Foundation
import Testing

@testable import NuonuoChuubyCore

@Suite("Fullscreen detector")
struct FullscreenDetectorTests {
	private let monitor = Monitor(
		id: 1,
		frame: PixelRect(x: 0, y: 0, width: 1728, height: 1117),
		visibleFrame: PixelRect(x: 0, y: 37, width: 1728, height: 1080),
		scale: 2
	)

	private func window(
		id: UInt32 = 1,
		layer: Int = 0,
		x: Double = 0,
		y: Double = 0,
		width: Double = 1728,
		height: Double = 1117
	) -> PlatformWindow {
		PlatformWindow(
			id: id,
			ownerPID: 900,
			ownerName: "Game",
			bounds: PixelRect(x: x, y: y, width: width, height: height),
			layer: layer,
			alpha: 1
		)
	}

	@Test("A layer-0 window matching a monitor is fullscreen")
	func exactMatch() {
		#expect(
			FullscreenDetector.isFullscreenAppActive(windows: [window()], monitors: [monitor])
		)
	}

	@Test("A pixel or two of rounding still counts")
	func withinTolerance() {
		#expect(
			FullscreenDetector.isFullscreenAppActive(
				windows: [window(x: 1, y: 1, width: 1725, height: 1114)],
				monitors: [monitor]
			)
		)
	}

	@Test("A window inset beyond the tolerance is not fullscreen")
	func tooSmall() {
		// A maximised window stops at the menu bar rather than filling the frame.
		#expect(
			!FullscreenDetector.isFullscreenAppActive(
				windows: [window(y: 37, height: 1080)],
				monitors: [monitor]
			)
		)
	}

	@Test("A raised window is not fullscreen")
	func raisedWindowIgnored() {
		#expect(
			!FullscreenDetector.isFullscreenAppActive(
				windows: [window(layer: 3)],
				monitors: [monitor]
			)
		)
	}

	@Test("No monitors means nothing is fullscreen")
	func noMonitors() {
		#expect(!FullscreenDetector.isFullscreenAppActive(windows: [window()], monitors: []))
	}
}
