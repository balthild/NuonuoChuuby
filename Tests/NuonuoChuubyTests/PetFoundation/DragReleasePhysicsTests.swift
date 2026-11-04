import Testing

@testable import PetFoundation

@Suite("Drag release physics")
struct DragReleasePhysicsTests {
	private func tracker(
		fromX: Double,
		toX: Double,
		seconds: Double,
		steps: Int = 8
	) -> DragMotionTracker {
		var tracker = DragMotionTracker()
		tracker.reset(point: PixelPoint(x: fromX, y: 0), atSeconds: 0)
		for step in 1...steps {
			let progress = Double(step) / Double(steps)
			tracker.add(
				point: PixelPoint(x: fromX + (toX - fromX) * progress, y: 0),
				atSeconds: seconds * progress
			)
		}
		return tracker
	}

	@Test("A slow release produces no inertia")
	func slowRelease() {
		var tracker = tracker(fromX: 0, toX: 3, seconds: 0.2)
		let motion = tracker.release(point: PixelPoint(x: 3, y: 0), atSeconds: 0.2, scale: 1)
		#expect(!motion.hasInertia)
		#expect(motion.velocityX == 0)
	}

	@Test("A fast flick transfers velocity in the flick direction")
	func fastFlick() {
		var tracker = tracker(fromX: 0, toX: 400, seconds: 0.2)
		let motion = tracker.release(point: PixelPoint(x: 400, y: 0), atSeconds: 0.2, scale: 1)
		#expect(motion.hasInertia)
		#expect(motion.velocityX > 0)
		// The transfer factor is capped at 0.82.
		#expect(motion.velocityX <= 2000 * 0.82 + 0.001)
	}

	@Test("A stale gesture is abandoned")
	func staleGesture() {
		var tracker = tracker(fromX: 0, toX: 400, seconds: 0.1)
		let motion = tracker.release(point: PixelPoint(x: 400, y: 0), atSeconds: 0.9, scale: 1)
		#expect(!motion.hasInertia)
	}
}
