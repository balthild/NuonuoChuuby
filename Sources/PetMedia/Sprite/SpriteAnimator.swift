import CoreGraphics
import Foundation
import PetFoundation

@MainActor
public protocol SpriteAnimatorDelegate: AnyObject {
	func spriteAnimator(_ animator: SpriteAnimator, didChangeTo frame: CGImage)
	func spriteAnimator(_ animator: SpriteAnimator, didFinishClip clip: String)
}

/// Steps a clip's frames over time.
@MainActor
public final class SpriteAnimator {
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

		let table = SpriteClipTable.clips(for: profile)
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

		if let alias = SpriteClipTable.hatlessAliases[clipName], let bare = clips[alias] {
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
