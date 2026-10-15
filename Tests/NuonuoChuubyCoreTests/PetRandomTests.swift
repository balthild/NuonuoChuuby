import Testing

@testable import NuonuoChuubyCore

@Suite("Pet random")
struct PetRandomTests {
	@Test("The same seed gives the same sequence")
	func sameSeedSameSequence() {
		var a = PetRandom(seed: 12345)
		var b = PetRandom(seed: 12345)
		for _ in 0..<8 {
			#expect(Double.random(in: 0..<1, using: &a) == Double.random(in: 0..<1, using: &b))
		}
	}

	@Test("Different seeds diverge")
	func differentSeedsDiverge() {
		var a = PetRandom(seed: 1)
		var b = PetRandom(seed: 2)
		let drawsA = (0..<8).map { _ in Double.random(in: 0..<1, using: &a) }
		let drawsB = (0..<8).map { _ in Double.random(in: 0..<1, using: &b) }
		#expect(drawsA != drawsB)
	}

	@Test("Draws stay inside their range and do not repeat immediately")
	func drawsAreUsable() {
		var random = PetRandom(seed: 99)
		var seen = Set<Double>()
		for _ in 0..<100 {
			let value = Double.random(in: 0.5...1.6, using: &random)
			#expect(value >= 0.5 && value <= 1.6)
			seen.insert(value)
		}
		// A generator stuck on one value would still be "in range".
		#expect(seen.count > 90)
	}
}
