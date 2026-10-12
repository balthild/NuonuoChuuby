import Foundation

/// Whether a fullscreen app is covering a display.
///
/// A pure function over the window list and the displays, so it can be tested
/// without a Mac in front of it. A fullscreen window is an ordinary (layer 0)
/// window whose edges meet a monitor's frame within a small tolerance; a merely
/// maximised window stops at the menu bar and so does not count.
public enum FullscreenDetector {
	/// How far off a perfect match still counts. Window bounds and display frames
	/// are both in points, so a pixel or two of rounding is normal.
	public static let tolerance: Double = 2

	public static func isFullscreenAppActive(
		windows: [PlatformWindow], monitors: [Monitor]
	) -> Bool {
		guard !monitors.isEmpty else { return false }
		return windows.contains { window in
			window.layer == 0 && monitors.contains { covers($0.frame, window.bounds) }
		}
	}

	static func covers(_ monitor: PixelRect, _ window: PixelRect) -> Bool {
		abs(window.left - monitor.left) <= tolerance
			&& abs(window.top - monitor.top) <= tolerance
			&& abs(window.right - monitor.right) <= tolerance
			&& abs(window.bottom - monitor.bottom) <= tolerance
	}
}
