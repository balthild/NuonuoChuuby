import Foundation

/// User input may interrupt autonomous locomotion. Only short, atomic actions
/// that must finish their current animation reject a new drag gesture.
public enum DragInteractionPolicy {
	public static func canStart(from state: PetState) -> Bool {
		switch state {
		case .chomping, .climbing, .dragging, .pinching, .rolling, .waking:
			return false
		default:
			return true
		}
	}
}
