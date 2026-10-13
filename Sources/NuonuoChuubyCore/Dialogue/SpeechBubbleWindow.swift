import AppKit

/// A small rounded bubble that floats above the pet's head and fades out on its
/// own. Like the pet panel it never activates the app.
public final class SpeechBubblePanel: NSPanel {
	public init() {
		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		level = .floating
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		ignoresMouseEvents = true
		hidesOnDeactivate = false
		animationBehavior = .none
		isReleasedWhenClosed = false
	}

	override public var canBecomeKey: Bool { false }
	override public var canBecomeMain: Bool { false }
}

/// Draws a rounded caption with a small tail pointing at the pet: the tail
/// hangs off whichever edge the layout chose.
final class SpeechBubbleView: NSView {
	var text: String = "" {
		didSet {
			needsDisplay = true
			invalidateIntrinsicContentSize()
		}
	}

	var tail: SpeechBubbleTail = .down {
		didSet {
			guard tail != oldValue else { return }
			needsDisplay = true
			invalidateIntrinsicContentSize()
		}
	}

	var tailHeight: CGFloat { SpeechBubbleDrawing.tailHeight }

	override var isFlipped: Bool { true }

	/// The bubble body for `text`, tail excluded — what the layout sizes against,
	/// since which way the tail points is decided after the fit is known.
	func bodySize(for text: String) -> NSSize {
		SpeechBubbleDrawing.bodySize(for: text)
	}

	/// The whole bubble, tail included, in its current orientation.
	var preferredSize: NSSize {
		SpeechBubbleDrawing.preferredSize(for: text, tail: tail)
	}

	override func draw(_ dirtyRect: NSRect) {
		SpeechBubbleDrawing.draw(in: bounds, tail: tail, text: text)
	}
}

@MainActor
public final class SpeechBubbleWindowController: SpeechBubblePresenting {
	private let panel = SpeechBubblePanel()
	private let view = SpeechBubbleView()
	private var hideWorkItem: DispatchWorkItem?

	public init() {
		panel.contentView = view
	}

	public var isVisible: Bool { panel.isVisible }

	public var currentText: String { view.text }

	/// The body size the bubble needs for `text`, so the layout can pick a spot
	/// before the bubble exists.
	public func bodySize(for text: String) -> (width: Double, height: Double) {
		let size = view.bodySize(for: text)
		return (Double(size.width), Double(size.height))
	}

	public var tailHeight: Double { Double(view.tailHeight) }

	/// Shows the bubble at `placement` (global top-left coordinates) and hides it
	/// after `duration`.
	public func show(
		_ text: String,
		placement: SpeechBubblePlacement,
		displaySpace: DisplaySpace,
		duration: Double
	) {
		guard !text.isEmpty else { return }
		apply(text: text, placement: placement, displaySpace: displaySpace)
		panel.alphaValue = 1
		panel.orderFrontRegardless()

		hideWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.hide() }
		hideWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
	}

	public func reposition(to placement: SpeechBubblePlacement, displaySpace: DisplaySpace) {
		guard panel.isVisible else { return }
		apply(text: view.text, placement: placement, displaySpace: displaySpace)
	}

	private func apply(text: String, placement: SpeechBubblePlacement, displaySpace: DisplaySpace) {
		// Assigning a property runs its observer even when the value did not change, and
		// this view's observers ask for a redisplay — which would typeset the same line
		// again on every frame she moved. Only touch them when they really differ.
		let textChanged = view.text != text
		let tailChanged = view.tail != placement.tail
		if textChanged { view.text = text }
		if tailChanged { view.tail = placement.tail }

		let size = view.preferredSize
		if panel.contentView?.bounds.size != size {
			panel.setContentSize(size)
		}
		if view.frame.size != size {
			view.frame = NSRect(origin: .zero, size: size)
		}

		let frame = DisplaySpace.toAppKit(
			PixelRect(
				x: placement.topLeft.x,
				y: placement.topLeft.y,
				width: Double(size.width),
				height: Double(size.height)
			),
			primaryHeight: displaySpace.primaryHeight
		)
		let current = panel.frame
		let sizeChanged = current.size != frame.size
		if current.origin != frame.origin || sizeChanged {
			panel.setFrame(frame, display: sizeChanged)
		}
	}

	public func hide() {
		hideWorkItem?.cancel()
		hideWorkItem = nil
		panel.orderOut(nil)
	}
}
