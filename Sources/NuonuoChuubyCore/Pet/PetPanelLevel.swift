import AppKit

/// How high the pet's panel is stacked.
public enum PetPanelLevel {
	/// Above the menu bar (level 24), below open menus (level 101).
	public static let aboveMenuBar = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

	/// The level of the full-display overlay the pet is drawn into: one below
	/// `.floating`, so the speech bubble and the ghost icons — both `.floating` —
	/// keep drawing over her.
	///
	/// It must not be 0. `FullscreenDetector` matches any level-0 window filling a
	/// display and does not exclude our own process, so a level-0 overlay would put
	/// the pet into a suspension loop with itself: suspend, hide, resume, show,
	/// suspend.
	public static let belowFloating = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

	/// The pet's panel only rises above the menu bar while it actually overlaps
	/// it. Everywhere else the resting level is kept, so the Dock (level 20) and the
	/// rest of the system chrome stay on top of her as they always were.
	///
	/// - Parameters:
	///   - panelTop: the panel's top edge, top-left origin, Y down.
	///   - workArea: the pet's display's visible area, whose `top` is the menu
	///     bar's bottom edge.
	///   - low: the level used while she is clear of the menu bar. The moving panel
	///     takes `.floating`; the full-display overlay takes ``belowFloating`` so the
	///     bubble and the ghost icons stay above it.
	public static func level(
		panelTop: Double,
		workArea: PixelRect,
		below low: NSWindow.Level = .floating
	) -> NSWindow.Level {
		panelTop < workArea.top ? aboveMenuBar : low
	}
}
