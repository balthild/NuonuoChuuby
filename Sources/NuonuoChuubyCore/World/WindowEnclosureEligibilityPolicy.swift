import Foundation

/// Only a bounded application window may act as a physical enclosure.
///
/// A maximised or borderless fullscreen window is a background, not a box: the
/// pet dropped into one would be sealed against the whole screen. A real window
/// sitting behind the target never reaches this check — it only filters
/// enclosure candidates.
public enum WindowEnclosureEligibilityPolicy {
	/// How much of a display or its work area a window must cover to count as
	/// that display's background.
	public static let coverageRatio: Double = 0.99
	/// How close to the display's corner the window must start as well. A window
	/// that merely covers the area without being anchored to it is not chrome.
	public static let alignmentTolerance: Double = 4

	public static func isBoundedBody(_ bounds: PixelRect, monitors: [Monitor]) -> Bool {
		guard bounds.width > 0, bounds.height > 0 else { return false }
		return !monitors.contains { monitor in
			covers(bounds, monitor.frame) || covers(bounds, monitor.visibleFrame)
		}
	}

	private static func covers(_ bounds: PixelRect, _ area: PixelRect) -> Bool {
		guard area.width > 0, area.height > 0 else { return false }
		let intersection =
			max(0, min(bounds.right, area.right) - max(bounds.left, area.left))
			* max(0, min(bounds.bottom, area.bottom) - max(bounds.top, area.top))
		let areaPixels = area.width * area.height
		return intersection >= areaPixels * coverageRatio
			&& abs(bounds.top - area.top) <= alignmentTolerance
			&& abs(bounds.left - area.left) <= alignmentTolerance
	}
}
