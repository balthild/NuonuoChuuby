import CoreGraphics
import Foundation
import PetFoundation

@MainActor
public protocol SpriteAnimatorDelegate: AnyObject {
	func spriteAnimator(_ animator: SpriteAnimator, didChangeTo frame: CGImage)
	/// A looping clip was started, whole, for the render server to play.
	///
	/// Only one of this and ``spriteAnimator(_:didChangeTo:)`` is in force at a time: a
	/// handed-over loop is not stepped by the tick, so no frames are reported until a clip
	/// that stops takes over.
	func spriteAnimator(_ animator: SpriteAnimator, didBeginLoop loop: SpriteLoop)
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
	/// Whether the clip playing now was handed to the render server whole.
	private var loopHandedOver = false

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

	/// One full cycle of the clip playing now, if the render server can play it.
	///
	/// Nil for a clip that stops — that one has to report its own end, so the tick keeps
	/// stepping it — and for a clip whose frames could not be read.
	public var currentLoop: SpriteLoop? {
		guard current.loop else { return nil }
		let frames = catalog.frames(character: profile, folder: current.assetFolder)
		let indices = cycleIndices()
		guard !indices.isEmpty else { return nil }
		let cycle = indices.compactMap { index -> CGImage? in
			guard frames.indices.contains(index) else { return nil }
			return frames[index]
		}
		guard cycle.count == indices.count else { return nil }
		return SpriteLoop(clip: requestedClipName, frames: cycle, frameSeconds: current.frameSeconds)
	}

	/// Re-announces what is playing now, for a caller that attached after it started.
	public func announceCurrent() {
		if let loop = currentLoop {
			loopHandedOver = true
			delegate?.spriteAnimator(self, didBeginLoop: loop)
		} else if let frame = currentFrame {
			loopHandedOver = false
			delegate?.spriteAnimator(self, didChangeTo: frame)
		}
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
		announceCurrent()
	}

	public func tick(_ deltaSeconds: Double) {
		guard !completed, deltaSeconds.isFinite, deltaSeconds > 0 else { return }

		playbackSeconds += deltaSeconds
		elapsed += deltaSeconds
		while elapsed >= current.frameSeconds {
			elapsed -= current.frameSeconds
			guard let stepped = Self.step(from: frameIndex, direction: direction, in: current) else {
				finish()
				return
			}
			frameIndex = stepped.index
			direction = stepped.direction
			if !loopHandedOver, let frame = currentFrame {
				delegate?.spriteAnimator(self, didChangeTo: frame)
			}
		}
	}

	/// The frame after one step, or nil when the clip is not looping and has run out.
	///
	/// The one place the walking rule lives, so the cycle handed to the render server and
	/// the frames the tick would have reported cannot disagree about what the clip does.
	/// Internal rather than private so `SpriteAnimatorTests` can walk it and hold it against
	/// the cycle — the two are only equivalent by construction.
	static func step(
		from index: Int,
		direction: Int,
		in clip: SpriteClip
	) -> (index: Int, direction: Int)? {
		let next = index + direction
		if direction > 0, next > clip.lastFrame {
			guard clip.loop else { return nil }
			if clip.pingPong {
				return (max(clip.firstFrame, clip.lastFrame - 1), -1)
			}
			return (clip.firstFrame, 1)
		}
		if direction < 0, next < clip.firstFrame {
			guard clip.loop else { return nil }
			return (min(clip.lastFrame, clip.firstFrame + 1), 1)
		}
		return (next, direction)
	}

	/// Every frame index in one cycle, in play order, starting at the clip's first frame.
	///
	/// A ping-pong clip goes up the frames and back down them without repeating either end,
	/// which is one cycle of `2n - 2` frames for `n` frames; a plain loop is just `n`. The
	/// order is derived here rather than walked from ``step(from:direction:in:)`` because a
	/// ping-pong clip's *entry* into its cycle is not the same state as its steady state,
	/// so walking for a repeat would never return to where it started.
	///
	/// `SpriteAnimatorTests` holds this against the frames the tick actually emits over a
	/// cycle, so the two cannot drift apart unnoticed.
	private func cycleIndices() -> [Int] {
		let forward = Array(current.firstFrame...current.lastFrame)
		let ordered = current.startReversed ? forward.reversed().map { $0 } : forward
		guard current.pingPong, ordered.count > 2 else { return ordered }
		return ordered + ordered.dropFirst().dropLast().reversed()
	}

	private func finish() {
		completed = true
		delegate?.spriteAnimator(self, didFinishClip: requestedClipName)
	}
}
