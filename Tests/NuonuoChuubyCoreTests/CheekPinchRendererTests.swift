import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import NuonuoChuubyCore

/// Renders the pinch over a real idle frame and inspects the pixels.
@MainActor
@Suite("Cheek pinch renderer", .serialized)
struct CheekPinchRendererTests {
	private static var assetsRoot: URL? {
		let repoRoot = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let root = repoRoot.appendingPathComponent("Sources/NuonuoChuubyCore/Resources/Assets")
		return FileManager.default.fileExists(atPath: root.path) ? root : nil
	}

	private func idleFrame() throws -> CGImage {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let url = root.appendingPathComponent("sprites/runtime/idle/frame_00.png")
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else { throw TestSkip.missingAssets }
		return image
	}

	enum TestSkip: Error { case missingAssets }

	private func pixels(of image: CGImage) -> [UInt8] {
		var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
		guard
			let context = CGContext(
				data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
				bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return buffer }
		context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		return buffer
	}

	@Test("An inactive pinch returns the frame untouched")
	func inactiveReturnsBase() throws {
		let base = try idleFrame()
		let geometry = CheekPinchGeometry.geometry(for: .nuonuo)
		let rendered = CheekPinchRenderer.render(
			base: base, geometry: geometry, dynamics: CheekPinchDynamics())
		#expect(rendered === base)
	}

	@Test("A pulled cheek visibly changes the frame")
	func pulledCheekChangesPixels() throws {
		let base = try idleFrame()
		let geometry = CheekPinchGeometry.geometry(for: .nuonuo)

		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: CheekPinchDynamics.maximumHorizontal, y: 0)
		for _ in 0..<120 { dynamics.tick(1.0 / 60) }
		#expect(dynamics.isActive)

		let rendered = try #require(
			CheekPinchRenderer.render(base: base, geometry: geometry, dynamics: dynamics))

		let before = pixels(of: base)
		let after = pixels(of: rendered)
		#expect(before.count == after.count)

		let differing = zip(before, after).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
		#expect(differing > 500, "the pinch should repaint a visible area")

		// The change has to be on the pinched side, not scattered anywhere.
		let scale = SpriteGeometry.canvasToRuntime
		let cheekX = Int((geometry.x(for: .right) + dynamics.x) * scale)
		let centreRow = Int(geometry.cheekY * scale)
		var changedNearCheek = 0
		for y in (centreRow - 30)...(centreRow + 30) {
			for x in (cheekX - 30)...(cheekX + 30) {
				guard x >= 0, y >= 0, x < rendered.width, y < rendered.height else { continue }
				let index = (y * rendered.width + x) * 4
				if index + 3 < before.count, before[index] != after[index] {
					changedNearCheek += 1
				}
			}
		}
		#expect(changedNearCheek > 100, "the repainted area should be around the pulled cheek")
	}

	@Test("The base frame is not modified in place")
	func doesNotMutateBase() throws {
		let base = try idleFrame()
		let geometry = CheekPinchGeometry.geometry(for: .nuonuo)
		let before = pixels(of: base)

		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .left)
		dynamics.drag(x: -90, y: 10)
		for _ in 0..<60 { dynamics.tick(1.0 / 60) }
		_ = CheekPinchRenderer.render(base: base, geometry: geometry, dynamics: dynamics)

		let after = pixels(of: base)
		#expect(before == after)
	}
}
