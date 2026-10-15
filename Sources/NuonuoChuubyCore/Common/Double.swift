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
}
