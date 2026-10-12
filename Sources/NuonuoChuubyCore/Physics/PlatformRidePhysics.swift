import Foundation

/// What the pet does when the window she is standing on moves.
public enum PlatformMotionResponse: Sendable, Equatable {
	/// Ride along with it.
	case follow
	/// The window was yanked up fast enough to throw her.
	case launchUpward
	/// The window dropped away fast enough that she is briefly airborne.
	case releaseDownward
}

public struct PlatformMotionDecision: Sendable, Equatable {
	public var response: PlatformMotionResponse
	/// The upward velocity she leaves with, for ``PlatformMotionResponse/launchUpward``.
	public var initialPetVelocityY: Double
}

public struct AirbornePlatformContactDecision: Sendable, Equatable {
	public var pushesPet: Bool
	public var correctedFootY: Double
	public var petVelocityY: Double
	public var platformVelocityY: Double
}

/// A standing pet rides the window under her. A slow drag is followed; a fast
/// enough movement either throws her or leaves her behind, which is what makes a
/// dragged window feel physical instead of glued.
public enum PlatformRidePhysics {
	/// A window can blink out of the surface map for a moment while it is being
	/// dragged; support is held this long rather than dropping her.
	public static let supportRecoveryGraceSeconds: Double = 0.35

	/// How far a window must move *in one frame* before she is thrown or left
	/// behind, rather than carried.
	///
	/// The Windows original used 3 pt and 360 pt/s, which at 60 fps means a mere
	/// 6 pt of travel in a frame. An ordinary drag clears that easily, so she was
	/// flung 400 pt up for no reason.
	///
	/// These are deliberately higher, and the speed is aligned with the figure
	/// Ledgeling uses to decide that a window was *yanked* rather than dragged
	/// (`STARTLING_SPEED = 900`): below it she simply rides, above it the move was
	/// deliberate enough to react to. This is a conscious departure from the
	/// original's constants.
	public static let minimumDisplacement: Double = 12
	public static let throwSpeedThreshold: Double = 900

	public static func evaluate(
		displacementY: Double,
		velocityY: Double,
		displayScale: Double
	) -> PlatformMotionDecision {
		let scale = max(0.75, displayScale)
		let moved = abs(displacementY) >= minimumDisplacement * scale
		let moving = abs(velocityY) >= throwSpeedThreshold * scale

		// Rising fast: the ledge catches her feet and flings her up.
		if moved, moving, displacementY < 0 {
			return PlatformMotionDecision(
				response: .launchUpward,
				initialPetVelocityY: min(max(velocityY * 0.88, -1150 * scale), -300 * scale))
		}

		// Dropping away fast: she is left behind rather than dragged down, so she
		// falls onto the ledge as it comes back.
		if moved, moving, displacementY > 0 {
			return PlatformMotionDecision(response: .releaseDownward, initialPetVelocityY: 0)
		}

		return PlatformMotionDecision(response: .follow, initialPetVelocityY: 0)
	}

	public static func shouldPreserveTransientSupport(unavailableSeconds: Double) -> Bool {
		unavailableSeconds.isFinite
			&& unavailableSeconds >= 0
			&& unavailableSeconds <= supportRecoveryGraceSeconds
	}

	/// While airborne, a window edge rising through her feet pushes her up again
	/// instead of letting her fall through it.
	public static func resolveAirborneContact(
		footY: Double,
		petVelocityY: Double,
		previousPlatformTop: Double,
		currentPlatformTop: Double,
		deltaSeconds: Double,
		displayScale: Double
	) -> AirbornePlatformContactDecision {
		let scale = max(0.75, displayScale)
		let displacementY = currentPlatformTop - previousPlatformTop
		let platformVelocityY = displacementY / max(deltaSeconds, 1.0 / 240)

		// The edge must actually have crossed her feet this frame: it was at or
		// below them, and is now above. Without the first half, a window that is
		// simply sitting high above her would drag her up to it the moment she
		// fell below it — the same teleport the ride had.
		let wasAtOrBelowFeet = previousPlatformTop >= footY - 0.5
		let nowAboveFeet = currentPlatformTop < footY - 0.5
		let crossesFeet = wasAtOrBelowFeet && nowAboveFeet
		let risesFast =
			displacementY <= -minimumDisplacement * scale
			&& platformVelocityY <= -throwSpeedThreshold * scale

		guard crossesFeet, risesFast else {
			return AirbornePlatformContactDecision(
				pushesPet: false, correctedFootY: footY, petVelocityY: petVelocityY,
				platformVelocityY: platformVelocityY)
		}

		let inheritedVelocity = min(max(platformVelocityY * 0.88, -1150 * scale), -300 * scale)
		return AirbornePlatformContactDecision(
			pushesPet: true,
			correctedFootY: currentPlatformTop,
			petVelocityY: min(petVelocityY, inheritedVelocity),
			platformVelocityY: platformVelocityY)
	}
}

/// A window that maximises while the pet is standing on it throws her clear.
public struct WindowExpansionBounce: Sendable, Equatable {
	public var velocityX: Double
	public var velocityY: Double
}

public enum WindowExpansionPhysics {
	/// Only applies when her support has just vanished *and* that window filled
	/// the screen — otherwise she was simply dropped and falls normally.
	public static func evaluate(
		supportUnavailable: Bool,
		windowMaximized: Bool,
		footX: Double,
		monitorCenterX: Double,
		displayScale: Double
	) -> WindowExpansionBounce? {
		guard supportUnavailable, windowMaximized else { return nil }
		let scale = max(0.75, displayScale)
		let direction = footX < monitorCenterX ? -1.0 : 1.0
		return WindowExpansionBounce(velocityX: direction * 260 * scale, velocityY: -820 * scale)
	}
}
