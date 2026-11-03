import CoreGraphics
import Foundation

public struct SpriteClip: Sendable, Equatable {
	public var name: String
	public var assetFolder: String
	public var firstFrame: Int
	public var lastFrame: Int
	public var frameSeconds: Double
	public var loop: Bool
	public var pingPong: Bool
	public var startReversed: Bool

	public init(
		name: String,
		assetFolder: String,
		firstFrame: Int,
		lastFrame: Int,
		frameSeconds: Double,
		loop: Bool,
		pingPong: Bool,
		startReversed: Bool = false
	) {
		self.name = name
		self.assetFolder = assetFolder
		self.firstFrame = firstFrame
		self.lastFrame = lastFrame
		self.frameSeconds = frameSeconds
		self.loop = loop
		self.pingPong = pingPong
		self.startReversed = startReversed
	}
}

/// The animation clips a character can play, and the asset folders they need.
///
/// Data, not playback — which is why the asset layer can ask it what a character must
/// ship without going through the player.
public enum SpriteClipTable {
	private static let defaultClips: [String: SpriteClip] = [
		"idle": SpriteClip(
			name: "idle",
			assetFolder: "idle",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.135,
			loop: true,
			pingPong: false
		),
		"run": SpriteClip(
			name: "run",
			assetFolder: "run",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.070,
			loop: true,
			pingPong: false
		),
		"walk": SpriteClip(
			name: "walk",
			assetFolder: "walk",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.110,
			loop: true,
			pingPong: false
		),
		"toss": SpriteClip(
			name: "toss",
			assetFolder: "toss",
			firstFrame: 0,
			lastFrame: 7,
			frameSeconds: 0.055,
			loop: false,
			pingPong: false
		),
		"fall": SpriteClip(
			name: "fall",
			assetFolder: "fall",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.090,
			loop: true,
			pingPong: false
		),
		"land": SpriteClip(
			name: "land",
			assetFolder: "land",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.060,
			loop: false,
			pingPong: false
		),
		"curious": SpriteClip(
			name: "curious",
			assetFolder: "curious",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.135,
			loop: true,
			pingPong: false
		),
		"sleep_enter": SpriteClip(
			name: "sleep_enter",
			assetFolder: "sleep",
			firstFrame: 0,
			lastFrame: 7,
			frameSeconds: 0.145,
			loop: false,
			pingPong: false
		),
		"sleep": SpriteClip(
			name: "sleep",
			assetFolder: "sleep",
			firstFrame: 8,
			lastFrame: 15,
			frameSeconds: 0.185,
			loop: true,
			pingPong: true
		),
		"sleep_exit": SpriteClip(
			name: "sleep_exit",
			assetFolder: "sleep",
			firstFrame: 0,
			lastFrame: 7,
			frameSeconds: 0.105,
			loop: false,
			pingPong: false,
			startReversed: true
		),
		"hungry": SpriteClip(
			name: "hungry",
			assetFolder: "hungry",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.135,
			loop: true,
			pingPong: false
		),
		"climb": SpriteClip(
			name: "climb",
			assetFolder: "climb",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.082,
			loop: true,
			pingPong: false
		),
		"drag": SpriteClip(
			name: "drag",
			assetFolder: "drag",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.080,
			loop: true,
			pingPong: true
		),
		"jump": SpriteClip(
			name: "jump",
			assetFolder: "jump",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.075,
			loop: false,
			pingPong: false
		),
		"slide": SpriteClip(
			name: "slide",
			assetFolder: "slide",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.090,
			loop: true,
			pingPong: false
		),
		"roll": SpriteClip(
			name: "roll",
			assetFolder: "roll",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.085,
			loop: false,
			pingPong: false
		),
		"lick": SpriteClip(
			name: "lick",
			assetFolder: "lick",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.110,
			loop: false,
			pingPong: false
		),
		"chomp": SpriteClip(
			name: "chomp",
			assetFolder: "chomp",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.150,
			loop: false,
			pingPong: false
		),
		"satisfied": SpriteClip(
			name: "satisfied",
			assetFolder: "satisfied",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.095,
			loop: false,
			pingPong: false
		),
		"satisfied_quick": SpriteClip(
			name: "satisfied_quick",
			assetFolder: "satisfied",
			firstFrame: 0,
			lastFrame: 9,
			frameSeconds: 0.085,
			loop: false,
			pingPong: false
		),
		"pair_cheek": SpriteClip(
			name: "pair_cheek",
			assetFolder: "pair_cheek",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.145,
			loop: false,
			pingPong: false
		),
		"pair_notice": SpriteClip(
			name: "pair_notice",
			assetFolder: "pair_notice",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.18,
			loop: false,
			pingPong: false
		),
		"pair_nuzzle": SpriteClip(
			name: "pair_nuzzle",
			assetFolder: "pair_nuzzle",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.20,
			loop: false,
			pingPong: false
		),
		"pair_ball": SpriteClip(
			name: "pair_ball",
			assetFolder: "pair_ball",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: CompanionLifeConstants.kickFrameSeconds,
			loop: false,
			pingPong: false
		),
		"pair_feed": SpriteClip(
			name: "pair_feed",
			assetFolder: "pair_feed",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.175,
			loop: false,
			pingPong: false
		),
		"pair_feed_wait": SpriteClip(
			name: "pair_feed_wait",
			assetFolder: "pair_feed",
			firstFrame: 0,
			lastFrame: 2,
			frameSeconds: 0.400,
			loop: true,
			pingPong: true
		),
		"pair_feed_ready": SpriteClip(
			name: "pair_feed_ready",
			assetFolder: "pair_feed",
			firstFrame: 3,
			lastFrame: 5,
			frameSeconds: 0.250,
			loop: false,
			pingPong: false
		),
		"pair_feed_catch": SpriteClip(
			name: "pair_feed_catch",
			assetFolder: "pair_feed",
			firstFrame: 6,
			lastFrame: 15,
			frameSeconds: 0.175,
			loop: false,
			pingPong: false
		),
		"pair_icon_kick": SpriteClip(
			name: "pair_icon_kick",
			assetFolder: "pair_icon_kick",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.105,
			loop: false,
			pingPong: false
		),
		"pair_sleep_enter": SpriteClip(
			name: "pair_sleep_enter",
			assetFolder: "pair_sleep",
			firstFrame: 0,
			lastFrame: 15,
			frameSeconds: 0.165,
			loop: false,
			pingPong: false
		),
		"pair_sleep_hold": SpriteClip(
			name: "pair_sleep_hold",
			assetFolder: "pair_sleep",
			firstFrame: 10,
			lastFrame: 15,
			frameSeconds: 0.32,
			loop: true,
			pingPong: true
		),
	]

	/// The clips a character actually has: every default clip with the character's own
	/// frame timings, less the food clips a mischief character never eats and the one
	/// clip only a mischief character plays.
	public static func clips(for profile: PetCharacterProfile) -> [String: SpriteClip] {
		var table: [String: SpriteClip] = [:]
		for (name, clip) in defaultClips {
			var adjusted = clip
			adjusted.frameSeconds = profile.resolveFrameSeconds(
				clipName: name,
				defaultSeconds: clip.frameSeconds
			)
			table[name] = adjusted
		}
		if profile.usesMischief {
			for key in table.keys where foodAssetFolders.contains(table[key]!.assetFolder) {
				table.removeValue(forKey: key)
			}
			table["curious"] = SpriteClip(
				name: "curious",
				assetFolder: "curious",
				firstFrame: 0,
				lastFrame: 7,
				frameSeconds: profile.resolveFrameSeconds(clipName: "curious", defaultSeconds: 0.135),
				loop: true,
				pingPong: true
			)
		} else {
			table.removeValue(forKey: "pair_icon_kick")
		}
		return table
	}

	private static let foodAssetFolders: Set<String> = ["hungry", "lick", "chomp", "satisfied"]

	/// Clips drawn with the bare variant of a pose when the character has no hat on.
	public static let hatlessAliases: [String: String] = [
		"idle": "bare_idle", "walk": "bare_run", "run": "bare_run",
		"drag": "bare_drag", "fall": "bare_fall", "toss": "bare_fall",
		"land": "bare_recover",
	]
}

/// Pair-scene timings referenced by the clip table.
public enum CompanionLifeConstants {
	public static let kickFrameSeconds: Double = 0.13
	public static let kickContact = 7 * kickFrameSeconds
	public static let rallySeconds: Double = 1.6
	public static let rallyCount = 6
}
