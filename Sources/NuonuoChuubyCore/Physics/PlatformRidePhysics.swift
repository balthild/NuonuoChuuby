import Foundation

/// What the pet's response to a moving surface was, for logging.
public enum PlatformMotionResponse: Sendable, Equatable {
	/// Carried along with it.
	case follow
	/// It moved up fast enough to throw her.
	case launchUpward
	/// It dropped away fast enough that she was left behind.
	case releaseDownward
}

/// The little that is left of the original ride physics: the grace that holds the
/// perch while a dragged window briefly vanishes from the window server's list.
public enum PlatformRidePhysics {
	/// A window can blink out of the window server's list for a moment while it is
	/// being dragged; the perch is held this long rather than dropping her.
	public static let supportRecoveryGraceSeconds: Double = 0.35

	public static func shouldPreserveTransientSupport(unavailableSeconds: Double) -> Bool {
		unavailableSeconds.isFinite
			&& unavailableSeconds >= 0
			&& unavailableSeconds <= supportRecoveryGraceSeconds
	}
}
