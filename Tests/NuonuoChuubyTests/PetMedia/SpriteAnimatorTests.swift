import CoreGraphics
import Foundation
import Testing

@testable import PetFoundation
@testable import PetMedia

/// Handing a looping clip to the render server.
///
/// A loop is not stepped by the tick any more, so the frames it plays have to be exactly
/// the frames the tick would have shown — otherwise she would quietly change how she
/// animates, which nothing else would notice. The pairs below are held against each other
/// rather than checked one at a time, because that equivalence is the whole contract.
@MainActor
@Suite("Sprite loops")
struct SpriteAnimatorTests {
	enum TestSkip: Error { case missingAssets }

	/// Records what the animator announces.
	private final class Spy: SpriteAnimatorDelegate {
		var frames: [CGImage] = []
		var loops: [SpriteLoop] = []
		var finished: [String] = []

		func spriteAnimator(_ animator: SpriteAnimator, didChangeTo frame: CGImage) {
			frames.append(frame)
		}

		func spriteAnimator(_ animator: SpriteAnimator, didBeginLoop loop: SpriteLoop) {
			loops.append(loop)
		}

		func spriteAnimator(_ animator: SpriteAnimator, didFinishClip clip: String) {
			finished.append(clip)
		}
	}

	private func animator() throws -> (SpriteAnimator, Spy, AssetCatalog) {
		guard let root = TestAssets.root else { throw TestSkip.missingAssets }
		// One catalog for both: two of them decode the same files into different
		// `CGImage`s, so identity between their frames would never hold.
		let catalog = AssetCatalog(locator: AssetLocator(root: root))
		let animator = SpriteAnimator(catalog: catalog)
		let spy = Spy()
		animator.delegate = spy
		return (animator, spy, catalog)
	}

	/// Which frame of its folder each image is, by identity — the only thing that can say
	/// whether two of these are really the same frame and not two look-alikes.
	private func indices(
		of frames: [CGImage],
		inFolder folder: String,
		catalog: AssetCatalog
	)
		throws -> [Int]
	{
		let all = catalog.frames(character: .nuonuo, folder: folder)
		return try frames.map { frame in
			try #require(
				all.firstIndex { ($0 as AnyObject) === (frame as AnyObject) },
				"a frame that is not in \(folder)"
			)
		}
	}

	/// The frames the tick would show, one full cycle's worth, from the clip's own start.
	///
	/// Walked with the same rule the tick uses, from the clip's definition, which is what
	/// makes this an independent check of the cycle handed over rather than a restatement.
	private func tickCycle(
		of clipName: String,
		profile: PetCharacterProfile = .nuonuo
	) throws -> [Int] {
		let strip = try trim(clipName)
		let clip = strip.clip
		var index = clip.startReversed ? clip.lastFrame : clip.firstFrame
		var direction = clip.startReversed ? -1 : 1
		var seen: [Int] = [index]
		// Several cycles' worth, so the period (up to twice the clip's length) is less than
		// half the walk — the search below needs at least one full repeat to check against.
		let span = abs(clip.lastFrame - clip.firstFrame) + 1
		for _ in 0..<(span * 5 + 2) {
			guard let next = SpriteAnimator.step(from: index, direction: direction, in: clip) else {
				break
			}
			index = next.index
			direction = next.direction
			seen.append(index)
		}
		return seen
	}

	private func trim(_ clipName: String) throws -> (clip: SpriteClip, profile: PetCharacterProfile) {
		let table = SpriteClipTable.clips(for: .nuonuo)
		let clip = try #require(table[clipName], "no clip \(clipName)")
		return (clip, .nuonuo)
	}

	@Test(
		"A looped clip hands over exactly the cycle the tick would have played",
		arguments: ["idle", "sleep", "drag", "run"]
	)
	func theCycleMatchesTheTick(clipName: String) throws {
		let (animator, spy, catalog) = try animator()
		animator.play(clipName)

		let loop = try #require(spy.loops.first, "\(clipName) should be handed over")
		#expect(spy.frames.isEmpty, "a handed-over loop must not also be stepped")

		let walked = try tickCycle(of: clipName)
		let played = try indices(
			of: loop.frames,
			inFolder: animator.currentAssetFolder,
			catalog: catalog
		)

		// One period of the walk: the shortest prefix from which it repeats. The two are
		// the same cycle entered at different points — a ping-pong clip's entry state is
		// not its steady state, so the comparison is by rotation.
		let period = try #require(
			firstPeriod(of: walked),
			"the \(clipName) walk does not repeat within \(walked.count) frames"
		)
		#expect(
			isRotation(played, of: period),
			"\(clipName): the loop plays \(played) but the tick plays \(period)"
		)
		// And it starts where she would have: the first frame drawn is the clip's own.
		#expect(played.first == walked.first, "\(clipName) starts on a different frame")
	}

	@Test("A ping-pong clip turns around without repeating either end")
	func pingPongTurnsAround() throws {
		let (animator, spy, catalog) = try animator()
		animator.play("sleep")
		let played = try indices(
			of: try #require(spy.loops.first).frames,
			inFolder: "sleep",
			catalog: catalog
		)

		// `sleep` is frames 8...15 of its folder, played up and back down: eight up, then
		// six back down (the ends are not repeated), which is 2n - 2 for n = 8.
		#expect(played.count == 14)
		#expect(played.first == 8)
		#expect(played.max() == 15)
		// The ends appear once and the middle twice. Repeating an end would show the same
		// frame for two frame-times at each end, which reads as a hitch every cycle.
		let counts = played.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
		#expect(counts[8] == 1, "the low end is held")
		#expect(counts[15] == 1, "the high end is held")
		#expect(counts[11] == 2, "a middle frame is not repeated")
		_ = animator
	}

	@Test("A clip that stops is never handed over, and its frames keep arriving")
	func aFiniteClipIsStepped() throws {
		for clipName in ["land", "toss", "sleep_enter", "chomp"] {
			let (animator, spy, _) = try animator()
			animator.play(clipName)
			#expect(spy.loops.isEmpty, "\(clipName) should not be handed over")
			#expect(spy.frames.count == 1, "\(clipName) should arrive as a step")
			#expect(animator.currentLoop == nil, "\(clipName) has no loop to hand over")

			// Stepping it reports frames, and the end reports the end — which is what a
			// handed-over loop cannot do.
			let clip = try trim(clipName).clip
			let frames = abs(clip.lastFrame - clip.firstFrame) + 2
			for _ in 0..<frames { animator.tick(clip.frameSeconds) }
			#expect(spy.finished == [clipName], "\(clipName) should report its end")
		}
	}

	@Test("Re-announcing says the same thing the clip started with")
	func announcingAgainSaysTheSame() throws {
		let (animator, spy, _) = try animator()

		animator.play("idle")
		#expect(spy.loops.count == 1)
		animator.announceCurrent()
		#expect(spy.loops.count == 2, "a loop is announced again, not stepped")
		#expect(spy.frames.isEmpty)

		animator.play("land")
		#expect(spy.frames.count == 1)
		animator.announceCurrent()
		#expect(spy.frames.count == 2, "a stepped clip is re-announced as a frame")
		#expect(spy.loops.count == 2)
	}

	@Test("Every clip in the table either hands over a cycle or is stepped")
	func everyClipPicksOneWay() throws {
		for clipName in SpriteClipTable.clips(for: .nuonuo).keys.sorted() {
			let (animator, spy, _) = try animator()
			animator.play(clipName)
			let handedOver = !spy.loops.isEmpty
			let stepped = !spy.frames.isEmpty
			#expect(handedOver != stepped, "\(clipName) did both or neither")
			#expect(handedOver == (animator.currentLoop != nil), "\(clipName) disagrees with itself")
			if handedOver {
				#expect(
					try #require(spy.loops.first).frames.count > 1,
					"\(clipName) handed over a cycle with nothing in it"
				)
			}
		}
	}

	// MARK: - Comparing sequences

	/// The shortest prefix that the sequence then repeats for ever, or nil if it does not.
	///
	/// Only from `length` onwards is the walk required to line up: a ping-pong clip is one
	/// frame away from its steady cycle when it starts, so the very beginning is allowed to
	/// sit outside the period.
	private func firstPeriod(of walk: [Int]) -> [Int]? {
		guard walk.count > 3 else { return walk }
		for length in 1...(walk.count / 2) {
			let repeats = walk.indices.dropFirst(length).allSatisfy { walk[$0] == walk[$0 - length] }
			if repeats { return Array(walk.prefix(length)) }
		}
		return nil
	}

	private func isRotation(_ candidate: [Int], of other: [Int]) -> Bool {
		guard candidate.count == other.count, !candidate.isEmpty else { return false }
		return (0..<other.count).contains { offset in
			(0..<other.count).allSatisfy { other[($0 + offset) % other.count] == candidate[$0] }
		}
	}
}
