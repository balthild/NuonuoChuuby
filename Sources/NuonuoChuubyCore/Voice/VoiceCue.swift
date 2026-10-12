import Foundation

public enum VoiceCue: String, Sendable, CaseIterable {
	case neutral
	case affirmative
	case sad
	case positive
	case scream
	case panic
	case calm
	case aggrieved
	case question
	case landing
}

public enum VoicePriority: Int, Sendable, Comparable {
	case ambient = 0
	case normal = 1
	case important = 2
	case critical = 3

	public static func < (lhs: VoicePriority, rhs: VoicePriority) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

/// Each cue maps to one or more recorded files. The rotation policy keeps a cue
/// from sounding like a single loop.
public enum VoiceCueCatalog {
	static let nuonuoFiles: [VoiceCue: [String]] = [
		.neutral: [
			"糯糯_002.wav", "糯糯_015.wav", "糯糯_017.wav", "糯糯_018.wav", "糯糯_019.wav",
			"糯糯_024.wav", "糯糯_030.wav", "糯糯_正常.wav", "糯糯_正常02.wav", "糯糯_正常03.wav",
			"糯糯_正常04.wav",
		],
		.affirmative: ["糯糯_表示肯定.wav"],
		.sad: ["糯糯_超级伤心.wav"],
		.positive: ["糯糯_积极.wav"],
		.scream: [
			"糯糯_快速.wav", "糯糯_015.wav", "糯糯_017.wav", "糯糯_024.wav", "糯糯_正常.wav",
			"糯糯_正常03.wav", "糯糯_有点委屈.wav",
		],
		.panic: ["糯糯_惊恐_控制不住自己.wav"],
		.calm: ["糯糯_冷静.wav"],
		.aggrieved: ["糯糯_委屈.wav", "糯糯_有点委屈.wav"],
		.question: ["糯糯_疑问.wav"],
		.landing: ["糯糯_软.wav", "糯糯_有点委屈.wav"],
	]

	public static func fileNames(
		for cue: VoiceCue,
		character: PetCharacterProfile = .nuonuo
	) -> [String] {
		if character.usesMischief {
			return []
		}
		return nuonuoFiles[cue] ?? []
	}

	public static func allFileNames(for character: PetCharacterProfile = .nuonuo) -> [String] {
		if character.usesMischief { return [] }
		return Set(nuonuoFiles.values.flatMap { $0 }).sorted()
	}
}
