import AppKit

/// How high the pet's panel is stacked.
public enum PetPanelLevel {
	/// Above the menu bar (level 24), below open menus (level 101).
	public static let aboveMenuBar = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

	/// The pet's panel only rises above the menu bar while it actually overlaps
	/// it. Everywhere else `.floating` is kept, so the Dock (level 20) and the
	/// rest of the system chrome stay on top of her as they always were.
	///
	/// - Parameters:
	///   - panelTop: the panel's top edge, top-left origin, Y down.
	///   - workArea: the pet's display's visible area, whose `top` is the menu
	///     bar's bottom edge.
	public static func level(panelTop: Double, workArea: PixelRect) -> NSWindow.Level {
		panelTop < workArea.top ? aboveMenuBar : .floating
	}
}
