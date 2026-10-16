import Foundation
import Testing

@testable import NuonuoChuubyCore

/// Walking along a surface she is already standing on.
///
/// The walk must not be bounded by a clock. Reaching a window's edge can take
/// longer than any fixed timeout, and cutting the walk short jumps her the rest of
/// the way in a single frame — the teleport she used to make at the foot of a wall
/// before climbing it.
@MainActor
@Suite("Ground walk", .serialized)
struct GroundWalkTests {
	private static var assetsRoot: URL? { TestAssets.root }

	enum TestSkip: Error { case missingAssets }

	private static let frame = 1.0 / 60
	private static let workWidth: Double = 1728
	private static let workHeight: Double = 1117

	private struct Rig {
		var controller: PetController
		var provider: SurfaceProvider
		var platform: MockPlatform
		var floor: Surface
		var directory: URL
	}

	private func makeRig() throws -> Rig {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-ground-walk-\(UUID().uuidString)")

		let platform = MockPlatform.singleMonitor(width: Self.workWidth, height: Self.workHeight)
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: Self.workHeight)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: provider,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space,
			randomSeed: TestAssets.randomSeed
		)
		let floor = try #require(provider.surfaces.first { $0.key.kind == .floor })
		return Rig(
			controller: controller,
			provider: provider,
			platform: platform,
			floor: floor,
			directory: directory
		)
	}

	@Test("A long walk arrives at a walking pace, with no give-up teleport")
	func aLongWalkIsNotTeleported() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		rig.controller.debugPlaceOnSurface(rig.floor)
		// The commanded walk below is unaffected, but nothing else may start once it
		// ends: the assertions are about this walk, and self-directed behaviour after
		// it would be a different walk they would have to tell apart.
		rig.controller.quietMode = true

		// The floor runs the width of the display and she starts at its centre, so
		// the far end is more than the 8 s a give-up timeout allowed at the 92 pt/s
		// walking pace. If the setup fell inside that budget the test would pass
		// whether or not the timeout still existed.
		let target = Self.workWidth - 20
		let startX = rig.controller.debugState.foot.x
		#expect(
			target - startX > 8 * 92,
			"the walk must outlast the old give-up timeout to be a real test"
		)

		rig.controller.debugBeginWalk(toX: target)
		#expect(rig.controller.debugState.movementPurpose == .wander)

		var previousX = startX
		var biggestStep = 0.0
		for _ in 0..<900 {
			rig.controller.debugStep(delta: Self.frame)
			let x = rig.controller.debugState.foot.x
			biggestStep = max(biggestStep, abs(x - previousX))
			previousX = x
		}

		#expect(rig.controller.debugState.state != .running, "she finished the walk")
		#expect(abs(previousX - target) <= 5, "she arrived, at x=\(previousX)")
		#expect(
			biggestStep < 10,
			"no frame may move her more than a walking step, but one moved \(biggestStep)"
		)
	}
}
