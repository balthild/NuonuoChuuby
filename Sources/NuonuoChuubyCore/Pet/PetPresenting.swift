import AppKit

/// What the rest of the app needs from whatever puts the pet on screen.
///
/// Two implementations exist. `OverlayPetWindowController` (the default) draws her
/// into a full-display transparent window that never moves; `--pet-panel` selects
/// `PetWindowController`, which moves a small panel to where she is instead. Both
/// report the same placement rectangle and expose a ``speechBubble``, so the speech
/// coordinator drives either one without knowing which it got.
@MainActor
public protocol PetPresenting: AnyObject {
	/// Supplied by the menu bar layer; called on a right-click.
	var menuProvider: ((NSEvent) -> NSMenu?)? { get set }
	/// The bubble she speaks through, drawn the way this presenter draws her.
	///
	/// It belongs to the presenter rather than to the caller because the two
	/// renderers put it on screen differently: a panel of its own, or a layer of the
	/// overlay that also holds her.
	var speechBubble: any SpeechBubblePresenting { get }
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
	/// Creates a fake icon for a deleted item, drawn the way this presenter draws
	/// the pet: a panel of its own, or a layer of the overlay.
	func makeGhostIcon() -> any GhostIconPresenting
}
