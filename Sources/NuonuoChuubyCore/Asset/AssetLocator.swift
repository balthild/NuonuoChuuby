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
