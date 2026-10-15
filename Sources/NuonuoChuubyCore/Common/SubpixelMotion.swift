import Foundation

/// The simulation runs in continuous doubles; only whole pixels are applied to
/// the window, carrying the remainder so slow motion still advances.
public enum SubpixelMotion {
	public static func takeWholePixels(_ movement: Double, remainder: inout Double) -> Int {
		let accumulated = movement + remainder
		let wholePixels = Int(accumulated.rounded(.towardZero))
		remainder = accumulated - Double(wholePixels)
		return wholePixels
	}
}
