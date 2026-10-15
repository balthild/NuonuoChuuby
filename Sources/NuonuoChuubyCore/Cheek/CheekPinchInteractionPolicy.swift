import Foundation

/// Whether a cheek pinch may start from a given state.
///
/// A pinch interrupts what she is doing much as a drag does, so the drag policy
/// applies as well — which is what already refuses climbing. A nap is refused
/// only here: upstream lets a sleeping pet be pinched, but being grabbed by the
/// face should not be what wakes her.
public enum CheekPinchInteractionPolicy {
	public static func canStart(from state: PetState) -> Bool {
		switch state {
		case .sleeping, .climbing:
			return false
		default:
			return DragInteractionPolicy.canStart(from: state)
		}
	}
}
