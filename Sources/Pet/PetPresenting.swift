import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation

/// What the app shell needs from whatever puts the pet on screen.
///
/// Two renderers implement it: the full-display overlay, which is the one that ships,
/// and the small moving panel that `--pet-panel` selects for the mouse-move
/// comparison. The seam is this narrow on purpose — it is the part the experiment has
/// to hold constant, not an invitation to a third renderer.
@MainActor
public protocol PetPresenting: AnyObject {
	var menuProvider: ((NSEvent) -> NSMenu?)? { get set }
	var speechBubble: any SpeechBubblePresenting { get }
	var onPlacementChanged: ((PixelRect) -> Void)? { get set }
	var onSuspensionChanged: ((Bool) -> Void)? { get set }

	func show()
	func hide()
	func updateDisplaySpace(_ space: DisplaySpace)
	func makeGhostIcon() -> any GhostIconPresenting
}
