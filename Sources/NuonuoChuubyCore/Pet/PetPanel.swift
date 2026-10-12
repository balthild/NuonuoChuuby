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
}
