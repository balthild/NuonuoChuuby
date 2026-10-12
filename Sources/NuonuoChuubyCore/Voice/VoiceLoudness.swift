import Foundation

/// Per-file gains measured offline, so the recordings keep their balance without
/// being re-encoded.
public struct VoiceLoudness: Sendable {
	private let gains: [String: Double]

	public init(gains: [String: Double] = [:]) {
		self.gains = gains
	}

	private struct Index: Decodable {
		struct Clip: Decodable {
			var character: String
			var file: String
			var gain: Double

			enum CodingKeys: String, CodingKey {
				case character = "Character"
				case file = "File"
				case gain = "Gain"
			}
		}
		var clips: [Clip]

		enum CodingKeys: String, CodingKey {
			case clips = "Clips"
		}
	}

	public static func load(from url: URL) -> VoiceLoudness {
		guard let data = try? Data(contentsOf: url),
			let index = try? JSONDecoder().decode(Index.self, from: data)
		else {
			// A missing or damaged index must not silence the pet; the recordings
			// are simply played at their own levels.
			return VoiceLoudness()
		}
		var gains: [String: Double] = [:]
		for clip in index.clips where clip.gain.isFinite && clip.gain > 0 && clip.gain <= 1 {
			gains["\(clip.character)/\(clip.file)"] = clip.gain
		}
		return VoiceLoudness(gains: gains)
	}

	public func gain(character: String, file: String?) -> Double {
		guard let file else { return 1 }
		return gains["\(character)/\(file)"] ?? 1
	}

	public func volume(character: String, file: String?, requested: Double) -> Double {
		let clamped = requested.isFinite ? min(max(requested, 0), 1) : 0
		return clamped * gain(character: character, file: file)
	}
}
