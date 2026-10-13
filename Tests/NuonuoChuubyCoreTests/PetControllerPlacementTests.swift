import Foundation
import ImageIO
import Testing

@testable import NuonuoChuubyCore

/// Exercises the real controller with the seeded assets. This is the layer where
/// the "pet stands still until you let go" bug lived, so the drag path is
/// covered explicitly.
@MainActor
@Suite("Pet controller placement", .serialized)
struct PetControllerPlacementTests {
	private final class DelegateSpy: PetControllerDelegate {
		var placements = 0
		var suspensions: [Bool] = []
		func petController(_ controller: PetController, didProduceFrame image: CGImage) {}
		func petControllerDidChangePlacement(_ controller: PetController) { placements += 1 }
		func petControllerDidRequestMenu(_ controller: PetController) {}
		func petController(_ controller: PetController, didChangeSuspension suspended: Bool) {
			suspensions.append(suspended)
		}
	}

	/// The assets seeded into the resource folder by `make assets`.
	private static var assetsRoot: URL? {
		let testFile = URL(fileURLWithPath: #filePath)
		let repoRoot =
			testFile
			.deletingLastPathComponent()  // NuonuoChuubyCoreTests
			.deletingLastPathComponent()  // Tests
			.deletingLastPathComponent()  // repo root
		let root = repoRoot.appendingPathComponent("Sources/NuonuoChuubyCore/Resources/Assets")
		return FileManager.default.fileExists(atPath: root.path) ? root : nil
	}

	private func makeController(available: Bool = true) throws -> (PetController, DelegateSpy, URL) {
		guard let root = Self.assetsRoot else {
			throw TestSkip.missingAssets
		}
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-controller-\(UUID().uuidString)")
		let catalogue = AssetCatalog(locator: AssetLocator(root: root))
		let space = DisplaySpace()
		let surfaces = SurfaceProvider()
		surfaces.refresh(displaySpace: space)
		let controller = PetController(
			catalog: catalogue,
			surfaceProvider: surfaces,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space,
			profile: .nuonuo,
			petSize: PetSizePolicy.defaultSize
		)
		let spy = DelegateSpy()
		controller.delegate = spy
		_ = available
		return (controller, spy, directory)
	}

	enum TestSkip: Error { case missingAssets }

	@Test("A drag moves the pet as the cursor moves, without waiting for release")
	func dragMovesThePet() throws {
		let (controller, spy, directory) = try makeController()
		defer { try? FileManager.default.removeItem(at: directory) }

		let grab = controller.foot
		controller.beginDrag(at: grab)
		#expect(controller.state == .dragging)

		let baseline = spy.placements
		// Three intermediate drag callbacks, as a real mouse drag produces.
		controller.updateDrag(to: PixelPoint(x: grab.x + 40, y: grab.y - 30))
		controller.updateDrag(to: PixelPoint(x: grab.x + 80, y: grab.y - 60))
		controller.updateDrag(to: PixelPoint(x: grab.x + 120, y: grab.y - 90))

		#expect(controller.foot.x == grab.x + 120)
		#expect(controller.foot.y == grab.y - 90)
		// Each intermediate move must reposition the window; this is the
		// regression: the pet used to sit still until the button was released.
		#expect(spy.placements >= baseline + 3)
	}

	@Test("The pet keeps the grab offset, so it does not jump under the cursor")
	func dragKeepsGrabOffset() throws {
		let (controller, _, directory) = try makeController()
		defer { try? FileManager.default.removeItem(at: directory) }

		// Grab the pet 50 points to the left of its foot.
		let grab = PixelPoint(x: controller.foot.x + 50, y: controller.foot.y + 10)
		controller.beginDrag(at: grab)
		#expect(abs(controller.dragOffsetForTesting.x - (-50)) < 0.001)

		controller.updateDrag(to: PixelPoint(x: grab.x + 200, y: grab.y))
		#expect(abs(controller.foot.x - (grab.x + 200 - 50)) < 0.001)
	}

	@Test("A drag does not start while the pet is mid-chomp")
	func dragBlockedWhileBusy() throws {
		let (controller, _, directory) = try makeController()
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(DragInteractionPolicy.canStart(from: .chomping) == false)
	}

	@Test("Dragging her below the floor puts her on the floor, not off the screen")
	func dragBelowFloorClamps() throws {
		let (controller, _, directory) = try makeController()
		defer { try? FileManager.default.removeItem(at: directory) }

		let floor = try #require(DisplaySpace().displays.first?.visibleFrame.bottom)
		let grab = controller.foot
		controller.beginDrag(at: grab)
		controller.updateDrag(to: PixelPoint(x: grab.x, y: floor + 4000))

		// Below the floor there is nothing to land on, so on release she would fall
		// straight out of the screen.
		#expect(controller.foot.y == floor)
		#expect(controller.foot.x == grab.x)

		// And releasing from there must land her on the floor, not past it, even
		// though the downward drag carries release inertia.
		controller.endDrag(at: PixelPoint(x: grab.x, y: floor + 4000))
		for _ in 0..<30 { controller.debugStep(delta: 1.0 / 60) }
		#expect(controller.foot.y <= floor + 1)
	}

	@Test("Resizing repositions the window immediately")
	func resizeNotifies() throws {
		let (controller, spy, directory) = try makeController()
		defer { try? FileManager.default.removeItem(at: directory) }

		let baseline = spy.placements
		controller.setSize(320)
		#expect(controller.petSize == 320)
		#expect(spy.placements == baseline + 1)
		// Size is clamped into the supported range.
		controller.setSize(10_000)
		#expect(controller.petSize == PetSizePolicy.fromPercent(PetSizePolicy.maximumPercent))
	}

	@Test("Placement is only reported when it actually changes")
	func placementNotificationsAreIdempotent() throws {
		let (controller, spy, directory) = try makeController()
		defer { try? FileManager.default.removeItem(at: directory) }

		controller.setSize(300)
		let baseline = spy.placements
		controller.setSize(300)
		#expect(spy.placements == baseline)
	}
}
