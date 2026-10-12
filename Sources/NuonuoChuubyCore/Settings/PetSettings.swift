import Foundation

/// Durable user preferences.
public struct PetSettings: Sendable, Equatable, Codable {
	public static let currentVersion = 1

	public var version: Int = PetSettings.currentVersion
	public var characterId: String = PetCharacterProfile.nuonuo.id
	public var reactToDeletes: Bool = true
	public var soundEnabled: Bool = true
	public var fastingMode: Bool = false
	public var infiniteMode: Bool = false
	public var coexistenceMode: Bool = false
	public var showSpeechBubbles: Bool = true
	public var quietMode: Bool = false
	public var allowMischief: Bool = true
	public var voiceVolume: Double = 0.72
	public var petSize: Double = PetSizePolicy.defaultSize
	public var watchedFolders: [String] = []

	public init() {}

	public var character: PetCharacterProfile { PetCharacterProfile.resolve(id: characterId) }

	/// Clamps every field that has a valid range, so a hand-edited file cannot
	/// put the pet into an impossible state.
	public mutating func normalize() {
		characterId = PetCharacterProfile.resolve(id: characterId).id
		voiceVolume = voiceVolume.isFinite ? min(max(voiceVolume, 0), 1) : 0.72
		petSize = PetSizePolicy.clampPreferredSize(petSize)
	}
}

public struct SettingsStore: Sendable {
	public let path: URL

	public init(path: URL) {
		self.path = path
	}

	/// A damaged file must never stop the pet from appearing.
	public func load() -> PetSettings {
		guard let data = try? Data(contentsOf: path),
			var settings = try? JSONDecoder().decode(PetSettings.self, from: data)
		else {
			return PetSettings()
		}
		settings.normalize()
		return settings
	}

	public func save(_ settings: PetSettings) {
		var normalized = settings
		normalized.normalize()
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		guard let data = try? encoder.encode(normalized) else { return }
		try? FileManager.default.createDirectory(
			at: path.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try? data.write(to: path, options: .atomic)
	}
}
