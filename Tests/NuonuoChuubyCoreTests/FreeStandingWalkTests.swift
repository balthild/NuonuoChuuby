import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The two walks that leave the surface behind: to a meal, and to an icon.
///
/// Both move her feet off the edge she is anchored to without ever going through
/// `beginFall`, so the perch has to work out on its own that she is somewhere else.
/// Until it did, the edge she set off from rode her back to it the moment the walk
/// ended — a teleport with no explanation on screen.
///
/// Both tests are arranged so that nothing else can hide the problem. A perch that
/// no longer covers her feet is already rejected, so her x must stay well inside
/// the edge she set off from: if it did not, the perch would be dropped as
/// "covered" and she would fall for the wrong reason, and the test would pass
/// whether or not her drift is noticed at all.
@MainActor
@Suite("Free-standing walks", .serialized)
struct FreeStandingWalkTests {
	private static var assetsRoot: URL? { TestAssets.root }

	enum TestSkip: Error { case missingAssets }

	private static let frame = 1.0 / 60
	private static let windowID: UInt32 = 6060
	/// A wide window she can start on: its edge is below the icon she walks to, and
	/// wide enough to still contain her once she is up there.
	private static let ledgeTop: Double = 700
	private static let ledge = PixelRect(x: 200, y: ledgeTop, width: 1400, height: 300)
	/// The one icon she may lick, and the one meal she is offered.
	private static let spot = PixelPoint(x: 700, y: 300)

	private struct Rig {
		var controller: PetController
		var provider: SurfaceProvider
		var platform: MockPlatform
		var ledge: Surface
		var floor: Surface
		var directory: URL
	}

	/// A real ``MockPlatform`` rather than the surface-injection seam, because a
	/// walk spans seconds: the graph is rebuilt on its own cadence as she goes, and
	/// an injected graph would be wiped by the first rebuild.
	private func makeRig() throws -> Rig {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-walk-\(UUID().uuidString)")

		let platform = MockPlatform.singleMonitor(width: 1728, height: 1117)
		platform.setWindows([
			PlatformWindow(
				id: Self.windowID,
				ownerPID: 4242,
				ownerName: "Safari",
				bounds: Self.ledge,
				layer: 0,
				alpha: 1
			)
		])
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: 1117)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: provider,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space,
			randomSeed: TestAssets.randomSeed
		)

		let ledge = try #require(provider.surfaces.first { $0.key.kind == .windowTop })
		let floor = try #require(provider.surfaces.first { $0.key.kind == .floor })
		return Rig(
			controller: controller,
			provider: provider,
			platform: platform,
			ledge: ledge,
			floor: floor,
			directory: directory
		)
	}

	/// Runs whole frames until `condition` holds, and reports how many it took.
	@discardableResult
	private func run(_ rig: Rig, upTo limit: Int, until condition: () -> Bool) -> Int {
		var frames = 0
		while !condition(), frames < limit {
			rig.controller.debugStep(delta: Self.frame)
			frames += 1
		}
		return frames
	}

	@Test("The last frame of a lick leaves her falling, not walking back")
	func lickEndsInAFall() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		rig.controller.debugPlaceOnSurface(rig.ledge)

		// One icon, put there by hand: the pick is otherwise random, and what this
		// test is about is where she ends up, not which icon she chose.
		let index = DesktopIconIndex(reader: {
			[DesktopIcon(name: "a.txt", position: Self.spot, size: 56)]
		})
		index.refresh()
		rig.controller.desktopIcons = index

		#expect(rig.controller.tryBeginIconLick(manual: false))
		#expect(rig.controller.debugState.movementPurpose == .iconLick)

		run(rig, upTo: 900) { rig.controller.state == .licking }
		#expect(rig.controller.state == .licking, "she reached the icon")

		let atTheIcon = rig.controller.debugState
		#expect(abs(atTheIcon.foot.y - Self.spot.y) < 150, "she is down at the icon")
		#expect(atTheIcon.perchKey == rig.ledge.key, "the ledge is still her perch, untouched")

		// The clip does not loop, and it ends inside the animation tick — so the first
		// look that shows her out of the lick must show her already falling. The ledge
		// is still there and still under her, so the ride would otherwise have put her
		// back on it, one frame later.
		run(rig, upTo: 300) { rig.controller.state != .licking }
		let afterTheLick = rig.controller.debugState
		#expect(afterTheLick.state == .falling, "the lick ends in a fall")
		#expect(afterTheLick.perchKey == nil, "nothing holds her once the walk is over")
		#expect(afterTheLick.movementPurpose == .none, "the walk's purpose is finished with")
		#expect(abs(afterTheLick.foot.y - Self.spot.y) < 150, "she falls from the icon")

		// Straight down, onto the edge she licked above.
		run(rig, upTo: 900) { rig.controller.state == .landing }
		let landed = rig.controller.debugState
		#expect(landed.state == .landing)
		#expect(landed.perchKey == rig.ledge.key)
		#expect(landed.foot.y == Self.ledgeTop)
	}

	@Test("Eating off the floor leaves her up at the food, then lets her go")
	func mealEndsInAFall() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		// The floor is the perch to beat: its edge runs the width of the display, so
		// it covers her feet whatever x she walked to.
		rig.controller.debugPlaceOnSurface(rig.floor)

		let accepted = rig.controller.enqueueMeals([
			DeletedItem(
				id: 1,
				originalPath: "/tmp/a.txt",
				displayName: "a.txt",
				detectedAt: Date(),
				anchor: Self.spot,
				exactAnchor: true
			)
		])
		#expect(accepted == 1)
		#expect(rig.controller.debugState.movementPurpose == .meal)

		// She walks up, eats, and strikes a pose: `.satisfied` ends in idle.
		run(rig, upTo: 1200) { rig.controller.state == .idle }
		#expect(rig.controller.state == .idle, "the meal finishes")

		let afterTheMeal = rig.controller.debugState
		#expect(abs(afterTheMeal.foot.y - Self.spot.y) < 150, "she is still up at the food")
		#expect(afterTheMeal.perchKey == rig.floor.key, "and still nominally on the floor")

		// A perch is resolved by identity and the floor is exactly where it was, so
		// only her own drift gives her away.
		run(rig, upTo: 300) { rig.controller.state == .falling }
		let falling = rig.controller.debugState
		#expect(falling.state == .falling)
		#expect(falling.perchKey == nil)
		#expect(falling.movementPurpose == .none)
		#expect(abs(falling.foot.y - Self.spot.y) < 150, "she falls from the food, not the floor")
	}

	@Test("A meal wakes her instead of waiting for the nap to end")
	func mealWakesHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		rig.controller.debugPlaceOnSurface(rig.floor)
		rig.controller.debugBeginSleep()
		#expect(rig.controller.state == .sleeping)

		let accepted = rig.controller.enqueueMeals([
			DeletedItem(
				id: 1,
				originalPath: "/tmp/a.txt",
				displayName: "a.txt",
				detectedAt: Date(),
				anchor: Self.spot,
				exactAnchor: true
			)
		])
		#expect(accepted == 1)
		#expect(rig.controller.state == .waking, "the meal wakes her")

		// The get-up clip runs, and then she sets off on her own.
		run(rig, upTo: 1200) { rig.controller.debugState.movementPurpose == .meal }
		#expect(rig.controller.debugState.movementPurpose == .meal, "she goes to the meal")

		run(rig, upTo: 1200) { rig.controller.state == .idle }
		#expect(rig.controller.state == .idle, "the meal finishes")
	}

	/// Records the three moments of a meal's life: the queue entry, which is where
	/// the ghost icon first goes up, and the two ends of the walk.
	@MainActor
	private final class MealSpy: PetMealDelegate {
		var enqueued: [[Int]] = []
		var begun: [Int] = []
		var finished: [Int] = []

		func petController(_ controller: PetController, didEnqueueMeals items: [DeletedItem]) {
			enqueued.append(items.map(\.id))
		}

		func petController(_ controller: PetController, didBeginMeal item: DeletedItem) {
			begun.append(item.id)
		}

		func petController(_ controller: PetController, didFinishMeal item: DeletedItem) {
			finished.append(item.id)
		}
	}

	@Test("The icons go up when the files are deleted, not when she sets off")
	func iconsAppearBeforeTheWalk() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		rig.controller.debugPlaceOnSurface(rig.floor)
		// Asleep, so she certainly cannot set off for either of them yet.
		rig.controller.debugBeginSleep()

		let spy = MealSpy()
		rig.controller.mealDelegate = spy

		let accepted = rig.controller.enqueueMeals([
			DeletedItem(
				id: 1,
				originalPath: "/tmp/a.txt",
				displayName: "a.txt",
				detectedAt: Date(),
				anchor: Self.spot,
				exactAnchor: true
			),
			DeletedItem(
				id: 2,
				originalPath: "/tmp/b.txt",
				displayName: "b.txt",
				detectedAt: Date(),
				anchor: PixelPoint(x: Self.spot.x + 120, y: Self.spot.y),
				exactAnchor: true
			),
		])
		#expect(accepted == 2)
		#expect(spy.enqueued == [[1, 2]], "both icons are up while she is still asleep")
		#expect(spy.begun.isEmpty, "and she has not set off for either")

		// Waking for the meal she takes them in the order they arrived.
		run(rig, upTo: 2400) { spy.begun.count == 2 }
		#expect(spy.begun == [1, 2], "the same items, in the same order, when she does set off")
	}

	@Test("Quiet mode puts the queued icons away and refuses the next deletion")
	func quietModeDropsTheQueue() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		rig.controller.debugPlaceOnSurface(rig.floor)

		let spy = MealSpy()
		rig.controller.mealDelegate = spy

		#expect(
			rig.controller.enqueueMeals([
				DeletedItem(
					id: 1,
					originalPath: "/tmp/a.txt",
					displayName: "a.txt",
					detectedAt: Date(),
					anchor: Self.spot,
					exactAnchor: true
				),
				DeletedItem(
					id: 2,
					originalPath: "/tmp/b.txt",
					displayName: "b.txt",
					detectedAt: Date(),
					anchor: PixelPoint(x: Self.spot.x + 120, y: Self.spot.y),
					exactAnchor: true
				),
			]) == 2
		)

		// Quiet mode means "only rest and sleep", so the food she was heading for and
		// the food still waiting both go, and their icons come down with them.
		rig.controller.quietMode = true
		#expect(spy.finished == [1, 2], "both icons come down")
		#expect(rig.controller.debugQueuedMealCount == 0, "and the queue is empty")

		// A deletion that arrives while quiet mode is on is refused at the door, which
		// is what the original does: it never queues the item and never makes a ghost.
		let refused = rig.controller.enqueueMeals([
			DeletedItem(
				id: 3,
				originalPath: "/tmp/c.txt",
				displayName: "c.txt",
				detectedAt: Date(),
				anchor: Self.spot,
				exactAnchor: true
			)
		])
		#expect(refused == 0)
		#expect(spy.enqueued == [[1, 2]], "nothing new goes up")
	}

	@Test("An interruption that is not a drag hands the meal back instead of losing it")
	func pinchDuringAMealRequeuesIt() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		rig.controller.debugPlaceOnSurface(rig.floor)

		let spy = MealSpy()
		rig.controller.mealDelegate = spy

		let accepted = rig.controller.enqueueMeals([
			DeletedItem(
				id: 1,
				originalPath: "/tmp/a.txt",
				displayName: "a.txt",
				detectedAt: Date(),
				anchor: Self.spot,
				exactAnchor: true
			)
		])
		#expect(accepted == 1)
		#expect(spy.begun == [1], "its ghost icon is up")

		// A pinch takes her out of the walk. Only a drag used to give the item back,
		// so this left the icon on the display for ever and the queue unable to move
		// on — a meal she abandoned is indistinguishable from one she never began.
		rig.controller.beginPinch(side: .right, at: CGPoint(x: 40, y: 60))
		#expect(rig.controller.state == .pinching)
		rig.controller.debugStep(delta: Self.frame)
		#expect(spy.finished == [1], "the icon comes down with the walk")

		rig.controller.endPinch()
		run(rig, upTo: 1200) { rig.controller.debugState.movementPurpose == .meal }
		#expect(rig.controller.debugState.movementPurpose == .meal, "she sets off for it again")
		#expect(spy.begun == [1, 1], "with a new icon standing in for it")

		run(rig, upTo: 2400) { rig.controller.state == .idle }
		#expect(rig.controller.state == .idle, "the meal still finishes")
		#expect(spy.finished == [1, 1])
	}
}
