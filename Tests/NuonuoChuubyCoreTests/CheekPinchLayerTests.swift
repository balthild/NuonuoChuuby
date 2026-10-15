import CoreGraphics
import QuartzCore
import Testing

@testable import NuonuoChuubyCore

/// The vector shapes the pinch overlay is built from, in the pet's own points.
///
/// They are checked against the rig: the cheek sits on the anchor, only moves
/// outwards, and the mouth group only appears past the tension it needs.
@Suite("Cheek pinch shapes")
struct CheekPinchShapesTests {
	/// `pointsPerPixel: 1` keeps every coordinate in the rig's own pixels.
	private func shapes(
		_ dynamics: CheekPinchDynamics,
		pointsPerPixel: Double = 1
	)
		-> CheekPinchShapes.Shapes
	{
		CheekPinchShapes.shapes(
			state: CheekPinchState(
				geometry: CheekPinchGeometry.geometry(for: .nuonuo),
				dynamics: dynamics
			),
			pointsPerPixel: pointsPerPixel
		)
	}

	private func settled(side: CheekSide = .right, dx: Double, dy: Double = 0) -> CheekPinchDynamics {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: side)
		dynamics.drag(x: dx, y: dy)
		for _ in 0..<300 { dynamics.tick(1.0 / 60) }
		return dynamics
	}

	@Test("A pinch that has built no tension draws nothing")
	func noTensionDrawsNothing() {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		#expect(shapes(dynamics).isEmpty)
	}

	/// A pull across the face is a negative outward offset, so it must not draw a
	/// cheek pinned to the other side of her head.
	@Test("Pulling inwards draws nothing either")
	func inwardPullDrawsNothing() {
		// The right cheek's outward direction is positive, so a leftward drag is the
		// one that builds no tension.
		let dynamics = settled(dx: -CheekPinchDynamics.maximumHorizontal)
		#expect(shapes(dynamics).isEmpty)
	}

	@Test("A pulled cheek draws a cheek and a blush")
	func pulledCheekDrawsCheekAndBlush() {
		let shapes = shapes(settled(dx: CheekPinchDynamics.maximumHorizontal))
		#expect(shapes.cheek != nil)
		#expect(shapes.blush != nil)
	}

	@Test("The cheek sits on the rig's anchor, in the pet's own points")
	func cheekSitsOnTheAnchor() {
		let geometry = CheekPinchGeometry.geometry(for: .nuonuo)
		let scale = SpriteGeometry.canvasToRuntime
		let pointsPerPixel = 0.5
		// A pull small enough to keep the mouth group out of the way.
		let dynamics = settled(dx: 8)
		let shapes = shapes(dynamics, pointsPerPixel: pointsPerPixel)
		let cheek = try! #require(shapes.cheek)
		let box = cheek.path.boundingBoxOfPath

		let expectedX = (geometry.rightX + dynamics.outwardOffset) * scale * pointsPerPixel
		let expectedY = (geometry.cheekY + dynamics.y) * scale * pointsPerPixel
		#expect(abs(box.midX - expectedX) < 0.5)
		#expect(abs(box.midY - expectedY) < 0.5)
	}

	@Test("The mouth group only appears once the pull is hard enough")
	func mouthAppearsPastItsThreshold() {
		// Outward 20 of 105 is a tension of about 0.19: cheek and blush, no mouth.
		let gentle = shapes(settled(dx: 20))
		#expect(gentle.cheek != nil)
		#expect(gentle.mouth == nil, "the mouth must not appear on a light pull")

		let hard = shapes(settled(dx: CheekPinchDynamics.maximumHorizontal))
		#expect(hard.mouthCover != nil)
		#expect(hard.mouth != nil)
		#expect(hard.tongue != nil)
	}

	@Test("A pull moves the cheek outwards, never across the face")
	func pullMovesTheCheekOutwards() {
		let rest = shapes(settled(dx: 8)).cheek!.path.boundingBoxOfPath.midX
		let pulled = shapes(settled(dx: CheekPinchDynamics.maximumHorizontal))
			.cheek!.path.boundingBoxOfPath.midX
		#expect(pulled > rest + 50, "the cheek should travel a long way out")
	}

	/// The mouth is the rig's own size, in the rig's own runtime-frame pixels, not
	/// scaled to the cel artwork's mouth.
	@Test("The pinched mouth is the rig's size")
	func mouthMatchesTheRig() {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: CheekPinchDynamics.maximumHorizontal, y: 0)
		for _ in 0..<300 { dynamics.tick(1.0 / 60) }
		#expect(dynamics.tension > 0.99)

		let box = shapes(dynamics).mouth!.path.boundingBoxOfPath
		// The upstream rig: radiusX = 4.5 + 2·tension, radiusY = 2.5 + 2.4·tension + 3.5·nibble.
		let expectedWidth = 2 * (4.5 + 2 * dynamics.tension)
		let expectedHeight = 2 * (2.5 + 2.4 * dynamics.tension + 3.5 * dynamics.nibble)
		#expect(abs(box.width - expectedWidth) < 0.5)
		#expect(abs(box.height - expectedHeight) < 0.5)
	}
}

/// Renders the overlay into a bitmap the way the pet's overlay window composites
/// it, and checks the cheek lands on her face.
///
/// The whole overlay rests on a coordinate system that the pet's layer tree
/// establishes (`isGeometryFlipped` at the root, the pet anchored at its bottom
/// centre). Getting the flip wrong mirrors the shapes onto the other end of her
/// body, which no geometry-only test can see.
@MainActor
@Suite("Cheek pinch layer", .serialized)
struct CheekPinchLayerTests {
	private static let petSize: Double = 132

	/// The pet's square, drawn the way `OverlayPetWindowController` builds it.
	private func buildRoot() -> (root: CALayer, pet: CALayer) {
		let root = CALayer()
		root.bounds = CGRect(x: 0, y: 0, width: Self.petSize, height: Self.petSize)
		root.isGeometryFlipped = true
		root.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

		let pet = CALayer()
		pet.bounds = CGRect(x: 0, y: 0, width: Self.petSize, height: Self.petSize)
		pet.anchorPoint = CGPoint(x: 0.5, y: 1)
		pet.position = CGPoint(x: Self.petSize / 2, y: Self.petSize)
		root.addSublayer(pet)
		return (root, pet)
	}

	private func render(_ layer: CALayer) -> [UInt8] {
		let width = Int(Self.petSize)
		let height = Int(Self.petSize)
		var buffer = [UInt8](repeating: 0, count: width * height * 4)
		guard
			let context = CGContext(
				data: &buffer,
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: width * 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else { return buffer }
		// So row 0 of the buffer is the top of the picture, which is how the eye
		// reads the layer tree.
		context.translateBy(x: 0, y: CGFloat(height))
		context.scaleBy(x: 1, y: -1)
		layer.render(in: context)
		return buffer
	}

	/// The centre of mass of the painted (non-white, opaque) pixels.
	private func paintedCentre(_ buffer: [UInt8]) -> (x: Double, y: Double, count: Int) {
		let width = Int(Self.petSize)
		var sumX = 0.0
		var sumY = 0.0
		var count = 0
		for y in 0..<Int(Self.petSize) {
			for x in 0..<width {
				let index = (y * width + x) * 4
				let r = buffer[index]
				let g = buffer[index + 1]
				let b = buffer[index + 2]
				let a = buffer[index + 3]
				guard a > 200, r < 250 || g < 250 || b < 250 else { continue }
				sumX += Double(x)
				sumY += Double(y)
				count += 1
			}
		}
		guard count > 0 else { return (0, 0, 0) }
		return (sumX / Double(count), sumY / Double(count), count)
	}

	@Test("A pulled right cheek is drawn on her face, on the right")
	func pulledCheekLandsOnTheFace() {
		let (root, pet) = buildRoot()
		let pinch = CheekPinchLayer()
		pet.addSublayer(pinch.container)
		pinch.setBounds(
			CGRect(x: 0, y: 0, width: Self.petSize, height: Self.petSize),
			contentsScale: 1
		)

		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: CheekPinchDynamics.maximumHorizontal, y: 0)
		for _ in 0..<120 { dynamics.tick(1.0 / 60) }
		pinch.update(
			state: CheekPinchState(
				geometry: CheekPinchGeometry.geometry(for: .nuonuo),
				dynamics: dynamics
			),
			base: nil
		)

		let centre = paintedCentre(render(root))
		#expect(centre.count > 100, "the overlay should paint a visible patch")
		#expect(centre.x > 80, "a right-side pull belongs on the right half")
		// The cheek is around 60% down her square. A vertically mirrored overlay
		// would land near 40% instead, which is what this pins.
		#expect(centre.y > 68 && centre.y < 92, "the cheek belongs on her face, not her feet")
	}

	@Test("Clearing hides every shape")
	func clearHidesTheOverlay() {
		let (root, pet) = buildRoot()
		let pinch = CheekPinchLayer()
		pet.addSublayer(pinch.container)
		pinch.setBounds(
			CGRect(x: 0, y: 0, width: Self.petSize, height: Self.petSize),
			contentsScale: 1
		)

		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: CheekPinchDynamics.maximumHorizontal, y: 0)
		for _ in 0..<120 { dynamics.tick(1.0 / 60) }
		pinch.update(
			state: CheekPinchState(
				geometry: CheekPinchGeometry.geometry(for: .nuonuo),
				dynamics: dynamics
			),
			base: nil
		)
		#expect(paintedCentre(render(root)).count > 100)

		pinch.clear()
		#expect(paintedCentre(render(root)).count == 0)
	}
}
