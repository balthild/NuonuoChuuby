import Testing

@testable import PetFoundation

@Suite("Double helpers")
struct DoubleHelperTests {
	@Test("Clamping saturates at the bounds and passes values through")
	func clamp() {
		#expect(0.5.clamp(lower: 0, upper: 1) == 0.5)
		#expect((-3.0).clamp(lower: 0, upper: 1) == 0)
		#expect(7.0.clamp(lower: 0, upper: 1) == 1)
	}

	@Test("Smoothstep eases between its plateaus")
	func smoothstep() {
		#expect(0.0.smoothstep() == 0)
		#expect(1.0.smoothstep() == 1)
		#expect(abs(0.5.smoothstep() - 0.5) < 0.0001)
		// Out-of-range input sits on a plateau rather than overshooting.
		#expect((-2.0).smoothstep() == 0)
		#expect(3.0.smoothstep() == 1)
	}

	@Test("Rounding to a whole number survives a non-finite value")
	func roundedToInt() {
		#expect(36.4.roundedToInt() == 36)
		#expect(36.5.roundedToInt() == 37)
		// Clamping does not make a NaN finite, so the guard has to be here: a bare
		// `Int(rounded())` traps on it.
		#expect(Double.nan.roundedToInt() == 0)
		#expect(Double.infinity.roundedToInt() == 0)
	}
}
