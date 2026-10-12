import Foundation

public enum AutonomousAction: String, Sendable, CaseIterable {
	case rest
	case wander
	case explore
	case sleep
	case askForFood
	case lickIcon
	case roll
	case hop
}

public enum AutonomousBehaviorPlanner {
	/// One weighted draw over the actions currently available to the pet.
	public static func choose(
		life: PetLifeState,
		hasGroundSupport: Bool,
		availableActions: Set<AutonomousAction>,
		randomUnit: Double,
		profile: PetCharacterProfile = .nuonuo
	) -> AutonomousAction {
		let isFeibi = profile.id == PetCharacterProfile.feibiJiubi.id
		let supportsFood = profile.supportsFood
		let energy = min(max((75 - life.sleepiness) / 35, 0), 1)
		let tiredMovementScale = isFeibi ? 1 - min(max((life.sleepiness - 75) / 25, 0), 1) * 0.45 : 1

		var choices: [(action: AutonomousAction, weight: Double)] = []

		func add(_ action: AutonomousAction, _ weight: Double) {
			guard weight > 0, availableActions.contains(action) else { return }
			choices.append((action, weight))
		}

		add(.rest, 2.2 + (supportsFood ? max(0, life.fullness - 68) / 24 : 0))

		if hasGroundSupport {
			add(
				.wander,
				(1.1 + life.curiosity / 85) * (isFeibi ? 1 + 0.12 * energy : 1) * tiredMovementScale)
			add(
				.explore,
				(0.25 + max(0, life.curiosity - 30) / 13)
					* (isFeibi ? 1 + 0.45 * energy : 1) * tiredMovementScale)
		}

		// A short nap is also an ordinary idle variation; sleepiness raises its
		// probability, but even a rested pet can occasionally choose it.
		add(.sleep, 0.75 + max(0, life.sleepiness - 43) / 9)

		if supportsFood {
			add(.askForFood, max(0, life.hunger - 48) / 10)
			add(.lickIcon, 0.16 + max(0, life.hunger - 35) / 24)
			add(.roll, max(0, life.hunger - 58) / 10)
		}

		if hasGroundSupport {
			add(.hop, (0.24 + life.curiosity / 180) * (isFeibi ? 1 + 0.75 * energy : 1) * tiredMovementScale)
		}

		guard !choices.isEmpty else { return .rest }

		let total = choices.reduce(0) { $0 + $1.weight }
		var target = min(max(randomUnit, 0), 0.999999) * total
		for choice in choices {
			target -= choice.weight
			if target <= 0 { return choice.action }
		}
		return choices[choices.count - 1].action
	}
}
