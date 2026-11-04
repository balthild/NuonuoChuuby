import Testing

@testable import PetBehaviour

@Suite("Pet dialogue")
struct PetDialogueTests {
	@Test("Every cue has lines")
	func everyCueHasLines() {
		for cue in DialogueCue.allCases {
			#expect(!PetDialogueCatalog.lines(for: cue).isEmpty, "\(cue) has no lines")
		}
	}

	@Test("The selector never repeats a cue's own previous line")
	func noImmediateRepeat() {
		var selector = PetDialogueSelector()
		var previous: [DialogueCue: String] = [:]
		for _ in 0..<200 {
			let cue = DialogueCue.allCases.randomElement()!
			let line = selector.choose(cue)
			if let last = previous[cue] {
				#expect(line != last, "\(cue) repeated \(line)")
			}
			previous[cue] = line
		}
	}

	@Test("The item placeholder is substituted")
	func itemSubstitution() {
		var selector = PetDialogueSelector()
		let line = selector.choose(.tastedItem, itemName: "蛋糕")
		#expect(line.contains("蛋糕"))
		#expect(!line.contains("{item}"))
	}
}

@Suite("Mood speech")
struct PetMoodSpeechTests {
	@Test("The hunger bands report themselves, and a fed pet reports fullness")
	func bands() {
		var life = PetLifeState()
		life.hunger = 20
		life.fullness = 10
		#expect(PetMoodSpeech.line(life: life, fastingMode: false) == nil)

		life.hunger = LifeBehaviorPolicy.aBitHungryHungerThreshold
		#expect(PetMoodSpeech.line(life: life, fastingMode: false)?.cue == .aBitHungry)

		life.hunger = LifeBehaviorPolicy.veryHungryHungerThreshold
		#expect(PetMoodSpeech.line(life: life, fastingMode: false)?.cue == .veryHungry)

		life.fullness = LifeBehaviorPolicy.comfortablyFullThreshold
		#expect(PetMoodSpeech.line(life: life, fastingMode: false)?.cue == .comfortablyFull)
	}

	@Test("Fasting silences hunger but not fullness")
	func fasting() {
		var life = PetLifeState()
		life.hunger = 100
		life.fullness = 10
		#expect(PetMoodSpeech.line(life: life, fastingMode: true) == nil)

		life.fullness = LifeBehaviorPolicy.comfortablyFullThreshold
		#expect(PetMoodSpeech.line(life: life, fastingMode: true)?.cue == .comfortablyFull)
	}

	@Test("The ravenous band needs more hunger than the peckish one")
	func thresholdsAreOrdered() {
		#expect(
			LifeBehaviorPolicy.aBitHungryHungerThreshold
				< LifeBehaviorPolicy.veryHungryHungerThreshold
		)
	}
}
