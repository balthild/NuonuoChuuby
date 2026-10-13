import Foundation
import Testing

@testable import NuonuoChuubyCore

@Suite("Asset manifest")
struct AssetManifestTests {
	private func manifest() -> AssetManifest {
		AssetManifest(
			upstream: "https://github.com/nicedoctors/JiuNuoDesktopPet",
			commit: "abc123",
			files: [
				.init(path: "audio/voice/糯糯_002.wav", source: "音效/糯糯_002.wav"),
				.init(
					path: "sprites/runtime/idle/frame_00.png",
					source: "assets/sprites/runtime/idle/frame_00.png"
				),
			]
		)
	}

	@Test("The compiled-in manifest pins a commit and lists the runtime files")
	func bundledManifest() {
		#expect(AssetManifest.bundled.commit.count == 40)
		#expect(AssetManifest.bundled.upstream.contains("github.com"))
		#expect(AssetManifest.bundled.files.count > 300)
	}

	@Test("Every entry points at a plausible upstream path")
	func entryPaths() {
		for entry in AssetManifest.bundled.files {
			#expect(!entry.path.isEmpty)
			#expect(!entry.source.isEmpty)
			// Voice clips come from the Chinese-named folder at the repo root.
			if entry.path.hasPrefix("audio/voice/") {
				#expect(entry.source.hasPrefix("音效/"))
			} else {
				#expect(entry.source.hasPrefix("assets/"))
			}
		}
	}

	@Test("A CDN URL is built against the pinned commit")
	func cdnURL() throws {
		let bundled = manifest()
		let entry = bundled.files[1]
		let url = try #require(bundled.cdnURL(for: entry))
		#expect(url.absoluteString.contains("cdn.jsdelivr.net/gh/nicedoctors/JiuNuoDesktopPet@abc123"))
		#expect(url.absoluteString.hasSuffix("/assets/sprites/runtime/idle/frame_00.png"))
	}

	@Test("The repository slug is taken from the upstream URL")
	func repositorySlug() {
		#expect(
			AssetManifest.repositorySlug(from: "https://github.com/owner/repo")
				== "owner/repo"
		)
		// A `.git` suffix must not leak into the CDN path.
		#expect(
			AssetManifest.repositorySlug(from: "https://github.com/owner/repo.git")
				== "owner/repo"
		)
	}

	@Test("A non-ASCII path is percent-encoded, not left raw")
	func encodesNonASCII() throws {
		let bundled = manifest()
		let entry = bundled.files[0]
		let url = try #require(bundled.cdnURL(for: entry))
		// The manifest's own path stays readable, but the request must be escaped.
		#expect(!url.absoluteString.contains("糯糯"))
		#expect(url.absoluteString.contains("%E7%B3%AF"))
		// The resolving round trip has to survive.
		#expect(url.absoluteString.removingPercentEncoding?.contains("音效/糯糯_002.wav") == true)
	}
}

@Suite("Asset store")
struct AssetStoreTests {
	private let manifest = AssetManifest(
		upstream: "https://github.com/owner/repo",
		commit: "deadbeef",
		files: [
			.init(
				path: "sprites/runtime/idle/frame_00.png",
				source: "assets/sprites/runtime/idle/frame_00.png"
			),
			.init(path: "audio/voice/a.wav", source: "音效/a.wav"),
		]
	)

	private func makeStore() -> (AssetStore, URL) {
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-assets-\(UUID().uuidString)")
		let environment = AppEnvironment(storageDirectory: root)
		return (
			MainActor.assumeIsolated { AssetStore(environment: environment, manifest: manifest) }, root
		)
	}

	@MainActor
	@Test("A fresh install reports every file missing")
	func freshInstall() {
		let (store, root) = makeStore()
		defer { try? FileManager.default.removeItem(at: root) }
		#expect(store.missingFiles(in: store.installDirectory).count == 2)
		#expect(!store.isComplete())
	}

	@MainActor
	@Test("An empty file still counts as missing")
	func emptyFileIsMissing() throws {
		let (store, root) = makeStore()
		defer { try? FileManager.default.removeItem(at: root) }

		let file = store.installDirectory.appendingPathComponent("audio/voice/a.wav")
		try FileManager.default.createDirectory(
			at: file.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		// A truncated download must not look complete.
		try Data().write(to: file)

		let missing = store.missingFiles(in: store.installDirectory)
		#expect(missing.count == 2)
	}

	@MainActor
	@Test("A complete install reports nothing missing")
	func completeInstall() throws {
		let (store, root) = makeStore()
		defer { try? FileManager.default.removeItem(at: root) }

		for entry in manifest.files {
			let file = store.installDirectory.appendingPathComponent(entry.path)
			try FileManager.default.createDirectory(
				at: file.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			try Data([0x00]).write(to: file)
		}
		#expect(store.isComplete())
	}

	@MainActor
	@Test("The install path is keyed by the pinned commit, so a new pin refetches")
	func installDirectoryIsPinned() {
		let (store, root) = makeStore()
		defer { try? FileManager.default.removeItem(at: root) }
		#expect(store.installDirectory.lastPathComponent == "deadbeef")
	}
}
