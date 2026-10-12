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

@MainActor
public protocol SpriteAnimatorDelegate: AnyObject {
	func spriteAnimator(_ animator: SpriteAnimator, didChangeTo frame: CGImage)
	func spriteAnimator(_ animator: SpriteAnimator, didFinishClip clip: String)
}

/// Steps a clip's frames over time.
@MainActor
public final class SpriteAnimator {
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

	private static let foodAssetFolders: Set<String> = ["hungry", "lick", "chomp", "satisfied"]

	private static let hatlessAliases: [String: String] = [
		"idle": "bare_idle", "walk": "bare_run", "run": "bare_run",
		"drag": "bare_drag", "fall": "bare_fall", "toss": "bare_fall",
		"land": "bare_recover",
	]

	/// The clip folders a character must ship for every behaviour to be playable.
	public static func requiredAssetFolders(for profile: PetCharacterProfile) -> [String] {
		var folders = defaultClips.values.map(\.assetFolder)
		var seen = Set<String>()
		var ordered: [String] = []
		for folder in folders where seen.insert(folder).inserted {
			ordered.append(folder)
		}
		folders = ordered

		if profile.usesMischief {
			folders = folders.filter { !foodAssetFolders.contains($0) }
		} else {
			folders = folders.filter { $0 != "pair_icon_kick" }
		}
		return folders
	}

	private let catalog: AssetCatalog
	private let profile: PetCharacterProfile
	private var clips: [String: SpriteClip]
	private var current: SpriteClip

	private var frameIndex: Int
	private var elapsed: Double = 0
	private var completed = false
	private var direction = 1
	private var requestedClipName = "idle"
	private var playbackSeconds: Double = 0

	public weak var delegate: SpriteAnimatorDelegate?

	public init(catalog: AssetCatalog, profile: PetCharacterProfile = .nuonuo) {
		self.catalog = catalog
		self.profile = profile

		var table: [String: SpriteClip] = [:]
		for (name, clip) in SpriteAnimator.defaultClips {
			var adjusted = clip
			adjusted.frameSeconds = profile.resolveFrameSeconds(
				clipName: name,
				defaultSeconds: clip.frameSeconds
			)
			table[name] = adjusted
		}
		if profile.usesMischief {
			for key in table.keys where SpriteAnimator.foodAssetFolders.contains(table[key]!.assetFolder)
			{
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
		self.clips = table
		self.current = table["idle"]!
		self.frameIndex = table["idle"]!.firstFrame
	}

	public var currentClip: String { requestedClipName }
	public var currentAssetFolder: String { current.assetFolder }
	public var isCompleted: Bool { completed }
	public var currentFrameIndex: Int { frameIndex }

	public var durationSeconds: Double {
		Double(current.lastFrame - current.firstFrame + 1) * current.frameSeconds
	}

	public var elapsedSeconds: Double {
		current.loop ? playbackSeconds : min(playbackSeconds, durationSeconds)
	}

	public var progress: Double {
		let duration = durationSeconds
		guard duration > 0 else { return 1 }
		return min(max(elapsedSeconds / duration, 0), 1)
	}

	public func hasClip(_ name: String) -> Bool { clips[name] != nil }

	public var currentFrame: CGImage? { frame(at: frameIndex) }

	public func frame(at index: Int) -> CGImage? {
		let frames = catalog.frames(character: profile, folder: current.assetFolder)
		guard !frames.isEmpty else { return nil }
		return frames[min(max(index, current.firstFrame), min(current.lastFrame, frames.count - 1))]
	}

	public func play(_ clipName: String, restart: Bool = true) {
		if !restart, requestedClipName.caseInsensitiveCompare(clipName) == .orderedSame {
			return
		}
		guard var next = clips[clipName] else { return }

		if let alias = SpriteAnimator.hatlessAliases[clipName], let bare = clips[alias] {
			var aliased = bare
			aliased.name = clipName
			aliased.firstFrame = next.firstFrame
			aliased.lastFrame = next.lastFrame
			aliased.loop = next.loop
			aliased.pingPong = next.pingPong
			aliased.startReversed = next.startReversed
			next = aliased
		}

		current = next
		requestedClipName = clipName
		playbackSeconds = 0
		frameIndex = next.startReversed ? next.lastFrame : next.firstFrame
		elapsed = 0
		completed = false
		direction = next.startReversed ? -1 : 1
		if let frame = currentFrame {
			delegate?.spriteAnimator(self, didChangeTo: frame)
		}
	}

	public func tick(_ deltaSeconds: Double) {
		guard !completed, deltaSeconds.isFinite, deltaSeconds > 0 else { return }

		playbackSeconds += deltaSeconds
		elapsed += deltaSeconds
		while elapsed >= current.frameSeconds {
			elapsed -= current.frameSeconds
			var nextFrame = frameIndex + direction

			if direction > 0, nextFrame > current.lastFrame {
				if current.loop {
					if current.pingPong {
						direction = -1
						nextFrame = max(current.firstFrame, current.lastFrame - 1)
					} else {
						nextFrame = current.firstFrame
					}
				} else {
					finish()
					return
				}
			} else if direction < 0, nextFrame < current.firstFrame {
				if current.loop {
					direction = 1
					nextFrame = min(current.lastFrame, current.firstFrame + 1)
				} else {
					finish()
					return
				}
			}

			frameIndex = nextFrame
			if let frame = currentFrame {
				delegate?.spriteAnimator(self, didChangeTo: frame)
			}
		}
	}

	private func finish() {
		completed = true
		delegate?.spriteAnimator(self, didFinishClip: requestedClipName)
	}
}

/// Pair-scene timings referenced by the clip table.
public enum CompanionLifeConstants {
	public static let kickFrameSeconds: Double = 0.13
	public static let kickContact = 7 * kickFrameSeconds
	public static let rallySeconds: Double = 1.6
	public static let rallyCount = 6
}
