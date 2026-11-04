import Foundation
import Testing

@testable import PetBehaviour

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

	private func write(_ json: String, into directory: URL, as store: PetLifeStateStore) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data(json.utf8).write(to: store.statePath)
	}

	/// A build that adds a field must not cost the save it is reading: without `@Fallback`
	/// the missing key throws, `load()` falls back to a fresh state, and every meal she has
	/// eaten is forgotten.
	@Test("A file written before a field existed keeps the rest of the state")
	func fileWithoutEveryKey() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-tests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = PetLifeStateStore(stateDirectory: directory)
		try write(
			#"{"hunger":80,"totalMeals":7,"foodTypeCounts":{"png":7}}"#,
			into: directory,
			as: store
		)

		let state = store.load()
		#expect(state.hunger == 80)
		#expect(state.totalMeals == 7)
		#expect(state.foodTypeCounts == ["png": 7])
		// The fields the file did not carry take their defaults.
		#expect(state.fullness == 24)
		#expect(state.favoriteFoodType.isEmpty)
	}

	/// An undated file is read as dated *now*, not as a long absence — otherwise a missing
	/// timestamp would drain every need by the twelve hours `advance` clamps to.
	@Test("A file with no timestamp is not read as an absence")
	func missingTimestampIsNotAnAbsence() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-tests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = PetLifeStateStore(stateDirectory: directory)
		try write(#"{"hunger":50,"fullness":50}"#, into: directory, as: store)

		let state = store.load()
		#expect(state.hunger == 50)
		#expect(state.fullness == 50)
	}

	@Test("An unreadable value costs only its own field")
	func unreadableValue() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-tests-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }

		let store = PetLifeStateStore(stateDirectory: directory)
		try write(
			#"{"hunger":"lots","totalMeals":7,"foodTypeCounts":"png"}"#,
			into: directory,
			as: store
		)

		let state = store.load()
		#expect(state.hunger == 36)
		#expect(state.totalMeals == 7)
		#expect(state.foodTypeCounts.isEmpty)
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

	@Test("High fullness, not hunger, makes resting more likely")
	func fullnessRaisesRest() {
		let restOrWander: Set<AutonomousAction> = [.rest, .wander]
		var hungryButEmpty = PetLifeState()
		hungryButEmpty.fullness = 10
		hungryButEmpty.curiosity = 0
		hungryButEmpty.hunger = 100
		var fullButRavenous = PetLifeState()
		fullButRavenous.fullness = 100
		fullButRavenous.curiosity = 0
		fullButRavenous.hunger = 100

		#expect(
			AutonomousBehaviorPlanner.choose(
				life: hungryButEmpty,
				hasGroundSupport: true,
				availableActions: restOrWander,
				randomUnit: 0.75
			) == .wander
		)
		#expect(
			AutonomousBehaviorPlanner.choose(
				life: fullButRavenous,
				hasGroundSupport: true,
				availableActions: restOrWander,
				randomUnit: 0.75
			) == .rest
		)
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

@Suite("Life behaviour policy")
struct LifeBehaviorPolicyTests {
	@Test("Being full follows fullness, not hunger")
	func comfortablyFull() {
		var state = PetLifeState()
		state.fullness = LifeBehaviorPolicy.comfortablyFullThreshold - 1
		state.hunger = 100
		#expect(!LifeBehaviorPolicy.isComfortablyFull(state))

		state.fullness = LifeBehaviorPolicy.comfortablyFullThreshold
		state.hunger = 0
		#expect(LifeBehaviorPolicy.isComfortablyFull(state))
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
