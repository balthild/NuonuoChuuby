import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The settings file is the one file the user is most likely to outlive: a build that adds
/// a field, a hand-edited value, a file left by an older version. None of those may cost the
/// preferences the file does hold, because `SettingsStore.load()` has no second attempt —
/// a decode that throws is answered with a wholesale `PetSettings()`.
@Suite("Settings store")
struct SettingsStoreTests {
	private func store() -> (SettingsStore, URL) {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-settings-\(UUID().uuidString)")
		return (SettingsStore(path: directory.appendingPathComponent("settings.json")), directory)
	}

	private func write(_ json: String, to url: URL) throws {
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try Data(json.utf8).write(to: url)
	}

	@Test("Every preference survives a round trip")
	func roundTrip() throws {
		let (store, directory) = store()
		defer { try? FileManager.default.removeItem(at: directory) }

		var settings = PetSettings()
		settings.fastingMode = true
		settings.quietMode = true
		settings.soundEnabled = false
		settings.voiceVolume = 0.31
		settings.petSize = 286
		settings.watchedFolders = ["/tmp/one"]
		store.save(settings)

		let reloaded = store.load()
		#expect(reloaded.fastingMode)
		#expect(reloaded.quietMode)
		#expect(!reloaded.soundEnabled)
		#expect(reloaded.voiceVolume == 0.31)
		#expect(reloaded.petSize == 286)
		#expect(reloaded.watchedFolders == ["/tmp/one"])
	}

	/// The reason every field carries `@Fallback`: a build that adds a field must not reset
	/// what an older file holds. Without the wrappers, `version` would be the only key
	/// missing and the whole file would be discarded.
	@Test("A file written before a field existed keeps the rest of its values")
	func fileWithoutEveryKey() throws {
		let (store, directory) = store()
		defer { try? FileManager.default.removeItem(at: directory) }
		try write(#"{"fastingMode":true,"watchingFolders":["/tmp/one"]}"#, to: store.path)

		let settings = store.load()
		#expect(settings.fastingMode)
		// Missing keys take their defaults rather than a decode failure.
		#expect(settings.soundEnabled)
		#expect(settings.quietMode == false)
		#expect(settings.watchedFolders.isEmpty)
	}

	/// A wrong type is the other half of the same story: it costs one field, not the file.
	@Test("An unreadable value costs only its own field")
	func unreadableValue() throws {
		let (store, directory) = store()
		defer { try? FileManager.default.removeItem(at: directory) }
		try write(#"{"quietMode":"yes","fastingMode":true,"watchedFolders":{}}"#, to: store.path)

		let settings = store.load()
		#expect(settings.quietMode == false)
		#expect(settings.fastingMode)
		#expect(settings.watchedFolders.isEmpty)
	}

	/// Only an optional field can hold a null, so on a non-optional one it is read as a
	/// missing value — which is the answer a hand-edited file is asking for anyway.
	@Test("An explicit null on a non-optional field takes the default")
	func explicitNull() throws {
		let (store, directory) = store()
		defer { try? FileManager.default.removeItem(at: directory) }
		try write(#"{"quietMode":null,"characterId":null,"fastingMode":true}"#, to: store.path)

		let settings = store.load()
		#expect(settings.quietMode == false)
		#expect(settings.characterId == PetCharacterProfile.nuonuo.id)
		#expect(settings.fastingMode)
	}

	/// Whatever the file did not carry is written back on the next save, so one load is
	/// enough to heal it.
	@Test("A save writes every field, so the file heals")
	func saveHealsTheFile() throws {
		let (store, directory) = store()
		defer { try? FileManager.default.removeItem(at: directory) }
		try write(#"{"fastingMode":true}"#, to: store.path)

		store.save(store.load())
		let text = try String(contentsOf: store.path, encoding: .utf8)
		#expect(text.contains("\"quietMode\""))
		#expect(text.contains("\"loggingEnabled\""))
	}

	/// The one case left: a file that is not an object at all. It must still leave the pet
	/// able to start, and `normalize()` must still have run.
	@Test("A file that cannot be read at all falls back to the defaults")
	func unreadableFile() throws {
		let (store, directory) = store()
		defer { try? FileManager.default.removeItem(at: directory) }
		try write("{broken", to: store.path)

		let settings = store.load()
		#expect(settings == PetSettings())
		#expect(settings.petSize == PetSizePolicy.defaultSize)
	}

	@Test("A hand-edited value outside its range is clamped")
	func handEditedValuesAreClamped() throws {
		let (store, directory) = store()
		defer { try? FileManager.default.removeItem(at: directory) }
		try write(#"{"petSize":-20,"voiceVolume":2,"characterId":"nobody"}"#, to: store.path)

		let settings = store.load()
		#expect(settings.petSize == PetSizePolicy.clampPreferredSize(-20))
		#expect(settings.voiceVolume == 1)
		#expect(settings.characterId == PetCharacterProfile.nuonuo.id)
	}
}
