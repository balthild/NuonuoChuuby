import AppKit

/// How high the pet's windows are stacked.
public enum PetPanelLevel {
	/// The pet's own level: above the menu bar (24) and the Dock (20), below open
	/// menus (101). She rests here whether or not she overlaps the chrome, so
	/// neither the menu bar nor the Dock can occlude her.
	///
	/// It must stay above 0: `FullscreenDetector` matches any level-0 window
	/// filling a display and does not exclude our own process, so a level-0 pet
	/// window would put her into a suspension loop with herself.
	public static let pet = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
}
