import Foundation
import Testing

@testable import NuonuoChuubyCore

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

@Suite("Subpixel motion")
struct SubpixelMotionTests {
	@Test("Fractional movement accumulates until it crosses a pixel")
	func carriesRemainder() {
		var remainder = 0.0
		#expect(SubpixelMotion.takeWholePixels(0.4, remainder: &remainder) == 0)
		#expect(SubpixelMotion.takeWholePixels(0.4, remainder: &remainder) == 0)
		#expect(SubpixelMotion.takeWholePixels(0.4, remainder: &remainder) == 1)
		#expect(abs(remainder - 0.2) < 0.0001)
	}

	@Test("Negative movement truncates toward zero")
	func negativeMovement() {
		var remainder = 0.0
		#expect(SubpixelMotion.takeWholePixels(-2.7, remainder: &remainder) == -2)
		#expect(abs(remainder + 0.7) < 0.0001)
	}
}

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

@Suite("Pet size policy")
struct PetSizePolicyTests {
	@Test("Percent converts both ways")
	func percentRoundTrip() {
		#expect(PetSizePolicy.fromPercent(100) == 220)
		#expect(PetSizePolicy.toPercent(220) == 100)
		#expect(PetSizePolicy.toPercent(1_000) == 200)
		#expect(PetSizePolicy.toPercent(0) == 60)
	}

	@Test("A non-finite size falls back to the default")
	func nonFinite() {
		#expect(PetSizePolicy.clampPreferredSize(.nan) == 220)
		#expect(PetSizePolicy.clampPreferredSize(.infinity) == 220)
	}

	@Test("A tiny work area shrinks the pet but never below the minimum")
	func fitToWorkArea() {
		#expect(
			PetSizePolicy.fitToWorkArea(
				preferredSize: 220,
				workAreaWidth: 400,
				workAreaHeight: 300,
				displayScale: 1
			) == 220
		)
		#expect(
			PetSizePolicy.fitToWorkArea(
				preferredSize: 220,
				workAreaWidth: 100,
				workAreaHeight: 100,
				displayScale: 1
			) == 96
		)
	}
}

@Suite("Life state")
struct PetLifeStateTests {
	@Test("Awake needs drift at the authored per-minute rates")
	func awakeRates() {
		var state = PetLifeState()
		let hunger = state.hunger
		let sleepiness = state.sleepiness
		state.advance(elapsedSeconds: 60, sleeping: false)
		#expect(abs(state.hunger - (hunger + 0.18)) < 0.0001)
		#expect(abs(state.sleepiness - (sleepiness + 0.13)) < 0.0001)
	}

	@Test("Sleep drains sleepiness at 36 per minute")
	func sleepingRates() {
		var state = PetLifeState()
		state.sleepiness = 100
		state.advance(elapsedSeconds: 60, sleeping: true)
		#expect(abs(state.sleepiness - 64) < 0.0001)
	}

	@Test("Needs are clamped to 0…100")
	func clamps() {
		var state = PetLifeState()
		// Twelve hours is the longest catch-up window; hunger saturates well before.
		state.advance(elapsedSeconds: 12 * 60 * 60, sleeping: false)
		#expect(state.hunger == 100)
		#expect(state.sleepiness == 100)
		#expect(state.fullness == 0)
	}

	@Test("A meal lowers hunger and raises fullness")
	func meal() {
		var state = PetLifeState()
		let hunger = state.hunger
		let fullness = state.fullness
		state.registerMeal(path: "/tmp/cake.png", nourishment: 10)
		#expect(state.hunger < hunger)
		#expect(state.fullness > fullness)
		#expect(state.totalMeals == 1)
		#expect(state.favoriteFoodType == "png")
	}

	@Test("Food type prefers the snack label and falls back to folder")
	func foodTypes() {
		#expect(PetLifeState.foodType(forPath: "/tmp/treat.snack") == "点心")
		#expect(PetLifeState.foodType(forPath: "/tmp/notes") == "文件夹")
	}
}

@Suite("Life state store")
struct PetLifeStateStoreTests {
	@Test("A missing file yields defaults")
	func missingFile() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-tests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = PetLifeStateStore(stateDirectory: directory)
		let state = store.load()
		#expect(state.hunger == 36)
		#expect(state.totalMeals == 0)
	}

	@Test("State survives a round trip")
	func roundTrip() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-tests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = PetLifeStateStore(stateDirectory: directory)
		var state = PetLifeState()
		state.registerMeal(path: "/tmp/cake.png", nourishment: 8)
		try store.save(state)

		let reloaded = store.load()
		#expect(reloaded.totalMeals == 1)
		#expect(reloaded.favoriteFoodType == "png")
	}
}

@Suite("Autonomous behaviour planner")
struct AutonomousBehaviorPlannerTests {
	private func allActions() -> Set<AutonomousAction> { Set(AutonomousAction.allCases) }

	@Test("Only available actions are ever chosen")
	func respectsAvailability() {
		var life = PetLifeState()
		life.fullness = 100
		for unit in stride(from: 0.0, to: 1.0, by: 0.01) {
			let action = AutonomousBehaviorPlanner.choose(
				life: life,
				hasGroundSupport: true,
				availableActions: [.rest],
				randomUnit: unit
			)
			#expect(action == .rest)
		}
	}

	@Test("High sleepiness makes a nap likely")
	func sleepinessRaisesNap() {
		var life = PetLifeState()
		life.sleepiness = 95
		life.hunger = 0
		var naps = 0
		let samples = 2000
		for index in 0..<samples {
			let unit = Double(index) / Double(samples)
			if AutonomousBehaviorPlanner.choose(
				life: life,
				hasGroundSupport: true,
				availableActions: allActions(),
				randomUnit: unit
			) == .sleep {
				naps += 1
			}
		}
		#expect(naps > samples / 4)
	}

	@Test("A pet with no ground support never wanders")
	func noGroundSupport() {
		for index in 0..<200 {
			let unit = Double(index) / 200
			let action = AutonomousBehaviorPlanner.choose(
				life: PetLifeState(),
				hasGroundSupport: false,
				availableActions: allActions(),
				randomUnit: unit
			)
			#expect(action != .wander)
			#expect(action != .explore)
			#expect(action != .hop)
		}
	}
}

@Suite("Mode policy")
struct PetModePolicyTests {
	@Test("Quiet mode leaves only rest and sleep")
	func quietMode() {
		#expect(PetModePolicy.allowsAutonomousAction(.rest, fastingMode: false, quietMode: true))
		#expect(PetModePolicy.allowsAutonomousAction(.sleep, fastingMode: false, quietMode: true))
		#expect(!PetModePolicy.allowsAutonomousAction(.wander, fastingMode: false, quietMode: true))
	}

	@Test("Fasting mode removes only the food actions")
	func fastingMode() {
		#expect(!PetModePolicy.allowsAutonomousAction(.askForFood, fastingMode: true, quietMode: false))
		#expect(!PetModePolicy.allowsAutonomousAction(.lickIcon, fastingMode: true, quietMode: false))
		#expect(PetModePolicy.allowsAutonomousAction(.wander, fastingMode: true, quietMode: false))
		#expect(PetModePolicy.resolveHunger(80, fastingMode: true) == 0)
	}

	@Test("The hunger bar hides under fasting or infinite mode")
	func progressDisplay() {
		#expect(
			!PetModePolicy.shouldShowProgressDisplay(
				character: .nuonuo,
				fastingMode: false,
				infiniteMode: true,
				coexistenceMode: false
			)
		)
		#expect(
			!PetModePolicy.shouldShowProgressDisplay(
				character: .nuonuo,
				fastingMode: true,
				infiniteMode: false,
				coexistenceMode: false
			)
		)
		#expect(
			PetModePolicy.shouldShowProgressDisplay(
				character: .nuonuo,
				fastingMode: false,
				infiniteMode: false,
				coexistenceMode: false
			)
		)
	}
}

@Suite("Character profile")
struct PetCharacterProfileTests {
	@Test("An unknown id falls back to 糯糯")
	func fallback() {
		#expect(PetCharacterProfile.resolve(id: "nope").id == "nuonuo")
		#expect(PetCharacterProfile.resolve(id: nil).id == "nuonuo")
		#expect(PetCharacterProfile.resolve(id: "FEIBIJIUBI").id == "feibijiubi")
	}

	@Test("Character flags follow the id")
	func flags() {
		#expect(PetCharacterProfile.nuonuo.supportsFood)
		#expect(!PetCharacterProfile.nuonuo.usesMischief)
		#expect(PetCharacterProfile.feibiJiubi.usesMischief)
		#expect(!PetCharacterProfile.feibiJiubi.supportsFood)
	}
}

@Suite("Sprite animator")
@MainActor
struct SpriteAnimatorTests {
	@Test("糯糯 needs every food clip but 菲比 needs none of them")
	func requiredFolders() {
		let nuonuo = SpriteAnimator.requiredAssetFolders(for: .nuonuo)
		#expect(nuonuo.contains("hungry"))
		#expect(nuonuo.contains("lick"))
		#expect(nuonuo.contains("chomp"))
		#expect(nuonuo.contains("satisfied"))
		#expect(!nuonuo.contains("pair_icon_kick"))

		let feibi = SpriteAnimator.requiredAssetFolders(for: .feibiJiubi)
		#expect(!feibi.contains("hungry"))
		#expect(!feibi.contains("chomp"))
	}

	@Test("Clip folders are de-duplicated")
	func uniqueFolders() {
		let folders = SpriteAnimator.requiredAssetFolders(for: .nuonuo)
		#expect(Set(folders).count == folders.count)
	}
}
