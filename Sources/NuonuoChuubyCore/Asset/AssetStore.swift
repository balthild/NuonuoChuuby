import Foundation

/// The pinned list of runtime files a release build fetches.
///
/// The manifest holds only paths and a commit id — no asset bytes — so it can be
/// committed and reviewed without carrying any of the artwork's unresolved
/// redistribution status. See `Tools/generate-asset-manifest.sh`.
public struct AssetManifest: Sendable, Decodable {
	public struct Entry: Sendable, Decodable {
		/// Where the file goes, relative to the app's asset folder.
		public var path: String
		/// Where it comes from, relative to the upstream repository root.
		public var source: String
	}

	public var upstream: String
	public var commit: String
	public var files: [Entry]

	/// Reads the manifest bundled with the app.
	public static func bundled() -> AssetManifest? {
		guard let url = Bundle.module.url(forResource: "asset-manifest", withExtension: "json"),
			let data = try? Data(contentsOf: url)
		else { return nil }
		return try? JSONDecoder().decode(AssetManifest.self, from: data)
	}

	/// The github.com URL the files are served from.
	public var rawBaseURL: URL? {
		URL(
			string: upstream.replacingOccurrences(
				of: "https://github.com/",
				with: "https://raw.githubusercontent.com/"
			)
		)
	}

	public func rawURL(for entry: Entry) -> URL? {
		guard let base = rawBaseURL else { return nil }
		var allowed = CharacterSet.urlPathAllowed
		// Characters that would change the meaning of the path are encoded rather
		// than left to the server's interpretation.
		allowed.remove(charactersIn: "#?[]{}|\\^`<>\"%")
		guard let encoded = entry.source.addingPercentEncoding(withAllowedCharacters: allowed),
			let url = URL(string: "\(base.absoluteString)/\(commit)/\(encoded)")
		else { return nil }
		return url
	}
}

/// Fetches and verifies the asset folder a release build runs from.
///
/// A development build ships a seed copy inside the bundle, so this only runs
/// when the seed is absent. Assets live under `assets/<commit>/`, which means a
/// release that pins a new commit naturally downloads once and then reuses it.
@MainActor
public final class AssetStore {
	public enum Failure: Error, CustomStringConvertible {
		case manifestMissing
		case downloadFailed(String)

		public var description: String {
			switch self {
			case .manifestMissing: return "找不到素材清单。"
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

	public convenience init(environment: AppEnvironment) throws {
		guard let manifest = AssetManifest.bundled() else { throw Failure.manifestMissing }
		self.init(environment: environment, manifest: manifest)
	}

	public var installDirectory: URL {
		environment.assetsRootDirectory.appendingPathComponent(manifest.commit)
	}

	/// The upstream revision these assets came from, for logging and support.
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

	/// Downloads whatever is missing, reporting progress as it goes.
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

		// A bounded number of parallel requests keeps the download short without
		// hammering the server or opening hundreds of sockets.
		try await withThrowingTaskGroup(of: String.self) { group in
			var iterator = missing.makeIterator()
			var inFlight = 0

			while inFlight < concurrency, let entry = iterator.next() {
				guard let url = manifest.rawURL(for: entry) else {
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

				if let entry = iterator.next(), let url = manifest.rawURL(for: entry) {
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
