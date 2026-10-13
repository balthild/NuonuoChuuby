import Foundation

/// What the pet may and may not do while a window's walls hold her.
public enum WindowEnclosureBehaviorPolicy {
	/// A deletion is worth leaving the box for, but only if there is really
	/// something to eat: she runs out through the nearest wall rather than
	/// finishing the wait. An empty queue is not a reason to escape.
	public static func shouldEscapeForMeal(isEnclosed: Bool, pendingMeals: Int) -> Bool {
		isEnclosed && pendingMeals > 0
	}

	/// Licking a desktop icon means walking to it, which she cannot do from
	/// inside a box. Waiting is the honest answer, not swallowing the request.
	public static func allowsIconLick(isEnclosed: Bool) -> Bool { !isEnclosed }
}
