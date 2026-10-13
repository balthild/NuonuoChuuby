import Foundation

/// A scripted ``Platform`` for tests: no window server, no displays to read.
@MainActor
public final class MockPlatform: Platform {
	private var scriptedWindows: [PlatformWindow]
	private var scriptedMonitors: [Monitor]

	public init(windows: [PlatformWindow] = [], monitors: [Monitor] = []) {
		self.scriptedWindows = windows
		self.scriptedMonitors = monitors
	}

	/// The list order **is** the z-order, as it is for ``MacOSPlatform``: index 0 is
	/// frontmost. Assigned here rather than left to the caller, because a scripted
	/// window's z-index defaults to 0 and every window would then claim to be
	/// frontmost — which silently flattens anything that reads z-order.
	public func windows() -> [PlatformWindow] {
		scriptedWindows.enumerated().map { index, window in
			var window = window
			window.zIndex = index
			return window
		}
	}

	public func monitors() -> [Monitor] { scriptedMonitors }

	public func setWindows(_ windows: [PlatformWindow]) { scriptedWindows = windows }
	public func setMonitors(_ monitors: [Monitor]) { scriptedMonitors = monitors }

	/// One display with a menu bar strip along the top, so a test can describe a
	/// desktop in a line.
	public static func singleMonitor(
		id: UInt32 = 1,
		width: Double = 1440,
		height: Double = 900,
		scale: Double = 1,
		menuBarHeight: Double = 25
	) -> MockPlatform {
		let frame = PixelRect(x: 0, y: 0, width: width, height: height)
		let visible = PixelRect(
			x: 0,
			y: menuBarHeight,
			width: width,
			height: height - menuBarHeight
		)
		return MockPlatform(monitors: [
			Monitor(id: id, frame: frame, visibleFrame: visible, scale: scale)
		])
	}
}
