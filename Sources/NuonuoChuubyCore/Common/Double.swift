extension Double {
	/// This value constrained to `lower...upper`. The bounds are not reordered, so
	/// passing them backwards yields `upper`.
	func clamp(lower: Double, upper: Double) -> Double {
		Swift.min(Swift.max(self, lower), upper)
	}

	/// The classic `3t² − 2t³` ease, with `t` first constrained to `0...1`.
	func smoothstep() -> Double {
		let t = clamp(lower: 0, upper: 1)
		return t * t * (3 - 2 * t)
	}

	/// This value rounded to the nearest whole number, for display.
	///
	/// Not simply `Int(rounded())`, which traps on a value that is not finite: the
	/// bounds a value was clamped to do not make it finite, so a NaN survives
	/// clamping and reaches here.
	func roundedToInt() -> Int {
		isFinite ? Int(rounded()) : 0
	}
}
