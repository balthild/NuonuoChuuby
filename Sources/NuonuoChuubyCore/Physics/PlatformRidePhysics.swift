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

	public static func evaluate(
		displacementY: Double,
		velocityY: Double,
		displayScale: Double
	) -> PlatformMotionDecision {
		let scale = max(0.75, displayScale)

		// Rising fast: the ledge catches her feet and flings her up.
		if displacementY <= -3 * scale, velocityY <= -360 * scale {
			return PlatformMotionDecision(
				response: .launchUpward,
				initialPetVelocityY: min(max(velocityY * 0.88, -1150 * scale), -300 * scale))
		}

		// Dropping away fast: she is left behind rather than dragged down, so she
		// falls onto the ledge as it comes back.
		if displacementY >= 2 * scale, velocityY >= 90 * scale {
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
		let risesThroughPet = currentPlatformTop < footY - 0.5
		let risesFast = displacementY <= -3 * scale && platformVelocityY <= -360 * scale

		guard risesThroughPet, risesFast else {
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
