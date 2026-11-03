import Foundation
import PetFoundation

/// Durable user preferences.
///
/// Every field carries `@Fallback`, so a key the file does not hold — or one holding a
/// value of the wrong shape — costs that field alone. A decode that throws is the one
/// failure this store cannot absorb: `SettingsStore.load()` answers it with a whole fresh
/// `PetSettings`, so without the wrappers a file written before a field existed would
/// silently reset every preference the user has. A new field therefore takes a wrapper
/// and an entry in ``PetSettingsDefault``, and nothing else has to change.
public struct PetSettings: Sendable, Equatable, Codable {
	public static let currentVersion = 1

	@Fallback<PetSettingsDefault.Version> public var version: Int
	@Fallback<PetSettingsDefault.CharacterId> public var characterId: String
	@Fallback<PetSettingsDefault.ReactToDeletes> public var reactToDeletes: Bool
	@Fallback<PetSettingsDefault.SoundEnabled> public var soundEnabled: Bool
	@Fallback<PetSettingsDefault.FastingMode> public var fastingMode: Bool
	@Fallback<PetSettingsDefault.InfiniteMode> public var infiniteMode: Bool
	@Fallback<PetSettingsDefault.CoexistenceMode> public var coexistenceMode: Bool
	@Fallback<PetSettingsDefault.ShowSpeechBubbles> public var showSpeechBubbles: Bool
	/// Whether the menu-bar icon is shown. Off leaves the pet as the only way into this
	/// menu — a right-click on her borrows the same one.
	@Fallback<PetSettingsDefault.ShowTrayIcon> public var showTrayIcon: Bool
	@Fallback<PetSettingsDefault.QuietMode> public var quietMode: Bool
	@Fallback<PetSettingsDefault.AllowMischief> public var allowMischief: Bool
	@Fallback<PetSettingsDefault.VoiceVolume> public var voiceVolume: Double
	@Fallback<PetSettingsDefault.PetSize> public var petSize: Double
	@Fallback<PetSettingsDefault.WatchedFolders> public var watchedFolders: [String]
	/// Whether the diagnostics log records anything. On by default: a bug report
	/// without a log is most of the value gone, and the cost is ~26 µs a line.
	@Fallback<PetSettingsDefault.LoggingEnabled> public var loggingEnabled: Bool

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

/// The value each ``PetSettings`` field takes when the stored file has no usable one.
///
/// `@Fallback` asks a type for the default rather than the field, and that protocol has
/// nowhere to carry a value, so every field names one of these. They follow the field list
/// above in the same order.
public enum PetSettingsDefault {
	/// A file that does not say which version wrote it is taken to be this build's.
	public enum Version: FallbackProvider {
		public static let fallbackValue = PetSettings.currentVersion
	}

	public enum CharacterId: FallbackProvider {
		public static let fallbackValue = PetCharacterProfile.nuonuo.id
	}

	public enum ReactToDeletes: FallbackProvider { public static let fallbackValue = true }
	public enum SoundEnabled: FallbackProvider { public static let fallbackValue = true }
	public enum FastingMode: FallbackProvider { public static let fallbackValue = false }
	public enum InfiniteMode: FallbackProvider { public static let fallbackValue = false }
	public enum CoexistenceMode: FallbackProvider { public static let fallbackValue = false }
	public enum ShowSpeechBubbles: FallbackProvider { public static let fallbackValue = true }
	public enum ShowTrayIcon: FallbackProvider { public static let fallbackValue = true }
	public enum QuietMode: FallbackProvider { public static let fallbackValue = false }
	public enum AllowMischief: FallbackProvider { public static let fallbackValue = true }
	public enum VoiceVolume: FallbackProvider { public static let fallbackValue = 0.72 }
	public enum PetSize: FallbackProvider {
		public static let fallbackValue = PetSizePolicy.defaultSize
	}
	public enum WatchedFolders: FallbackProvider { public static let fallbackValue: [String] = [] }
	public enum LoggingEnabled: FallbackProvider { public static let fallbackValue = true }
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
