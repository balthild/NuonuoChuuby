import AppKit

/// A window content view that paints nothing, takes no clicks, and uses the flipped
/// (top-left, Y-down) coordinate system the window server and the layouts here speak.
///
/// Used by the grid renderer's bubble and ghost icon, whose contents are a single
/// layer. Flipped rather than plain because the shapes drawn into them — a ghost icon's
/// rotation in particular — were authored against the overlay's flipped root, and the
/// direction of a rotation depends on it.
class PetLayerHostView: NSView {
	override var isFlipped: Bool { true }

	override func draw(_ dirtyRect: NSRect) {}

	/// Clicks go to whatever is behind: these windows exist to be looked at.
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
