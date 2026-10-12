import Foundation

/// Anchors expressed in 512-unit canvas space (see ``SpriteGeometry``).
public struct PetCharacterGeometry: Sendable, Equatable {
	public var footCanvasX: Double
	public var footCanvasY: Double
	public var mouthCanvasX: Double
	public var mouthCanvasY: Double
	public var lickContactCanvasX: Double
	public var lickContactCanvasY: Double
	public var slideContactCanvasX: Double
	public var bodyCollisionLeftCanvasX: Double
	public var bodyCollisionTopCanvasY: Double
	public var bodyCollisionRightCanvasX: Double
	public var bodyCollisionBottomCanvasY: Double
	public var suctionMouthCanvasX: Double
	public var suctionMouthCanvasY: Double
	public var burpOffsetCanvasX: Double = 0
	public var burpOffsetCanvasY: Double = 0
}

/// Per-character configuration. The macOS build instantiates only 糯糯, but the
/// indirection is kept intact so 菲比 can be added without a merge.
public struct PetCharacterProfile: Sendable, Equatable, Identifiable {
	public let id: String
	public let displayName: String
	/// Folder (relative to the asset root) holding `frame_NN.png` clips.
	public let runtimeRelativeDirectory: String
	/// Folder (relative to the asset root) holding the voice WAVs.
	public let voiceRelativeDirectory: String
	public let hasVoice: Bool
	public let movementSpeedMultiplier: Double
	public let maximumIdleSeconds: Double
	public let geometry: PetCharacterGeometry

	public var supportsFood: Bool { id == PetCharacterProfile.nuonuo.id }
	public var usesMischief: Bool { id == PetCharacterProfile.feibiJiubi.id }

	public static let nuonuo = PetCharacterProfile(
		id: "nuonuo",
		displayName: "糯糯",
		runtimeRelativeDirectory: "sprites/runtime",
		voiceRelativeDirectory: "audio/voice",
		hasVoice: true,
		movementSpeedMultiplier: 1,
		maximumIdleSeconds: 5,
		geometry: PetCharacterGeometry(
			footCanvasX: SpriteGeometry.footCanvasX,
			footCanvasY: SpriteGeometry.footCanvasY,
			mouthCanvasX: 45,
			mouthCanvasY: 267,
			lickContactCanvasX: 60,
			lickContactCanvasY: 334,
			slideContactCanvasX: 407,
			bodyCollisionLeftCanvasX: 92,
			bodyCollisionTopCanvasY: 92,
			bodyCollisionRightCanvasX: 416,
			bodyCollisionBottomCanvasY: 466,
			suctionMouthCanvasX: 191,
			suctionMouthCanvasY: 304
		)
	)

	public static let feibiJiubi = PetCharacterProfile(
		id: "feibijiubi",
		displayName: "菲比啾比",
		runtimeRelativeDirectory: "characters/feibijiubi/runtime",
		voiceRelativeDirectory: "characters/feibijiubi/audio",
		hasVoice: true,
		movementSpeedMultiplier: 1.15,
		maximumIdleSeconds: 4,
		geometry: PetCharacterGeometry(
			footCanvasX: SpriteGeometry.footCanvasX,
			footCanvasY: SpriteGeometry.footCanvasY,
			mouthCanvasX: 55,
			mouthCanvasY: 284,
			lickContactCanvasX: 95,
			lickContactCanvasY: 372,
			slideContactCanvasX: 436,
			bodyCollisionLeftCanvasX: 100,
			bodyCollisionTopCanvasY: 100,
			bodyCollisionRightCanvasX: 424,
			bodyCollisionBottomCanvasY: 470,
			suctionMouthCanvasX: 180,
			suctionMouthCanvasY: 284,
			burpOffsetCanvasX: 130,
			burpOffsetCanvasY: 100
		)
	)

	public static let all: [PetCharacterProfile] = [.nuonuo, .feibiJiubi]

	public static func resolve(id: String?) -> PetCharacterProfile {
		guard let id, let match = all.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
			return .nuonuo
		}
		return match
	}

	/// Feibi's clips are timed slightly faster than the shared defaults.
	func resolveFrameSeconds(clipName: String, defaultSeconds: Double) -> Double {
		guard id == PetCharacterProfile.feibiJiubi.id else { return defaultSeconds }
		switch clipName {
		case "idle": return 0.120
		case "walk": return 0.094
		case "run": return 0.058
		case "curious": return 0.112
		case "climb": return 0.071
		case "jump": return 0.063
		case "land": return 0.054
		case "roll": return 0.074
		default: return defaultSeconds
		}
	}
}
