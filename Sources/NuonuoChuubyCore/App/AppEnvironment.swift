import Foundation

/// Owns the on-disk layout of the app's data.
///
/// Everything lives under `~/Library/Application Support/NuonuoChuuby`:
///   * `settings.json`, `life-state.json` — durable user/pet state
///   * `assets/<commit>/` — assets fetched from upstream for a release build
///   * `activity.log` — local diagnostics
public struct AppEnvironment: Sendable {
	public static let bundleIdentifier = "com.balthild.NuonuoChuuby"
	public static let storageFolderName = "NuonuoChuuby"

	public let storageDirectory: URL

	public init(storageDirectory: URL) {
		self.storageDirectory = storageDirectory
	}

	public init() {
		let base =
			FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
				"Library/Application Support"
			)
		self.init(storageDirectory: base.appendingPathComponent(AppEnvironment.storageFolderName))
	}

	public var settingsPath: URL { storageDirectory.appendingPathComponent("settings.json") }
	public var lifeStateDirectory: URL { storageDirectory }
	public var assetsRootDirectory: URL { storageDirectory.appendingPathComponent("assets") }
	public var logPath: URL { storageDirectory.appendingPathComponent("activity.log") }
}
