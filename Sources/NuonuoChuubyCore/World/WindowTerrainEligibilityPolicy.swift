import Foundation

/// Which on-screen windows a pet may stand on: only ordinary, solid, user-facing
/// windows are terrain — never the desktop, the Dock, the menu bar, panels or our
/// own pet windows.
public enum WindowTerrainEligibilityPolicy {
	public static let minimumWidth: Double = 140
	public static let minimumHeight: Double = 60
	public static let minimumAlpha: Double = 0.05

	/// Owners that are chrome or system surfaces, never something to stand on.
	public static let excludedOwners: Set<String> = [
		"Window Server",
		"Dock",
		"Control Center",
		"Notification Center",
		"Spotlight",
		"SystemUIServer",
		"WindowManager",
		"loginwindow",
		"universalaccessd",
	]

	public static func isEligiblePlatform(
		_ window: PlatformWindow,
		ownPID: Int32,
		workArea: PixelRect
	) -> Bool {
		guard isEligibleAppWindow(window, ownPID: ownPID) else { return false }
		// The pet stands on the top edge, so that edge has to be somewhere she
		// can reach — inside the display, below the menu bar. An enclosure is
		// entered through the body rather than the top edge, so it uses
		// ``isEligibleAppWindow`` alone.
		guard window.bounds.top >= workArea.top, window.bounds.top < workArea.bottom else {
			return false
		}
		return true
	}

	/// Whether the window is an ordinary, solid, user-facing application window,
	/// ignoring where its edges are.
	public static func isEligibleAppWindow(_ window: PlatformWindow, ownPID: Int32) -> Bool {
		// Only ordinary windows: anything raised above or dropped below the
		// normal level is chrome or an overlay.
		guard window.layer == 0 else { return false }
		guard window.alpha >= minimumAlpha else { return false }
		guard window.ownerPID != ownPID else { return false }
		guard !window.ownerName.isEmpty, !excludedOwners.contains(window.ownerName) else {
			return false
		}
		guard window.bounds.width >= minimumWidth, window.bounds.height >= minimumHeight else {
			return false
		}
		return true
	}
}
