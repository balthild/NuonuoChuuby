import Testing

@testable import PetFoundation

@Suite("Character profile")
struct PetCharacterProfileTests {
	@Test("An unknown id falls back to 糯糯")
	func fallback() {
		#expect(PetCharacterProfile.resolve(id: "nope").id == "nuonuo")
		#expect(PetCharacterProfile.resolve(id: nil).id == "nuonuo")
		#expect(PetCharacterProfile.resolve(id: "FEIBIJIUBI").id == "feibijiubi")
	}

	@Test("Character flags follow the id")
	func flags() {
		#expect(PetCharacterProfile.nuonuo.supportsFood)
		#expect(!PetCharacterProfile.nuonuo.usesMischief)
		#expect(PetCharacterProfile.feibiJiubi.usesMischief)
		#expect(!PetCharacterProfile.feibiJiubi.supportsFood)
	}
}
