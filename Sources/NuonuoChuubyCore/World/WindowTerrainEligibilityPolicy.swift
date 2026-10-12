import Foundation

/// A window as the terrain system sees it. Kept platform-neutral so the
/// eligibility rules stay testable without the window server.
public struct TerrainWindow: Sendable, Equatable {
	public var number: UInt32
	public var ownerPID: Int32
	public var ownerName: String
	/// Only populated when the app has screen-recording permission; unused here.
	public var title: String?
	public var bounds: PixelRect
	/// CGWindowLevel. Ordinary app windows sit at 0; the Dock, the menu bar and
	/// system overlays do not.
	public var layer: Int
	public var alpha: Double

	public init(
		number: UInt32,
		ownerPID: Int32,
		ownerName: String,
		title: String? = nil,
		bounds: PixelRect,
		layer: Int,
		alpha: Double = 1
	) {
		self.number = number
		self.ownerPID = ownerPID
		self.ownerName = ownerName
		self.title = title
		self.bounds = bounds
		self.layer = layer
		self.alpha = alpha
	}
}

/// Which on-screen windows a pet may stand on.
///
/// The Windows original filtered by Win32 style bits; macOS expresses the same
/// intent with the window level, alpha and owner. The point is the same: only
/// ordinary, solid, user-facing windows are terrain — never the desktop, the
/// Dock, the menu bar, panels or our own pet windows.
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
		_ window: TerrainWindow,
		ownPID: Int32,
		workArea: PixelRect
	) -> Bool {
		// Only ordinary windows: anything raised above or dropped below the
		// normal level is chrome or an overlay.
		guard window.layer == 0 else { return false }
		guard window.alpha >= minimumAlpha else { return false }
		guard window.ownerPID != ownPID else { return false }
		guard !window.ownerName.isEmpty, !excludedOwners.contains(window.ownerName) else { return false }
		guard window.bounds.width >= minimumWidth, window.bounds.height >= minimumHeight else {
			return false
		}
		// The pet stands on the top edge, so that edge has to be somewhere she
		// can reach — inside the display, below the menu bar.
		guard window.bounds.top >= workArea.top, window.bounds.top < workArea.bottom else {
			return false
		}
		return true
	}
}
