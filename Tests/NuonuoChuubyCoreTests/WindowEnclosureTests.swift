import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The pet as a free body inside a window rectangle, ported from the original's
/// `WindowEnclosurePhysics.Resolve`. The numbers are the original's, so these
/// tests are a specification of that behaviour rather than a description of it.
@Suite("Window enclosure physics")
struct WindowEnclosureTests {
	private let frame = 1.0 / 60

	private func box(
		x: Double = 300,
		y: Double = 200,
		width: Double = 600,
		height: Double = 400
	) -> PixelRect {
		PixelRect(x: x, y: y, width: width, height: height)
	}

	private func pet(
		left: Double,
		top: Double,
		width: Double = 110,
		height: Double = 128
	) -> PixelRect {
		PixelRect(x: left, y: top, width: width, height: height)
	}

	private func step(
		pet body: PixelRect,
		from previous: PixelRect? = nil,
		to current: PixelRect,
		baseline: Double? = nil,
		velocityX: Double = 0,
		velocityY: Double = 0,
		wasOnFloor: Bool = false,
		elapsed: Double? = nil,
		scale: Double = 1
	) -> WindowEnclosureStep {
		WindowEnclosurePhysics.resolve(
			pet: body,
			previousBox: previous ?? current,
			currentBox: current,
			baselineSeconds: baseline,
			velocityX: velocityX,
			velocityY: velocityY,
			wasOnFloor: wasOnFloor,
			elapsedSeconds: elapsed ?? frame,
			scale: scale
		)
	}

	// MARK: - Gravity and walls

	@Test("Gravity pulls her down inside a still box")
	func gravityInAStillBox() {
		let result = step(pet: pet(left: 400, top: 300), to: box())
		#expect(!result.hitAny)
		#expect(result.offsetX == 0)
		#expect(abs(result.offsetY - 27.5 * frame) < 1e-9)
		#expect(abs(result.velocityY - 27.5) < 1e-9)
	}

	@Test("A gentle touch on the floor settles her instead of bouncing")
	func gentleFloorTouchSettles() {
		let result = step(pet: pet(left: 400, top: 466), to: box(), velocityY: 50)
		#expect(result.hitBottom)
		#expect(result.isResting)
		#expect(result.velocityY == 0)
		#expect(abs(result.offsetY) < 1e-9, "she is placed exactly on the wall")
		// Being held up is not an impact. Reporting one here also outranked
		// `isResting` in the controller, which reads `impactSpeed` to decide whether
		// to scream, so a settle used to shout and switch to falling instead.
		#expect(result.impactSpeed == 0)
	}

	@Test("A floor rising slowly under her carries her instead of bouncing her")
	func slowFloorRiseCarriesHer() {
		// 5 pt in a frame is 300 pt/s: an ordinary drag, well under the 900 pt/s
		// that counts as a yank. She is standing on the floor, so it takes her up
		// with it.
		let result = step(
			pet: pet(left: 400, top: 466),
			from: box(),
			to: box(y: 195),
			velocityY: 0,
			wasOnFloor: true
		)
		#expect(result.hitBottom)
		#expect(result.isResting, "carried, not bounced")
		#expect(result.velocityY == -300, "she moves up with the floor")
		#expect(result.impactSpeed == 0)
	}

	@Test("A floor falling slowly under her carries her down instead of dropping her")
	func slowFloorFallCarriesHer() {
		// The mirror of the rise: the floor moves away from her, and she must follow
		// it rather than being left airborne. Being left behind here is what made a
		// slow downward drag show a fall animation.
		let result = step(
			pet: pet(left: 400, top: 466),
			from: box(),
			to: box(y: 205),
			velocityY: 0,
			wasOnFloor: true
		)
		#expect(result.hitBottom)
		#expect(result.isResting)
		#expect(result.velocityY == 300, "she moves down with the floor")
		#expect(result.impactSpeed == 0)
	}

	@Test("A drag that stops does not leave her with the speed it had")
	func stoppingTheDragDoesNotReleaseHer() {
		// She was carried at 300 pt/s and the box has now stopped. She must stop
		// with it: keeping the speed would fling her off the floor, and she would
		// come back down hard enough to be read as a landing — with the fall
		// animation and the line that goes with it.
		let result = step(
			pet: pet(left: 400, top: 466),
			from: box(y: 195),
			to: box(y: 195),
			velocityY: -300,
			wasOnFloor: true
		)
		#expect(result.hitBottom)
		#expect(result.isResting)
		#expect(result.velocityY == 0, "stopped with the floor, not thrown off it")
		#expect(result.impactSpeed == 0, "and not reported as a landing")
	}

	@Test("A floor yanked up throws her instead of carrying her")
	func yankedFloorThrowsHer() {
		// The same move, four times as fast: past the threshold, so it is a throw.
		let result = step(
			pet: pet(left: 400, top: 466),
			from: box(),
			to: box(y: 180),
			velocityY: 0,
			wasOnFloor: true
		)
		#expect(result.hitBottom)
		#expect(!result.isResting)
		#expect(result.velocityY < -500, "flung up at the wall's own (clamped) speed")
		#expect(result.impactSpeed > 800)
	}

	@Test("A floor yanked down leaves her where she was")
	func yankedFloorDownLeavesHer() {
		let result = step(
			pet: pet(left: 400, top: 466),
			from: box(),
			to: box(y: 220),
			velocityY: 0,
			wasOnFloor: true
		)
		// It did not touch her at all: it simply went away. She falls from rest
		// where she stood — released with no speed of her own, gravity applying from
		// the next frame, exactly as the perch releases her. Snapping her down onto
		// the new floor would have carried her a frame's worth of the drag before
		// gravity had any say, which is the framewise version of being stuck to the
		// bottom edge.
		#expect(!result.hitBottom)
		#expect(!result.isResting)
		#expect(result.velocityY == 0, "left behind from rest")
		#expect(result.offsetY == 0, "and still where she was")
		#expect(result.impactSpeed == 0, "nothing to be startled by")
	}

	@Test("A floor yanked down takes its own speed with it")
	func yankedFloorDownDropsItsSpeed() {
		// She was being carried, so she is holding the floor's speed. That speed is
		// the floor's, not hers, and must not come with her: keeping it made a fast
		// downward drag fling her at the floor's speed instead of dropping her from
		// rest, which reads as a heavy shove rather than a fall.
		let result = step(
			pet: pet(left: 400, top: 466),
			from: box(),
			to: box(y: 220),
			velocityY: 850,
			wasOnFloor: true
		)
		#expect(!result.hitBottom)
		#expect(!result.isResting)
		#expect(result.velocityY == 0, "left behind from rest, not thrown down")
		#expect(result.offsetY == 0, "and she does not move this frame")
	}

	@Test("The threshold is the one the perch uses")
	func thresholdMatchesThePerch() {
		// Just under, then just over: the two must fall either side of the boundary.
		let nearly = step(
			pet: pet(left: 400, top: 466),
			from: box(),
			to: box(y: 200 - PlatformRidePhysics.releaseDisplacement + 0.5),
			velocityY: 0,
			wasOnFloor: true
		)
		#expect(nearly.isResting, "just under the threshold is still a carry")

		let past = step(
			pet: pet(left: 400, top: 466),
			from: box(),
			to: box(y: 200 - PlatformRidePhysics.releaseDisplacement),
			velocityY: 0,
			wasOnFloor: true
		)
		#expect(!past.isResting, "past it is a throw")
	}

	@Test("A wall measured over two ticks is judged by its speed, not its distance")
	func yankIsASpeedNotADistance() {
		// The box is not necessarily looked at every frame, and the two rectangles
		// are then further apart for the same movement. Reading that as a larger
		// flick would throw her out of a box the user merely dragged.
		let twoTicks = 2 * frame
		let dragged = step(
			pet: pet(left: 400, top: 466),
			from: box(),
			to: box(y: 200 - 20),
			baseline: twoTicks,
			velocityY: 0,
			wasOnFloor: true
		)
		#expect(dragged.isResting, "20 pt over two ticks is 600 pt/s: a drag")

		let flicked = step(
			pet: pet(left: 400, top: 466),
			from: box(),
			to: box(y: 200 - 20),
			baseline: frame,
			velocityY: 0,
			wasOnFloor: true
		)
		#expect(!flicked.isResting, "the same 20 pt in one tick is 1200 pt/s: a flick")
	}

	@Test("She still bounces off a ceiling she ran into")
	func ceilingSheRanIntoStillBounces() {
		let result = step(pet: pet(left: 400, top: 206), to: box(), velocityY: -400)
		#expect(result.hitTop)
		#expect(abs(result.velocityY - 372.5 * 0.58) < 1e-9)
		#expect(abs(result.impactSpeed - 372.5) < 1e-9)
	}

	@Test("A ceiling coming down onto her carries her down instead of kicking her")
	func descendingCeilingCarriesHer() {
		// 5 pt in a frame: the mirror of the floor case, and the mirror of its fix.
		let result = step(
			pet: pet(left: 400, top: 206),
			from: box(),
			to: box(y: 205),
			velocityY: 0
		)
		#expect(result.hitTop)
		#expect(result.velocityY == 300, "she is pushed down at the ceiling's speed")
		#expect(result.impactSpeed == 0)
	}

	@Test("A hard landing on the floor bounces at 0.48 of the impact")
	func hardFloorLandingBounces() {
		let result = step(pet: pet(left: 400, top: 466), to: box(), velocityY: 400)
		#expect(result.hitBottom)
		#expect(!result.isResting)
		#expect(abs(result.velocityY - -427.5 * 0.48) < 1e-9)
		#expect(abs(result.impactSpeed - 427.5) < 1e-9)
	}

	@Test("The ceiling bounces at 0.58 of the impact")
	func ceilingBounces() {
		let result = step(pet: pet(left: 400, top: 206), to: box(), velocityY: -200)
		#expect(result.hitTop)
		#expect(!result.hitBottom)
		#expect(!result.isResting)
		#expect(abs(result.velocityY - 172.5 * 0.58) < 1e-9)
		#expect(abs(result.offsetY) < 1e-9)
	}

	@Test("An opening wall pushes her along rather than passing through her")
	func openingWallPushesHer() {
		// The box slides 5 pt right in one frame, so its left wall moves at
		// 300 pt/s. She is sitting against where that wall used to be. That is an
		// ordinary drag, not a yank, so the wall **carries** her: a wall that only
		// pushes should not register as a hit, which the controller reads as a reason
		// to scream.
		let result = step(
			pet: pet(left: 306, top: 300),
			from: box(),
			to: box(x: 305),
			velocityX: 0
		)
		#expect(result.hitLeft)
		#expect(!result.hitRight)
		#expect(abs(result.offsetX - 5) < 1e-9, "she is carried out to the new wall")
		#expect(abs(result.velocityX - 300) < 1e-9, "she moves with the wall, not faster")
		#expect(result.impactSpeed == 0)
	}

	@Test("A side wall yanked sideways knocks her clear of it")
	func yankedSideWallKnocksHer() {
		// 100 pt in a frame would be 6000 pt/s; the wall is clamped to 900. Past the
		// threshold, so it is a knock rather than a push, and the clamp applies.
		let result = step(
			pet: pet(left: 306, top: 300),
			from: box(),
			to: box(x: 400),
			velocityX: 0
		)
		#expect(result.hitLeft)
		#expect(abs(result.velocityX - 1350) < 1e-9, "the final speed is clamped, not the wall alone")
		#expect(abs(result.impactSpeed - 900) < 1e-9)
	}

	@Test("A box too narrow to hold her centres her and inherits the wall speed")
	func tooNarrowToHoldHer() {
		let result = step(pet: pet(left: 400, top: 300), to: box(width: 80))
		#expect(result.hitLeft)
		#expect(result.hitRight)
		#expect(abs(result.velocityX) < 1e-9)
		// Centre of (306, 374) for a body spanning 400…510.
		#expect(abs(result.offsetX - (306 + 374 - 400 - 510) / 2) < 1e-9)
	}

	// MARK: - Guards

	@Test("A long frame is clamped to 80 ms")
	func longFrameIsClamped() {
		let result = step(
			pet: pet(left: 1000, top: 1000),
			to: box(x: 0, y: 0, width: 2000, height: 2000),
			elapsed: 1.0
		)
		#expect(!result.hitAny)
		#expect(abs(result.velocityY - 1650 * 0.08) < 1e-9)
		#expect(abs(result.offsetY - 1650 * 0.08 * 0.08) < 1e-9)
	}

	@Test("A degenerate box leaves her velocity alone")
	func degenerateBox() {
		let result = step(
			pet: pet(left: 400, top: 300),
			to: PixelRect(x: 300, y: 200, width: 0, height: 400),
			velocityX: 12,
			velocityY: -34
		)
		#expect(result.offsetX == 0)
		#expect(result.offsetY == 0)
		#expect(result.velocityX == 12)
		#expect(result.velocityY == -34)
		#expect(!result.hitAny)
	}

	@Test("Zero elapsed time is a no-op")
	func zeroElapsed() {
		let result = step(pet: pet(left: 400, top: 300), to: box(), velocityY: 90, elapsed: 0)
		#expect(result.velocityY == 90)
		#expect(result.offsetY == 0)
	}

	@Test("Every threshold scales with the display")
	func thresholdsScale() {
		// At scale 2 the walls are 12 pt in, so the same body is already past the
		// floor; and the rest threshold doubles to 230 pt/s.
		let result = step(pet: pet(left: 400, top: 466), to: box(), velocityY: 50, scale: 2)
		#expect(result.hitBottom)
		#expect(result.isResting, "105 pt/s is still a settle at scale 2")
		#expect(abs(result.offsetY - -6) < 1e-9)
	}

	// MARK: - Capacity

	@Test("A body fits only when it is wholly inside the walls")
	func bodyFitsInsideTheWalls() {
		let frameAndWalls = box()
		let walls = 6.0
		#expect(
			WindowEnclosurePhysics.bodyFits(
				PixelRect(x: 400, y: 300, width: 110, height: 128),
				in: frameAndWalls,
				inset: walls
			)
		)
		// Touching the wall exactly still fits.
		#expect(
			WindowEnclosurePhysics.bodyFits(
				PixelRect(x: 306, y: 206, width: 110, height: 388),
				in: frameAndWalls,
				inset: walls
			)
		)
		// One point past it does not.
		#expect(
			!WindowEnclosurePhysics.bodyFits(
				PixelRect(x: 305, y: 206, width: 110, height: 200),
				in: frameAndWalls,
				inset: walls
			)
		)
		#expect(
			!WindowEnclosurePhysics.bodyFits(
				PixelRect(x: 400, y: 300, width: 110, height: 300),
				in: frameAndWalls,
				inset: walls
			)
		)
	}

	@Test("A box narrower than the body never fits it")
	func boxNarrowerThanBody() {
		#expect(
			!WindowEnclosurePhysics.bodyFits(
				PixelRect(x: 300, y: 300, width: 110, height: 128),
				in: box(width: 80),
				inset: 6
			)
		)
	}

	@Test("Room is a question about size, not about where she is standing")
	func roomIgnoresPosition() {
		let body = PixelRect(x: 300, y: 300, width: 110, height: 128)
		// Far outside the box, and still there is room in it for her. Keeping her
		// between the walls is `resolve`'s job; a subpixel remainder can leave her
		// a fraction of a point past a wall without meaning the box no longer fits.
		#expect(WindowEnclosurePhysics.boxHasRoom(for: body, in: box(), inset: 6))
		#expect(WindowEnclosurePhysics.boxHasRoom(for: body, in: box(x: 4000), inset: 6))

		// Exactly big enough counts as room; a point less does not.
		let exact = PixelRect(x: 0, y: 0, width: 110 + 12, height: 128 + 12)
		#expect(WindowEnclosurePhysics.boxHasRoom(for: body, in: exact, inset: 6))
		#expect(
			!WindowEnclosurePhysics.boxHasRoom(
				for: body,
				in: PixelRect(x: 0, y: 0, width: 121, height: 128 + 12),
				inset: 6
			)
		)
		#expect(!WindowEnclosurePhysics.boxHasRoom(for: body, in: box(width: 80), inset: 6))
	}
}
