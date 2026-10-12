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
