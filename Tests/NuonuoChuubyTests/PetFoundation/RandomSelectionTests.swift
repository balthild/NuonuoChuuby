import Testing

@testable import PetFoundation

@Suite("Random selection")
struct RandomSelectionTests {
	@Test("A unit of exactly one still lands inside the pool")
	func unitOfOneStaysInRange() {
		// The reason the clamp exists: `Int(1 * count)` is one past the end.
		#expect(RandomSelection.unit(1) < 1)
		#expect(RandomSelection.index(in: 8, unit: 1) == 7)
	}

	@Test("The unit selects the matching entry")
	func indexFollowsTheUnit() {
		#expect(RandomSelection.index(in: 4, unit: 0) == 0)
		#expect(RandomSelection.index(in: 4, unit: 0.25) == 1)
		#expect(RandomSelection.index(in: 4, unit: 0.99) == 3)
	}

	@Test("Out-of-range and empty input cannot index out of bounds")
	func degenerateInput() {
		#expect(RandomSelection.unit(-5) == 0)
		#expect(RandomSelection.index(in: 4, unit: -5) == 0)
		#expect(RandomSelection.index(in: 0, unit: 0.5) == 0)
		#expect(RandomSelection.index(in: 1, unit: 0.5) == 0)
	}
}
