import Foundation

/// A landing only earns a reaction if it was hard enough to notice, or if the
/// pet was thrown by the user or the environment.
public enum LandingVoicePolicy {
	public static let userOrEnvironmentLaunchReasons: Set<String> = [
		"DragThrow",
		"PlatformLaunch",
		"PlatformDownwardRelease",
		"WindowMaximized",
		"WindowSideImpact",
		"EnclosureWindowLost",
	]

	public static func shouldReact(
		fallDistancePixels: Double,
		downwardImpactSpeed: Double,
		reason: String,
		displayScale: Double
	) -> Bool {
		let scale = max(0.5, displayScale)
		if fallDistancePixels >= 90 * scale { return true }
		return userOrEnvironmentLaunchReasons.contains(reason) && downwardImpactSpeed >= 360 * scale
	}
}
