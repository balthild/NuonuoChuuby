/// Turning a caller-supplied random value into a choice.
///
/// Callers hand the unit value in rather than drawing it themselves, so the
/// choice can be reproduced in a test. It may arrive as exactly 1, which
/// `Int(value * count)` would index one past the end of a pool, so it is pulled
/// just below 1 before use.
public enum RandomSelection {
	/// The unit value, constrained to `0..<1`.
	public static func unit(_ value: Double) -> Double {
		value.clamp(lower: 0, upper: 0.999999)
	}

	/// The entry a unit picks out of `poolOf` of them, never out of range.
	public static func index(in poolOf: Int, unit value: Double) -> Int {
		guard poolOf > 0 else { return 0 }
		return min(poolOf - 1, Int((unit(value) * Double(poolOf)).rounded(.down)))
	}
}
