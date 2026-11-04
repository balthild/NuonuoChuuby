import AppKit

/// The window behaviour every pet window shares.
///
/// Borderless and non-activating, so she never takes focus; above the menu bar and
/// the Dock (see ``PetPanelLevel``); on every Space; and free to hang past the edge of
/// a display — AppKit's default constraint pulls a window back into the screen's
/// visible frame, which is wrong for her, because her foot anchor sits near the
/// panel's bottom and the panel has to be allowed off the top edge.
class PetChromePanel: NSPanel {
	init(contentRect: NSRect) {
		super.init(
			contentRect: contentRect,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		isFloatingPanel = true
		becomesKeyOnlyIfNeeded = true
		level = PetPanelLevel.pet
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		isMovable = false
		isMovableByWindowBackground = false
		hidesOnDeactivate = false
		animationBehavior = .none
		isReleasedWhenClosed = false
	}

	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { false }

	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
	}
}
