import Foundation
import Testing

@testable import NuonuoChuubyCore

@Suite("Cheek pinch geometry")
struct CheekPinchGeometryTests {
	private let geometry = CheekPinchGeometry.geometry(for: .nuonuo)

	@Test("A press on a cheek is recognised, and the nearer one wins")
	func hitTest() {
		#expect(geometry.hitTest(x: geometry.leftX, y: geometry.cheekY) == .left)
		#expect(geometry.hitTest(x: geometry.rightX, y: geometry.cheekY) == .right)
		// Just left of centre is nearer the left cheek.
		#expect(geometry.hitTest(x: geometry.leftX + 5, y: geometry.cheekY) == .left)
	}

	@Test("A press away from the cheeks is not a pinch")
	func misses() {
		#expect(geometry.hitTest(x: 256, y: 60) == nil)
		#expect(geometry.hitTest(x: 20, y: 400) == nil)
	}

	@Test("Non-finite input is rejected rather than trapping")
	func nonFinite() {
		#expect(geometry.hitTest(x: .nan, y: 0) == nil)
		#expect(geometry.hitTest(x: 0, y: .infinity) == nil)
	}

	@Test("Each character has its own cheek anchors")
	func perCharacter() {
		let feibi = CheekPinchGeometry.geometry(for: .feibiJiubi)
		#expect(feibi.leftX != geometry.leftX)
		#expect(feibi.mouthX != geometry.mouthX)
	}

	@Test("The anchors land where the rig was authored, in sprite pixels")
	func spritePixelAnchors() {
		// The upstream rig is authored against the 384 px sprite, so converting the
		// canvas anchors back down has to reproduce its numbers.
		let toSpritePixels = SpriteGeometry.canvasToRuntime
		#expect(abs(geometry.leftX * toSpritePixels - 122) < 0.001)
		#expect(abs(geometry.rightX * toSpritePixels - 239) < 0.001)
		#expect(abs(geometry.cheekY * toSpritePixels - 232) < 0.001)
		#expect(abs(geometry.hitRadiusX * toSpritePixels - 25) < 0.001)
		#expect(abs(geometry.hitRadiusY * toSpritePixels - 18) < 0.001)
		#expect(abs(geometry.mouthX * toSpritePixels - 178) < 0.001)
		#expect(abs(geometry.mouthY * toSpritePixels - 227) < 0.001)
	}
}

@Suite("Cheek pinch dynamics")
struct CheekPinchDynamicsTests {
	@Test("A pinch starts at rest and follows the drag")
	func followsDrag() {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		#expect(dynamics.isActive)
		#expect(dynamics.isHeld)

		dynamics.drag(x: 60, y: 10)
		// The spring needs time to travel to the new target.
		for _ in 0..<60 { dynamics.tick(1.0 / 60) }
		#expect(dynamics.x > 50)
		#expect(dynamics.x <= CheekPinchDynamics.maximumHorizontal)
	}

	@Test("The pull is clamped to the maximum stretch")
	func clamped() {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: 10_000, y: 10_000)
		for _ in 0..<200 { dynamics.tick(1.0 / 60) }
		#expect(dynamics.x <= CheekPinchDynamics.maximumHorizontal + 0.001)
		#expect(dynamics.y <= CheekPinchDynamics.maximumVertical + 0.001)
		#expect(dynamics.outwardTension <= 1)
		#expect(dynamics.tension <= 1)
	}

	@Test("Releasing snaps the cheek back and then rests")
	func snapsBack() {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .left)
		dynamics.drag(x: -80, y: 0)
		for _ in 0..<60 { dynamics.tick(1.0 / 60) }
		#expect(dynamics.x < -20)

		dynamics.release()
		for _ in 0..<240 { dynamics.tick(1.0 / 60) }
		#expect(!dynamics.isActive)
		#expect(dynamics.x == 0)
	}

	@Test("A hard pull produces the nibble wobble")
	func nibble() {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: CheekPinchDynamics.maximumHorizontal, y: 0)
		var sawNibble = false
		for _ in 0..<120 {
			dynamics.tick(1.0 / 60)
			if dynamics.nibble > 0.05 { sawNibble = true }
		}
		#expect(sawNibble)
	}

	@Test("A large time step stays stable, because it is substepped")
	func stableUnderBigStep() {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: 100, y: 40)
		for _ in 0..<40 { dynamics.tick(0.05) }
		#expect(dynamics.x.isFinite)
		#expect(dynamics.y.isFinite)
		#expect(dynamics.x <= CheekPinchDynamics.maximumHorizontal + 0.001)
	}

	@Test("Dragging without a pinch does nothing")
	func dragWithoutBegin() {
		var dynamics = CheekPinchDynamics()
		dynamics.drag(x: 50, y: 50)
		dynamics.tick(1.0 / 60)
		#expect(!dynamics.isActive)
		#expect(dynamics.x == 0)
	}

	@Test("An inward drag builds no tension")
	func inwardDragHasNoTension() {
		var dynamics = CheekPinchDynamics()
		dynamics.begin(side: .right)
		dynamics.drag(x: -CheekPinchDynamics.maximumHorizontal, y: 0)
		for _ in 0..<200 { dynamics.tick(1.0 / 60) }
		#expect(dynamics.x < -100)
		#expect(dynamics.tension == 0)

		// The same distance outwards still builds the full stretch.
		var outward = CheekPinchDynamics()
		outward.begin(side: .right)
		outward.drag(x: CheekPinchDynamics.maximumHorizontal, y: 0)
		for _ in 0..<200 { outward.tick(1.0 / 60) }
		#expect(outward.tension > 0.99)

		// A vertical drag is unaffected by which way the horizontal went.
		var vertical = CheekPinchDynamics()
		vertical.begin(side: .left)
		vertical.drag(x: CheekPinchDynamics.maximumHorizontal, y: CheekPinchDynamics.maximumVertical)
		for _ in 0..<200 { vertical.tick(1.0 / 60) }
		#expect(vertical.tension > 0.99)
	}
}
