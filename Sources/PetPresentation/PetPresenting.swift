import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation

/// What the app shell needs from whatever puts the pet on screen.
///
/// Two renderers implement it: the small grid-moved window, which is the default, and
/// the full-display overlay that `--pet-overlay` selects. The seam is this narrow on
/// purpose — it is what let the two be compared, not an invitation to a third renderer.
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
