import Testing

@testable import PetFoundation

@Suite("Airborne boundary")
struct AirborneBoundaryPolicyTests {
	@Test("A foot inside the monitor is untouched")
	func insideMonitor() {
		let result = AirborneBoundaryPolicy.resolveHorizontal(
			proposedFootX: 500,
			velocityX: 40,
			monitorLeft: 0,
			monitorRight: 1000,
			margin: 8
		)
		#expect(!result.corrected)
		#expect(result.velocityX == 40)
	}

	@Test("Crossing the left edge reflects with retention")
	func leftEdge() {
		let result = AirborneBoundaryPolicy.resolveHorizontal(
			proposedFootX: -20,
			velocityX: -300,
			monitorLeft: 0,
			monitorRight: 1000,
			margin: 8
		)
		#expect(result.corrected)
		#expect(abs(result.nextFootX - 8) < 0.001)
		#expect(abs(result.velocityX - 138) < 0.001)
	}

	@Test("Crossing the right edge reflects with retention")
	func rightEdge() {
		let result = AirborneBoundaryPolicy.resolveHorizontal(
			proposedFootX: 1200,
			velocityX: 300,
			monitorLeft: 0,
			monitorRight: 1000,
			margin: 8
		)
		#expect(result.corrected)
		#expect(abs(result.nextFootX - 991) < 0.001)
		#expect(abs(result.velocityX + 138) < 0.001)
	}
}
