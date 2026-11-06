import AppKit

/// The window behaviour every pet window shares.
///
/// Borderless and non-activating, so she never takes focus; above the menu bar and
/// the Dock (see ``petPanelLevel``); on every Space; and free to hang past the edge of
/// a display — AppKit's default constraint pulls a window back into the screen's
/// visible frame, which is wrong for her, because her foot anchor sits near the
/// window's bottom and the window has to be allowed off the top edge.
class PetChromePanel: NSPanel {
	/// The pet's stacking level: above the menu bar (24) and the Dock (20), below open
	/// menus (101). She rests here whether or not she overlaps the chrome, so neither the
	/// menu bar nor the Dock can occlude her.
	///
	/// It must stay above 0: `FullscreenDetector` matches any level-0 window filling a
	/// display and does not exclude our own process, so a level-0 pet window would put her
	/// into a suspension loop with herself.
	static let petPanelLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

	/// The ghost icons' level: one step above the pet's.
	///
	/// A ghost stands where the file was, which can be anywhere on the display and is
	/// usually nowhere near her, so in the grid renderer it is a window of its own — and it
	/// is drawn over her, because she is eating it. Saying that with a level rather than by
	/// re-asserting the order is what keeps it free: her window is re-ordered whenever it is
	/// placed, so staying above her by ordering alone would mean ordering on her cadence.
	static let ghostPanelLevel = NSWindow.Level(rawValue: petPanelLevel.rawValue + 1)

	/// - Parameter ignoresMouseEvents: whether clicks should pass through to whatever is
	///   behind. True only for a window that is nothing but a picture — the ghost icons.
	///   Everything she can be drawn in is hit-tested instead, so a click on her works
	///   wherever she happens to be.
	/// - Parameter level: where the panel stacks. The default is ``petPanelLevel``; only the
	///   ghost icons ask for anything else.
	init(
		contentRect: NSRect,
		ignoresMouseEvents: Bool = false,
		level: NSWindow.Level = PetChromePanel.petPanelLevel
	) {
		super.init(
			contentRect: contentRect,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		if ignoresMouseEvents { self.ignoresMouseEvents = true }
		isFloatingPanel = true
		becomesKeyOnlyIfNeeded = true
		self.level = level
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
