import Testing

@testable import PetFoundation

@Suite("Pet size policy")
struct PetSizePolicyTests {
	@Test("Percent converts both ways")
	func percentRoundTrip() {
		#expect(PetSizePolicy.fromPercent(100) == 220)
		#expect(PetSizePolicy.toPercent(220) == 100)
		#expect(PetSizePolicy.toPercent(1_000) == 200)
		#expect(PetSizePolicy.toPercent(0) == 60)
	}

	@Test("A non-finite size falls back to the default")
	func nonFinite() {
		#expect(PetSizePolicy.clampPreferredSize(.nan) == 220)
		#expect(PetSizePolicy.clampPreferredSize(.infinity) == 220)
	}

	@Test("A tiny work area shrinks the pet but never below the minimum")
	func fitToWorkArea() {
		#expect(
			PetSizePolicy.fitToWorkArea(
				preferredSize: 220,
				workAreaWidth: 400,
				workAreaHeight: 300,
				displayScale: 1
			) == 220
		)
		#expect(
			PetSizePolicy.fitToWorkArea(
				preferredSize: 220,
				workAreaWidth: 100,
				workAreaHeight: 100,
				displayScale: 1
			) == 96
		)
	}
}
