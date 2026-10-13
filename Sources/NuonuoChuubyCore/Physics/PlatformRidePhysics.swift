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

/// The little that is left of the original ride physics: how far a surface may
/// move before it stops being something she rides and becomes something that
/// throws her.
///
/// It applies to both surfaces she can be carried by — a ledge she is standing on
/// and the floor of a window she is inside — so the two cannot drift apart.
public enum PlatformRidePhysics {
	/// A window can blink out of the window server's list for a moment while it is
	/// being dragged; the perch is held this long rather than dropping her.
	public static let supportRecoveryGraceSeconds: Double = 0.35

	/// How far a surface may move in one tick before it is yanked rather than
	/// carrying her. 15 pt at 60 Hz is the 900 pt/s the original read as a
	/// deliberate flick.
	public static let releaseDisplacement: Double = 15

	/// The tick `releaseDisplacement` is written for, so the same rule can be
	/// applied to a movement measured over several of them.
	public static let referenceTickSeconds: Double = 1.0 / 60

	/// The same rule as ``releaseDisplacement``, for a movement measured over
	/// `seconds` rather than over one tick.
	///
	/// It is really a **speed** — 900 pt/s — and it has to be read that way
	/// whenever the two positions it compares are more than a frame apart. A box
	/// that is only looked at 30 times a second covers twice the ground between
	/// looks, and the raw displacement would then read an ordinary drag as a
	/// flick.
	public static func yankDisplacement(overSeconds seconds: Double) -> Double {
		releaseDisplacement * (seconds / referenceTickSeconds)
	}

	public static func shouldPreserveTransientSupport(unavailableSeconds: Double) -> Bool {
		unavailableSeconds.isFinite
			&& unavailableSeconds >= 0
			&& unavailableSeconds <= supportRecoveryGraceSeconds
	}
}
