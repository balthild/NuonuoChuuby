import Foundation

/// Locates the artwork the Makefile assembles into the app
/// (`Contents/Resources/Assets.bundle/Assets`). It reads `Bundle.main` rather
/// than `Bundle.module`: the folder is built by hand, so nothing depends on
/// SwiftPM's generated resource bundle.
enum BundledAssets {
	static var bundleURL: URL? {
		Bundle.main.resourceURL?.appendingPathComponent("Assets.bundle")
	}

	/// Sprite frames and voice clips.
	static var rootURL: URL? { bundleURL?.appendingPathComponent("Assets") }
}

/// Resolves where the sprite frames and voice clips live.
public struct AssetLocator: Sendable {
	public let root: URL

	public init(root: URL) {
		self.root = root
	}

	enum AssetError: Error, CustomStringConvertible {
		case missing(String)

		var description: String {
			switch self {
			case .missing(let path): return "asset not found: \(path)"
			}
		}
	}

	/// The artwork hand-linked into the app (`Contents/Resources/Assets.bundle/Assets`)
	/// for a development build; nil when the build fetches it instead.
	///
	/// The resource folder always exists (the bundle carries the manifest), so a
	/// sentinel frame decides whether it actually carries artwork.
	public static func bundled() -> AssetLocator? {
		guard let url = BundledAssets.rootURL else { return nil }
		let sentinel = url.appendingPathComponent("sprites/runtime/idle/frame_00.png")
		return FileManager.default.fileExists(atPath: sentinel.path) ? AssetLocator(root: url) : nil
	}

	/// Assets previously downloaded into Application Support.
	public static func installed(environment: AppEnvironment, commit: String?) -> AssetLocator? {
		let root = environment.assetsRootDirectory
		if let commit {
			let exact = root.appendingPathComponent(commit)
			guard FileManager.default.fileExists(atPath: exact.path) else { return nil }
			return AssetLocator(root: exact)
		}
		// Newest revision wins; the folder name is the pinned commit id.
		let manager = FileManager.default
		guard let versions = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
		else { return nil }
		let newest =
			versions
			.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
			.max { $0.lastPathComponent < $1.lastPathComponent }
		guard let newest else { return nil }
		return AssetLocator(root: newest)
	}

	public func frameURL(character: PetCharacterProfile, clip folder: String, index: Int) -> URL {
		root.appendingPathComponent(character.runtimeRelativeDirectory)
			.appendingPathComponent(folder)
			.appendingPathComponent(String(format: "frame_%02d.png", index))
	}

	public func voiceURL(character: PetCharacterProfile, fileName: String) -> URL {
		root.appendingPathComponent(character.voiceRelativeDirectory).appendingPathComponent(fileName)
	}

	public func file(_ relativePath: String) -> URL {
		root.appendingPathComponent(relativePath)
	}
}
