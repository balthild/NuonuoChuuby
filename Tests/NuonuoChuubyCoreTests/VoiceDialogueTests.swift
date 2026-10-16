import Foundation
import Testing

@testable import NuonuoChuubyCore

@Suite("Voice cue catalog")
struct VoiceCueCatalogTests {
	@Test("Every cue 糯糯 can speak has at least one recording")
	func everyCueHasFiles() {
		for cue in VoiceCue.allCases {
			#expect(!VoiceCueCatalog.fileNames(for: cue).isEmpty, "\(cue) has no recording")
		}
	}

	@Test("The neutral cue rotates through many takes")
	func neutralRotates() {
		#expect(VoiceCueCatalog.fileNames(for: .neutral).count >= 10)
	}

	@Test("The full list is de-duplicated and sorted")
	func allFileNames() {
		let all = VoiceCueCatalog.allFileNames()
		#expect(Set(all).count == all.count)
		#expect(all == all.sorted())
		// 糯糯 ships exactly 21 recordings.
		#expect(all.count == 21)
	}
}

@Suite("Voice playback policy")
struct VoicePlaybackPolicyTests {
	@Test("A cooldown blocks a repeat until it elapses")
	func cooldown() {
		let now = Date()
		let started = now.addingTimeInterval(-5)
		#expect(VoicePlaybackPolicy.isCoolingDown(now: now, lastStartedAt: started, cooldown: 12))
		#expect(!VoicePlaybackPolicy.isCoolingDown(now: now, lastStartedAt: started, cooldown: 3))
	}

	@Test("Fresh files exclude anything played recently")
	func freshFiles() {
		let now = Date()
		let files = ["a.wav", "b.wav", "c.wav"]
		let lastStarted = ["a.wav": now.addingTimeInterval(-2), "c.wav": now.addingTimeInterval(-30)]
		let fresh = VoicePlaybackPolicy.freshFiles(
			available: files,
			lastFileStarted: lastStarted,
			now: now
		)
		#expect(fresh == ["b.wav", "c.wav"])
	}

	@Test("Rotation avoids the cue's previous pick and the overall previous pick")
	func rotationAvoidsRepeat() {
		let candidates = VoicePlaybackPolicy.rotationCandidates(
			freshFiles: ["a.wav", "b.wav", "c.wav"],
			previousFileForCue: "a.wav",
			previousFileOverall: "b.wav"
		)
		#expect(candidates == ["c.wav"])
	}

	@Test("Rotation falls back when avoiding everything would leave nothing")
	func rotationFallsBack() {
		let candidates = VoicePlaybackPolicy.rotationCandidates(
			freshFiles: ["a.wav"],
			previousFileForCue: "a.wav",
			previousFileOverall: "a.wav"
		)
		#expect(candidates == ["a.wav"])
	}
}

@Suite("Voice loudness")
struct VoiceLoudnessTests {
	private func index(_ clips: [(String, String, Double)]) -> VoiceLoudness {
		let items = clips.map {
			"{\"Character\":\"\($0.0)\",\"File\":\"\($0.1)\",\"Gain\":\($0.2)}"
		}.joined(separator: ",")
		let json = "{\"Clips\":[\(items)]}"
		let url = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("voice-levels-\(UUID().uuidString).json")
		try? json.data(using: .utf8)?.write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }
		return VoiceLoudness.load(from: url)
	}

	@Test("A recorded gain is applied")
	func gainApplied() {
		let loudness = index([("nuonuo", "糯糯_002.wav", 0.5)])
		#expect(loudness.gain(character: "nuonuo", file: "糯糯_002.wav") == 0.5)
		#expect(loudness.volume(character: "nuonuo", file: "糯糯_002.wav", requested: 1) == 0.5)
	}

	@Test("An unknown file plays at full level")
	func unknownFile() {
		let loudness = index([("nuonuo", "x.wav", 0.5)])
		#expect(loudness.gain(character: "nuonuo", file: "y.wav") == 1)
		#expect(loudness.gain(character: "nuonuo", file: nil) == 1)
	}

	@Test("Requested volume is clamped before the gain is applied")
	func clampedVolume() {
		let loudness = index([("nuonuo", "x.wav", 0.5)])
		#expect(loudness.volume(character: "nuonuo", file: "x.wav", requested: 2) == 0.5)
		#expect(loudness.volume(character: "nuonuo", file: "x.wav", requested: -1) == 0)
	}

	@Test("A missing index is tolerated")
	func missingIndex() {
		let loudness = VoiceLoudness.load(from: URL(fileURLWithPath: "/nonexistent/voice-levels.json"))
		#expect(loudness.gain(character: "nuonuo", file: "x.wav") == 1)
	}
}

@Suite("Landing voice policy")
struct LandingVoicePolicyTests {
	@Test("A long fall earns a reaction")
	func longFall() {
		#expect(
			LandingVoicePolicy.shouldReact(
				fallDistancePixels: 100,
				downwardImpactSpeed: 0,
				reason: "released",
				displayScale: 1
			)
		)
	}

	@Test("A short drop stays quiet")
	func shortDrop() {
		#expect(
			!LandingVoicePolicy.shouldReact(
				fallDistancePixels: 20,
				downwardImpactSpeed: 50,
				reason: "released",
				displayScale: 1
			)
		)
	}

	@Test("A thrown pet reacts on impact speed alone")
	func thrownPet() {
		#expect(
			LandingVoicePolicy.shouldReact(
				fallDistancePixels: 10,
				downwardImpactSpeed: 400,
				reason: "DragThrow",
				displayScale: 1
			)
		)
		#expect(
			!LandingVoicePolicy.shouldReact(
				fallDistancePixels: 10,
				downwardImpactSpeed: 200,
				reason: "DragThrow",
				displayScale: 1
			)
		)
	}
}

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

@Suite("Diagnostic privacy")
struct DiagnosticPrivacyTests {
	@Test("Paths and e-mails are replaced by references")
	func redaction() {
		let log = DiagnosticsLog()
		let text = DiagnosticsPrivacy.message(
			"opened /Users/someone/Secret/file.txt and mailed a@b.com",
			reference: log.reference
		)
		#expect(!text.contains("Secret"))
		#expect(!text.contains("a@b.com"))
		#expect(text.contains("[private:"))
	}

	@Test("A reference is stable within a session but hides the value")
	func referenceStability() {
		let log = DiagnosticsLog()
		let first = log.reference("/Users/someone/file")
		let second = log.reference("/Users/someone/file")
		let other = log.reference("/Users/someone/other")
		#expect(first == second)
		#expect(first != other)
		#expect(!first.contains("someone"))
	}

	@Test("Newlines are flattened")
	func flattening() {
		#expect(DiagnosticsPrivacy.message("a\nb\rc") == "a b c")
	}
}
