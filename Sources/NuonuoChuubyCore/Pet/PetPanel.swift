import AppKit

/// A borderless, transparent, always-on-top panel that never takes focus.
public final class PetPanel: NSPanel {
	public init(contentRect: NSRect) {
		super.init(
			contentRect: contentRect,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		isFloatingPanel = true
		becomesKeyOnlyIfNeeded = true
		level = .floating
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		isMovable = false
		isMovableByWindowBackground = false
		hidesOnDeactivate = false
		animationBehavior = .none
		// A borderless panel must opt out of the default release-on-close.
		isReleasedWhenClosed = false
	}

	override public var canBecomeKey: Bool { true }
	override public var canBecomeMain: Bool { false }

	/// Allows the panel off the screen edges.
	///
	/// Her foot anchor sits near the bottom of the panel, so when she stands on a
	/// window close to the top of the screen the panel's top has to go above it.
	/// AppKit's default constraint pulls the panel back to the screen's visible
	/// frame, which left her drawn ~130 pt below where the simulation had her —
	/// she looked like she was floating in mid-air with nothing under her feet.
	override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
	}
}
