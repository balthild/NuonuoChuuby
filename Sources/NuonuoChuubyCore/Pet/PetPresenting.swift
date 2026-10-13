import AppKit

/// What the rest of the app needs from whatever puts the pet on screen.
///
/// Two implementations exist. `PetWindowController` moves a small panel to where
/// she is. `OverlayPetWindowController` draws her into a full-display transparent
/// window that never moves (see `--pet-overlay`). Both report the same placement
/// rectangle, so the speech bubble follows either one with no change.
@MainActor
public protocol PetPresenting: AnyObject {
	/// Supplied by the menu bar layer; called on a right-click.
	var menuProvider: ((NSEvent) -> NSMenu?)? { get set }
	/// Called after every move, so attached panels (the head bubble) can follow.
	///
	/// The rectangle is always **the pet's own square**, never the presenter's
	/// window. A full-display overlay would otherwise hand the bubble the screen's
	/// rectangle and place it entirely wrong.
	var onPlacementChanged: ((PixelRect) -> Void)? { get set }
	/// Called when the simulation suspends or resumes, so panels that belong to
	/// her can be put away with her rather than left over the fullscreen app.
	var onSuspensionChanged: ((Bool) -> Void)? { get set }

	func show()
	func updateDisplaySpace(_ space: DisplaySpace)
}
