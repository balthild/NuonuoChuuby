import Foundation
import Testing

@testable import NuonuoChuubyCore

@Suite("Hunger display")
struct HungerDisplayPolicyTests {
	@Test("The bands break where the original's did")
	func bands() {
		#expect(HungerDisplayPolicy.band(forHunger: 0) == .comfortable)
		#expect(HungerDisplayPolicy.band(forHunger: 54.9) == .comfortable)
		#expect(HungerDisplayPolicy.band(forHunger: 55) == .hungry)
		#expect(HungerDisplayPolicy.band(forHunger: 79.9) == .hungry)
		#expect(HungerDisplayPolicy.band(forHunger: 80) == .veryHungry)
		#expect(HungerDisplayPolicy.band(forHunger: 100) == .veryHungry)
	}

	@Test("A percentage is a whole number, rounded and clamped")
	func percentage() {
		#expect(HungerDisplayPolicy.percentage(forHunger: 36) == 36)
		#expect(HungerDisplayPolicy.percentage(forHunger: 35.6) == 36)
		#expect(HungerDisplayPolicy.percentage(forHunger: -5) == 0)
		#expect(HungerDisplayPolicy.percentage(forHunger: 140) == 100)
	}

	@Test("A value that is not finite still renders")
	func nonFinite() {
		// The guard lives in `Double.roundedToInt`, since clamping to 0…100 leaves a
		// NaN a NaN.
		#expect(HungerDisplayPolicy.percentage(forHunger: .nan) == 0)
	}
}
