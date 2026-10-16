import Foundation

/// How hungry she reads at a glance.
///
/// The bands are the original's (`MainWindow.xaml.cs`), so a given hunger is
/// grouped the same way it was there.
public enum HungerBand: Int, Sendable, CaseIterable {
	case comfortable
	case hungry
	case veryHungry
}

/// Turns a hunger value into what the menu shows: a whole percentage, and the band
/// its colour comes from.
public enum HungerDisplayPolicy {
	public static let hungryThreshold: Double = 55
	public static let veryHungryThreshold: Double = 80

	/// The hunger clamped into 0…100. Everything shown is taken from this, so a
	/// value the simulation could never produce cannot reach the display.
	///
	/// Range only: a NaN is not made finite by clamping, which is why the
	/// percentage conversion guards for itself.
	public static func clamp(_ hunger: Double) -> Double {
		hunger.clamp(lower: 0, upper: 100)
	}

	public static func percentage(forHunger hunger: Double) -> Int {
		clamp(hunger).roundedToInt()
	}

	public static func band(forHunger hunger: Double) -> HungerBand {
		let value = clamp(hunger)
		if value >= veryHungryThreshold { return .veryHungry }
		if value >= hungryThreshold { return .hungry }
		return .comfortable
	}
}
