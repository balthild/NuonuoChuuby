import Testing

@testable import PetFoundation

@Suite("Sprite geometry")
struct SpriteGeometryTests {
	@Test("The foot anchor sits on the authored baseline")
	func footAnchor() {
		#expect(abs(SpriteGeometry.footCanvasX - 256) < 0.001)
		#expect(abs(SpriteGeometry.footCanvasY - 498.6666) < 0.001)
	}

	@Test("Animation steps are clamped but simulation is not")
	func frameTiming() {
		let timing = FrameTiming.fromElapsed(0.5)
		#expect(timing.simulationSeconds == 0.5)
		#expect(timing.animationSeconds == 0.05)

		let negative = FrameTiming.fromElapsed(-1)
		#expect(negative.simulationSeconds == 0)
		#expect(negative.animationSeconds == 0)
	}
}
