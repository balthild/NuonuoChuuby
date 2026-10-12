import CoreGraphics
import Foundation
import ImageIO

/// Loads and caches per-clip frame arrays.
@MainActor
public final class AssetCatalog {
	private let locator: AssetLocator
	private var cache: [String: [CGImage]] = [:]

	public init(locator: AssetLocator) {
		self.locator = locator
	}

	/// Clip folders are addressed by their asset folder name (e.g. `idle`), which
	/// may differ from the logical clip name (e.g. `sleep` backing three clips).
	public func frames(character: PetCharacterProfile, folder: String) -> [CGImage] {
		let key = "\(character.id)/\(folder)"
		if let cached = cache[key] { return cached }

		var images: [CGImage] = []
		var index = 0
		while true {
			let url = locator.frameURL(character: character, clip: folder, index: index)
			guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
				let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
			else {
				break
			}
			images.append(image)
			index += 1
		}
		cache[key] = images
		return images
	}

	/// True when at least one frame is present for every required clip folder.
	public func hasRequiredClips(for character: PetCharacterProfile) -> Bool {
		let required = SpriteAnimator.requiredAssetFolders(for: character)
		return required.allSatisfy { !frames(character: character, folder: $0).isEmpty }
	}
}
