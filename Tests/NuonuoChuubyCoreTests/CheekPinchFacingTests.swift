import Foundation
import ImageIO
import Testing

@testable import NuonuoChuubyCore

/// The cheek rig is authored in the sprite's own space, but she is drawn mirrored
/// when she faces left. A pinch taken from the pointer therefore has to be mirrored
/// back, or the wrong cheek is pulled and the effect lands on the wrong side.
@MainActor
@Suite("Cheek pinch facing", .serialized)
struct CheekPinchFacingTests {
	enum TestSkip: Error { case missingAssets }

	private func makeController() throws -> (PetController, URL) {
		guard let root = TestAssets.root else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-cheek-\(UUID().uuidString)")
		let space = DisplaySpace()
		let surfaces = SurfaceProvider()
		surfaces.refresh(displaySpace: space)
		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: surfaces,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space,
			profile: .nuonuo,
			petSize: PetSizePolicy.defaultSize,
			randomSeed: TestAssets.randomSeed
		)
		return (controller, directory)
	}

	@Test("Facing right, the pointer is taken as authored")
	func facingRight() throws {
		let (controller, directory) = try makeController()
		defer { try? FileManager.default.removeItem(at: directory) }

		let geometry = controller.cheekGeometryInView
		#expect(controller.facing > 0)
		#expect(
			controller.cheekHitTest(viewPoint: CGPoint(x: geometry.rightX, y: geometry.cheekY)) == .right
		)
		#expect(
			controller.cheekHitTest(viewPoint: CGPoint(x: geometry.leftX, y: geometry.cheekY)) == .left
		)
	}

	@Test("Facing left, the pointer is mirrored onto the authored cheek")
	func facingLeft() throws {
		let (controller, directory) = try makeController()
		defer { try? FileManager.default.removeItem(at: directory) }

		let size = CGFloat(controller.petSize)
		let geometry = controller.cheekGeometryInView
		controller.debugSetFacing(-1)

		// The authored right cheek is drawn on the left of the square, so that is
		// where the pointer has to be to pull it.
		#expect(
			controller.cheekHitTest(
				viewPoint: CGPoint(x: size - CGFloat(geometry.rightX), y: geometry.cheekY)
			) == .right
		)
		#expect(
			controller.cheekHitTest(
				viewPoint: CGPoint(x: size - CGFloat(geometry.leftX), y: geometry.cheekY)
			) == .left
		)
	}

	@Test("A drag follows the cursor whichever way she faces")
	func dragFollowsTheCursor() throws {
		let (controller, directory) = try makeController()
		defer { try? FileManager.default.removeItem(at: directory) }

		let size = CGFloat(controller.petSize)
		let geometry = controller.cheekGeometryInView
		controller.debugSetFacing(-1)

		// Pull the cheek that is drawn on the right-hand side of the square, which
		// under the mirror is the authored left one.
		let start = CGPoint(x: size - CGFloat(geometry.leftX), y: geometry.cheekY)
		let side = try #require(controller.cheekHitTest(viewPoint: start))
		#expect(side == .left)
		controller.beginPinch(side: side, at: start)
		#expect(controller.isPinching)

		// Dragging the cursor to the right must pull the patch to the right, which
		// in the authored space is a negative offset.
		controller.updatePinch(to: CGPoint(x: start.x + 40, y: start.y))
		for _ in 0..<60 { controller.debugStep(delta: 1.0 / 60) }

		let offset = controller.debugCheekOffset
		#expect(offset.x < -20, "pulling right should read as a negative authored offset")
	}
}
