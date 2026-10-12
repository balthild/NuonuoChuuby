import Foundation

/// Resolves where the sprite frames and voice clips live.
///
/// A development build ships a seed copy inside the app bundle (copied from the
/// upstream submodule by `make assets`). A release build downloads the pinned
/// revision into Application Support on first launch. Whichever is present, the
/// same relative layout is used so the rest of the app never has to care.
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

	/// Assets bundled with the app, if `make assets` seeded them.
	public static func bundled() -> AssetLocator? {
		guard let url = Bundle.module.resourceURL?.appendingPathComponent("Assets") else { return nil }
		return FileManager.default.fileExists(atPath: url.path) ? AssetLocator(root: url) : nil
	}

	/// Assets previously downloaded into Application Support.
	public static func installed(environment: AppEnvironment) -> AssetLocator? {
		let root = environment.assetsRootDirectory
		let manager = FileManager.default
		guard let versions = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
			return nil
		}
		// Newest revision wins; the folder name is the pinned commit id.
		let newest = versions.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
			.first
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
