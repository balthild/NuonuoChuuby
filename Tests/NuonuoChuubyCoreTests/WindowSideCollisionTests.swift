import Foundation
import Testing

@testable import NuonuoChuubyCore

/// A window's left or right edge sweeping through the pet's body. Ported from the
/// original's `WindowSideCollisionPolicy.Resolve`.
@Suite("Window side collision")
struct WindowSideCollisionTests {
	private let frame = 1.0 / 60

	/// The body she can be hit in: 520…640 across, 300…428 down.
	private let body = PixelRect(x: 520, y: 300, width: 120, height: 128)

	private func box(
		_ x: Double,
		_ width: Double,
		top: Double = 200,
		height: Double = 300
	)
		-> PixelRect
	{
		PixelRect(x: x, y: top, width: width, height: height)
	}

	private func resolve(
		from previous: PixelRect,
		to current: PixelRect,
		elapsed: Double? = nil,
		scale: Double = 1
	) -> WindowSideImpact? {
		WindowSideCollisionPolicy.resolve(
			previous: previous,
			current: current,
			pet: body,
			elapsedSeconds: elapsed ?? frame,
			scale: scale
		)
	}

	// MARK: - The two directions

	@Test("A right edge sweeping right throws her right")
	func rightEdgeThrowsRight() throws {
		let resolved = try #require(resolve(from: box(300, 220), to: box(300, 240)))
		#expect(resolved.direction == 1)
		#expect(resolved.edgeVelocityX == 1100, "the reported edge speed is clamped")
		#expect(resolved.petVelocityX == 1112)
		#expect(resolved.petVelocityY == -143.5)
		#expect(resolved.correctionX == 22, "only far enough to clear her body")
	}

	@Test("A left edge sweeping left throws her left")
	func leftEdgeThrowsLeft() throws {
		// It starts just past her right side and sweeps in over her.
		let resolved = try #require(resolve(from: box(641, 200), to: box(621, 200)))
		#expect(resolved.direction == -1)
		#expect(resolved.edgeVelocityX == -1100)
		#expect(resolved.petVelocityX == -1112)
		#expect(resolved.petVelocityY == -143.5)
		#expect(resolved.correctionX == -21)
	}

	@Test("The correction is capped at 45% of her body width")
	func correctionIsCapped() throws {
		let resolved = try #require(resolve(from: box(300, 220), to: box(300, 320)))
		#expect(resolved.correctionX == 120 * 0.45)
	}

	@Test("A slow sweep still gets the minimum throw")
	func slowSweepGetsTheMinimum() throws {
		let resolved = try #require(resolve(from: box(300, 220), to: box(300, 220.5)))
		#expect(resolved.petVelocityX == 230, "the horizontal throw has a floor")
		#expect(resolved.petVelocityY == -125, "as does the lift")
		#expect(resolved.correctionX == 2.5)
	}

	// MARK: - What does not count

	@Test("A sweep below the minimum edge speed is not a hit")
	func tooSlowIsNotAHit() {
		#expect(resolve(from: box(300, 220), to: box(300, 220.3)) == nil)
	}

	@Test("An edge that does not overlap her body vertically is not a hit")
	func noVerticalOverlapIsNotAHit() {
		// The window is well below her, so its edge passes under her feet.
		#expect(
			resolve(from: box(300, 220, top: 600), to: box(300, 240, top: 600)) == nil
		)
	}

	@Test("An edge that never reached her is not a hit")
	func edgeThatNeverReachedHer() {
		#expect(resolve(from: box(300, 100), to: box(300, 150)) == nil)
	}

	@Test("A jump too large to be a drag is a teleport, not a throw")
	func aTeleportIsNotAThrow() {
		// Half a second of elapsed time is the limit; beyond it the window was
		// restored or snapped, not dragged.
		#expect(resolve(from: box(300, 220), to: box(300, 240), elapsed: 0.6) == nil)
		#expect(resolve(from: box(300, 220), to: box(300, 240), elapsed: 0) == nil)
	}

	@Test("A degenerate window rectangle is not a hit")
	func degenerateRectangle() {
		#expect(resolve(from: box(300, 0), to: box(300, 240)) == nil)
		#expect(resolve(from: box(300, 220), to: box(300, 0)) == nil)
	}

	// MARK: - Scaling

	@Test("Every threshold scales with the display")
	func thresholdsScale() {
		// 30 pt/s clears the 22 pt/s floor at scale 1 but not the 44 pt/s one at
		// scale 2.
		#expect(resolve(from: box(300, 220), to: box(300, 220.5)) != nil)
		#expect(resolve(from: box(300, 220), to: box(300, 220.5), scale: 2) == nil)
	}
}
