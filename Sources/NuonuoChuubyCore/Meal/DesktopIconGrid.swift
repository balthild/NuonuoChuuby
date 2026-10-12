import Foundation

/// Approximates where Finder puts desktop icons.
///
/// macOS exposes no API for real icon positions — the only accurate source is
/// the Finder's own AppleScript dictionary, which needs an automation grant — so
/// this models Finder's *default* layout instead: a column down the right edge,
/// flowing leftwards. It is a plausible target for "she walks over and licks an
/// icon", and deliberately not presented as the icon's true position.
public enum DesktopIconGrid {
	public static let verticalSpacing: Double = 90
	public static let horizontalSpacing: Double = 110
	public static let firstInsetRight: Double = 60
	public static let firstInsetTop: Double = 60

	/// `xIndex` 0 is the rightmost column; `yIndex` 0 is the topmost icon.
	public static func position(
		xIndex: Int, yIndex: Int, in workArea: PixelRect
	) -> PixelPoint {
		PixelPoint(
			x: workArea.right - firstInsetRight - Double(xIndex) * horizontalSpacing,
			y: workArea.top + firstInsetTop + Double(yIndex) * verticalSpacing)
	}

	/// The first `count` icon slots, in the order Finder fills them.
	public static func positions(count: Int, in workArea: PixelRect, maxRows: Int = 8) -> [PixelPoint] {
		guard count > 0, maxRows > 0 else { return [] }
		return (0..<count).map { index in
			position(xIndex: index / maxRows, yIndex: index % maxRows, in: workArea)
		}
	}
}
