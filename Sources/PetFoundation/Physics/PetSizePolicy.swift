import Foundation

public enum PetSizePolicy {
	public static let defaultSize: Double = 220
	public static let minimumPercent = 60
	public static let maximumPercent = 200
	public static let minimumFittedSize: Double = 96

	public static func clampPreferredSize(_ size: Double) -> Double {
		guard size.isFinite else { return defaultSize }
		return min(max(size, fromPercent(minimumPercent)), fromPercent(maximumPercent))
	}

	public static func fromPercent(_ percent: Int) -> Double {
		defaultSize * Double(min(max(percent, minimumPercent), maximumPercent)) / 100
	}

	public static func toPercent(_ size: Double) -> Int {
		let raw = (clampPreferredSize(size) / defaultSize * 100).rounded()
		return min(max(Int(raw), minimumPercent), maximumPercent)
	}

	/// A pet must fit inside a very small work area (e.g. a tiny virtual display).
	public static func fitToWorkArea(
		preferredSize: Double,
		workAreaWidth: Double,
		workAreaHeight: Double,
		displayScale: Double
	) -> Double {
		let limiting = max(1, min(workAreaWidth, workAreaHeight))
		let safeScale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
		let maximumSize = limiting * 0.78 / safeScale
		return max(minimumFittedSize, min(clampPreferredSize(preferredSize), maximumSize))
	}
}
