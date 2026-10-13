import Foundation

/// The pinned list of runtime files a release build fetches. The manifest itself
/// is compiled in: `AssetManifest.bundled` is generated into
/// `Asset/AssetManifest.swift` by `Tools/generate-asset-manifest.sh`.
public struct AssetManifest: Sendable {
	public struct Entry: Sendable {
		/// Where the file goes, relative to the app's asset folder.
		public var path: String
		/// Where it comes from, relative to the upstream repository root.
		public var source: String
	}

	public var upstream: String
	public var commit: String
	public var files: [Entry]

	/// The `owner/repo` slug of the upstream GitHub URL.
	static func repositorySlug(from upstream: String) -> String? {
		var text = upstream
		if text.hasSuffix(".git") { text.removeLast(4) }
		guard let marker = text.range(of: "github.com") else { return nil }
		let slug = text[marker.upperBound...].drop { $0 == ":" || $0 == "/" }
		return slug.isEmpty ? nil : String(slug)
	}

	/// The jsdelivr base for the pinned commit, e.g.
	/// `https://cdn.jsdelivr.net/gh/owner/repo@<commit>`. jsdelivr serves a
	/// pinned commit from its edge cache, unlike a raw.githubusercontent.com
	/// fetch through the GitHub CDN.
	public var cdnBaseURL: URL? {
		guard let slug = Self.repositorySlug(from: upstream) else { return nil }
		return URL(string: "https://cdn.jsdelivr.net/gh/\(slug)@\(commit)")
	}

	public func cdnURL(for entry: Entry) -> URL? {
		guard let base = cdnBaseURL else { return nil }
		var allowed = CharacterSet.urlPathAllowed
		// Characters that would change the meaning of the path are encoded rather
		// than left to the server's interpretation.
		allowed.remove(charactersIn: "#?[]{}|\\^`<>\"%")
		guard let encoded = entry.source.addingPercentEncoding(withAllowedCharacters: allowed),
			let url = URL(string: "\(base.absoluteString)/\(encoded)")
		else { return nil }
		return url
	}
}

/// Fetches and verifies the asset folder a release build runs from. Assets live
/// under `assets/<commit>/`, so a new pinned commit downloads once and is reused.
@MainActor
public final class AssetStore {
	public enum Failure: Error, CustomStringConvertible {
		case downloadFailed(String)

		public var description: String {
			switch self {
			case .downloadFailed(let name): return "素材下载失败：\(name)"
			}
		}
	}

	public struct Progress: Sendable {
		public var completed: Int
		public var total: Int
	}

	private let environment: AppEnvironment
	private let manifest: AssetManifest
	private let session: URLSession
	private let concurrency = 6

	public init(environment: AppEnvironment, manifest: AssetManifest) {
		self.environment = environment
		self.manifest = manifest
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 30
		configuration.httpMaximumConnectionsPerHost = 6
		self.session = URLSession(configuration: configuration)
	}

	public convenience init(environment: AppEnvironment) {
		self.init(environment: environment, manifest: .bundled)
	}

	public var installDirectory: URL {
		environment.assetsRootDirectory.appendingPathComponent(manifest.commit)
	}

	/// The upstream revision these assets came from.
	public var manifestCommit: String { manifest.commit }

	/// Files that are absent or empty, so a half-finished download is retried.
	public func missingFiles(in directory: URL) -> [AssetManifest.Entry] {
		let manager = FileManager.default
		return manifest.files.filter { entry in
			let url = directory.appendingPathComponent(entry.path)
			guard let attributes = try? manager.attributesOfItem(atPath: url.path),
				let size = attributes[.size] as? Int
			else { return true }
			return size == 0
		}
	}

	public func isComplete() -> Bool {
		missingFiles(in: installDirectory).isEmpty
	}

	/// Downloads whatever is missing into ``installDirectory``, reporting progress as
	/// it goes. Throws if a file cannot be fetched or written.
	public func install(progress: @escaping @Sendable (Progress) -> Void) async throws {
		let directory = installDirectory
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

		let missing = missingFiles(in: directory)
		guard !missing.isEmpty else {
			progress(Progress(completed: manifest.files.count, total: manifest.files.count))
			return
		}

		let total = missing.count
		var completed = 0
		progress(Progress(completed: 0, total: total))
		DiagnosticsLog.shared.writeEvent(
			"AssetDownloadStarted",
			[
				("Count", "\(total)"),
				("Commit", manifest.commit),
			]
		)

		try await withThrowingTaskGroup(of: String.self) { group in
			var iterator = missing.makeIterator()
			var inFlight = 0

			while inFlight < concurrency, let entry = iterator.next() {
				guard let url = manifest.cdnURL(for: entry) else {
					throw Failure.downloadFailed(entry.path)
				}
				group.addTask { [session] in
					try await AssetStore.fetch(entry: entry, from: url, into: directory, session: session)
					return entry.path
				}
				inFlight += 1
			}

			while let finished = try await group.next() {
				_ = finished
				completed += 1
				progress(Progress(completed: completed, total: total))

				if let entry = iterator.next(), let url = manifest.cdnURL(for: entry) {
					group.addTask { [session] in
						try await AssetStore.fetch(entry: entry, from: url, into: directory, session: session)
						return entry.path
					}
				}
			}
		}

		DiagnosticsLog.shared.writeEvent("AssetDownloadFinished", [("Count", "\(total)")])
	}

	private static func fetch(
		entry: AssetManifest.Entry,
		from url: URL,
		into directory: URL,
		session: URLSession
	) async throws {
		let (data, response) = try await session.data(from: url)
		guard let http = response as? HTTPURLResponse else {
			throw Failure.downloadFailed(entry.path)
		}
		guard http.statusCode == 200 else {
			throw Failure.downloadFailed("\(entry.path) (HTTP \(http.statusCode))")
		}
		guard !data.isEmpty else {
			throw Failure.downloadFailed("\(entry.path) (empty)")
		}

		let destination = directory.appendingPathComponent(entry.path)
		try FileManager.default.createDirectory(
			at: destination.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		// Write through a temporary file so an interrupted download never looks
		// complete on the next launch.
		let temporary = destination.appendingPathExtension("partial")
		try data.write(to: temporary)
		_ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
	}
}
