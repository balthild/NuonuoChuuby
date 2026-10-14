import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import NuonuoChuubyCore

/// Renders the pinch over a real idle frame and inspects the pixels.
@MainActor
@Suite("Cheek pinch renderer", .serialized)
struct CheekPinchRendererTests {
	private static var assetsRoot: URL? { TestAssets.root }

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
				data: &buffer,
				width: image.width,
				height: image.height,
				bitsPerComponent: 8,
				bytesPerRow: image.width * 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else { return buffer }
		context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		return buffer
	}

	private func settled(dx: Double, dy: Double) -> CheekPinchDynamics {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: dx, y: dy)
		for _ in 0..<300 { dynamics.tick(1.0 / 60) }
		return dynamics
	}

	private func verticallyFlipped(_ image: CGImage) -> CGImage? {
		guard
			let context = CGContext(
				data: nil,
				width: image.width,
				height: image.height,
				bitsPerComponent: 8,
				bytesPerRow: 0,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else { return nil }
		context.translateBy(x: 0, y: CGFloat(image.height))
		context.scaleBy(x: 1, y: -1)
		context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		return context.makeImage()
	}

	private func differing(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
		zip(lhs, rhs).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
	}

	@Test("An inactive pinch returns the frame untouched")
	func inactiveReturnsBase() throws {
		let base = try idleFrame()
		let geometry = CheekPinchGeometry.geometry(for: .nuonuo)
		let rendered = CheekPinchRenderer.render(
			base: base,
			geometry: geometry,
			dynamics: CheekPinchDynamics()
		)
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
			CheekPinchRenderer.render(base: base, geometry: geometry, dynamics: dynamics)
		)

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

	@Test("The base frame keeps its orientation under a pinch")
	func baseKeepsItsOrientation() throws {
		let base = try idleFrame()
		let geometry = CheekPinchGeometry.geometry(for: .nuonuo)

		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: 40, y: 0)
		for _ in 0..<90 { dynamics.tick(1.0 / 60) }
		#expect(dynamics.isActive)

		let rendered = try #require(
			CheekPinchRenderer.render(base: base, geometry: geometry, dynamics: dynamics)
		)
		let flippedBase = try #require(verticallyFlipped(base))

		let fromUpright = differing(pixels(of: base), pixels(of: rendered))
		let fromFlipped = differing(pixels(of: flippedBase), pixels(of: rendered))
		#expect(
			fromUpright * 4 < fromFlipped,
			"the repainted frame should resemble the upright base, not its mirror"
		)
	}

	@Test("The pinched mouth is the rig's size, not the cel artwork's")
	func mouthMatchesTheRig() throws {
		let base = try idleFrame()
		let geometry = CheekPinchGeometry.geometry(for: .nuonuo)

		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: CheekPinchDynamics.maximumHorizontal, y: 0)
		for _ in 0..<200 { dynamics.tick(1.0 / 60) }
		#expect(dynamics.tension > 0.99)

		let rendered = try #require(
			CheekPinchRenderer.render(base: base, geometry: geometry, dynamics: dynamics)
		)

		// The mouth fill is dark and warm; the pink tongue is too light to match
		// and the skin backing is neither. Restricting to pixels the render
		// actually changed keeps the cel's own dark collar and hair out.
		let buffer = pixels(of: rendered)
		let before = pixels(of: base)
		let scale = SpriteGeometry.canvasToRuntime
		let anchorX = Int((geometry.mouthX * scale).rounded())
		let anchorY = Int((geometry.mouthY * scale).rounded())

		var minX = Int.max
		var maxX = Int.min
		var minY = Int.max
		var maxY = Int.min
		for y in (anchorY - 25)...(anchorY + 25) {
			for x in (anchorX - 25)...(anchorX + 25) {
				guard x >= 0, y >= 0, x < rendered.width, y < rendered.height else { continue }
				let index = (y * rendered.width + x) * 4
				guard
					buffer[index] != before[index] || buffer[index + 1] != before[index + 1]
						|| buffer[index + 2] != before[index + 2]
				else { continue }
				let red = Int(buffer[index])
				let green = Int(buffer[index + 1])
				guard red - green > 30, red < 170 else { continue }
				minX = min(minX, x)
				maxX = max(maxX, x)
				minY = min(minY, y)
				maxY = max(maxY, y)
			}
		}
		#expect(minX <= maxX, "the mouth should be drawn")

		// The upstream rig: radiusX = 4.5 + 2·tension, radiusY = 2.5 + 2.4·tension + 3.5·nibble.
		let expectedWidth = 2 * (4.5 + 2 * dynamics.tension)
		let expectedHeight = 2 * (2.5 + 2.4 * dynamics.tension + 3.5 * dynamics.nibble)
		#expect(abs(Double(maxX - minX + 1) - expectedWidth) <= 2)
		#expect(abs(Double(maxY - minY + 1) - expectedHeight) <= 2)
	}

	@Test("An inward pull has no visible effect")
	func inwardPullDrawsNothing() throws {
		let base = try idleFrame()
		let geometry = CheekPinchGeometry.geometry(for: .nuonuo)

		let inward = settled(dx: -CheekPinchDynamics.maximumHorizontal, dy: 0)
		#expect(inward.x < -100, "the drag should really be pulling inwards")
		#expect(inward.tension == 0)

		let rendered = try #require(
			CheekPinchRenderer.render(base: base, geometry: geometry, dynamics: inward)
		)
		#expect(pixels(of: rendered) == pixels(of: base))
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
