extension Double {
	/// This value constrained to `lower...upper`. The bounds are not reordered, so
	/// passing them backwards yields `upper`.
	func clamp(lower: Double, upper: Double) -> Double {
		Swift.min(Swift.max(self, lower), upper)
	}
}
