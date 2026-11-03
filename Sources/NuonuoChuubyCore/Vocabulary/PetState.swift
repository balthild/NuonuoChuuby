import Foundation

public enum PetState: String, Sendable, CaseIterable {
	case idle
	case running
	case falling
	case landing
	case curious
	case sleeping
	case waking
	case climbing
	case sliding
	case rolling
	case licking
	case chomping
	case satisfied
	case dragging
	case pinching
	case pranking
	case interacting
	case paused
}

public enum MovementPurpose: String, Sendable, CaseIterable {
	case none
	case meal
	case iconLick
	case wander
	case explore
	case patrol
	case climbApproach
	case edgeSlideApproach
	case edgeJumpApproach
}

extension MovementPurpose {
	/// Whether this walk is a journey to a chosen spot rather than an aimless
	/// wander, and so takes the quicker pace.
	var usesExplorePace: Bool {
		switch self {
		case .explore, .climbApproach, .edgeSlideApproach, .edgeJumpApproach:
			return true
		default:
			return false
		}
	}
}
