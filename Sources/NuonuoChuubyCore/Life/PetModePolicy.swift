import Foundation

public enum PetModePolicy {
	public static func resolveHunger(_ hunger: Double, fastingMode: Bool) -> Double {
		if fastingMode { return 0 }
		return hunger.isFinite ? min(max(hunger, 0), 100) : 36
	}

	public static func allowsAutonomousAction(
		_ action: AutonomousAction,
		fastingMode: Bool,
		quietMode: Bool
	) -> Bool {
		if quietMode {
			return action == .rest || action == .sleep
		}
		if fastingMode {
			return !(action == .askForFood || action == .lickIcon || action == .roll)
		}
		return true
	}

	public static func allowsDeletionMeal(quietMode: Bool) -> Bool { !quietMode }

	public static func shouldShowProgressDisplay(
		character: PetCharacterProfile,
		fastingMode: Bool,
		infiniteMode: Bool,
		coexistenceMode: Bool
	) -> Bool {
		!infiniteMode && !(fastingMode && (coexistenceMode || character.supportsFood))
	}
}
