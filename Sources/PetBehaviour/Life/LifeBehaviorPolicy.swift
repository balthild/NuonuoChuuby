import Foundation

public enum LifeBehaviorPolicy {
	public static let maximumIdleSeconds: Double = 5
	public static let minimumNapSeconds: Double = 7.5
	public static let patrolNeedCheckSeconds: Double = 5
	public static let hungerReactionCooldownSeconds: Double = 45
	public static let sleepInterruptionThreshold: Double = 62
	public static let lickInterruptionThreshold: Double = 62
	public static let rollInterruptionThreshold: Double = 65
	public static let foodAppealInterruptionThreshold: Double = 70
	/// Where she counts as peckish and as ravenous. Both sit below the weights the
	/// planner gives her food actions, so by the time she remarks on it she is
	/// already acting on it.
	public static let aBitHungryHungerThreshold: Double = 48
	public static let veryHungryHungerThreshold: Double = 72
	/// Fullness at which she counts as full — roughly four meals' worth. Unlike
	/// hunger, fullness only rises by eating, so this is reachable only after a
	/// run of meals.
	public static let comfortablyFullThreshold: Double = 60

	/// Being full is a matter of fullness alone: hunger is the drive to seek
	/// food, so a ravenous pet may still be full.
	public static func isComfortablyFull(_ life: PetLifeState) -> Bool {
		life.fullness >= comfortablyFullThreshold
	}

	public static func isHungerReaction(_ action: AutonomousAction) -> Bool {
		switch action {
		case .askForFood, .lickIcon, .roll: return true
		default: return false
		}
	}

	public static func isHungerReactionReady(
		_ action: AutonomousAction,
		now: Double,
		nextHungerReactionAt: Double
	) -> Bool {
		!isHungerReaction(action) || now >= nextHungerReactionAt
	}
}
