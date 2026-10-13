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

	private let horizontalPadding: CGFloat = 12
	private let verticalPadding: CGFloat = 7
	let tailHeight: CGFloat = 7
	private let halfTailWidth: CGFloat = 5
	private let maximumTextWidth: CGFloat = 240

	override var isFlipped: Bool { true }

	private var textAttributes: [NSAttributedString.Key: Any] {
		[
			.font: NSFont.systemFont(ofSize: 13),
			.foregroundColor: NSColor.labelColor,
		]
	}

	private func measuredTextSize(_ text: String) -> NSSize {
		// Layout is what CoreText is slow at, and the text of a bubble does not change
		// once it is up — but the placement is recomputed every time she moves, which
		// measured the same line again on every frame she animated while speaking.
		if let cached = measuredTextCache[text] { return cached }
		let constraint = NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude)
		let bounding = (text as NSString).boundingRect(
			with: constraint,
			options: [.usesLineFragmentOrigin],
			attributes: textAttributes
		)
		let size = NSSize(width: ceil(bounding.width), height: ceil(bounding.height))
		// Her lines are a small fixed set, so this settles after a few bubbles.
		if measuredTextCache.count > 64 { measuredTextCache.removeAll(keepingCapacity: true) }
		measuredTextCache[text] = size
		return size
	}

	/// Measured line sizes, keyed by the line, since the fonts and the width limit
	/// are fixed for the life of the view.
	private var measuredTextCache: [String: NSSize] = [:]

	/// The bubble body for `text`, tail excluded — what the layout sizes against,
	/// since which way the tail points is decided after the fit is known.
	func bodySize(for text: String) -> NSSize {
		let size = measuredTextSize(text)
		return NSSize(
			width: size.width + horizontalPadding * 2,
			height: size.height + verticalPadding * 2
		)
	}

	/// The whole bubble, tail included, in its current orientation.
	var preferredSize: NSSize {
		let body = bodySize(for: text)
		switch tail {
		case .down:
			return NSSize(width: body.width, height: body.height + tailHeight)
		case .left, .right:
			return NSSize(width: body.width + tailHeight, height: body.height)
		}
	}

	/// The rounded body, inset from the tail's edge.
	private var bodyRect: NSRect {
		switch tail {
		case .down:
			NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - tailHeight))
		case .left:
			NSRect(
				x: tailHeight,
				y: 0,
				width: max(0, bounds.width - tailHeight),
				height: bounds.height
			)
		case .right:
			NSRect(
				x: 0,
				y: 0,
				width: max(0, bounds.width - tailHeight),
				height: bounds.height
			)
		}
	}

	/// The tail triangle, its base pulled just inside the body so the two shapes
	/// overlap and their union has no sliver along the joint.
	private func tailTriangle(in body: NSRect) -> CGPath {
		let overlap: CGFloat = 1
		let points: [NSPoint]
		switch tail {
		case .down:
			points = [
				NSPoint(x: body.midX - halfTailWidth, y: body.maxY - overlap),
				NSPoint(x: body.midX + halfTailWidth, y: body.maxY - overlap),
				NSPoint(x: body.midX, y: bounds.height),
			]
		case .left:
			points = [
				NSPoint(x: body.minX + overlap, y: body.midY - halfTailWidth),
				NSPoint(x: body.minX + overlap, y: body.midY + halfTailWidth),
				NSPoint(x: 0, y: body.midY),
			]
		case .right:
			points = [
				NSPoint(x: body.maxX - overlap, y: body.midY - halfTailWidth),
				NSPoint(x: body.maxX - overlap, y: body.midY + halfTailWidth),
				NSPoint(x: bounds.width, y: body.midY),
			]
		}

		let path = CGMutablePath()
		path.move(to: points[0])
		path.addLine(to: points[1])
		path.addLine(to: points[2])
		path.closeSubpath()
		return path
	}

	override func draw(_ dirtyRect: NSRect) {
		let bubbleRect = bodyRect

		// Stroking the body and the tail separately would outline their shared
		// edge too, drawing a line across the tail's base; union them first.
		let body = CGPath(
			roundedRect: bubbleRect,
			cornerWidth: 9,
			cornerHeight: 9,
			transform: nil
		)
		let path = NSBezierPath(cgPath: body.union(tailTriangle(in: bubbleRect)))

		NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
		path.fill()
		NSColor.separatorColor.setStroke()
		path.lineWidth = 1
		path.stroke()

		let inset = NSRect(
			x: bubbleRect.minX + horizontalPadding,
			y: bubbleRect.minY + verticalPadding,
			width: max(0, bubbleRect.width - horizontalPadding * 2),
			height: max(0, bubbleRect.height - verticalPadding * 2)
		)
		(text as NSString).draw(
			with: inset,
			options: [.usesLineFragmentOrigin],
			attributes: textAttributes
		)
	}
}

@MainActor
public final class SpeechBubbleWindowController {
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
		duration: Double = 3.2
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
		// `text` and `tail` mark the view dirty themselves when they really change, and
		// resizing its frame does too. Asking for a redisplay here as well meant that
		// following her around — every frame while she moved — typeset and redrew the
		// whole bubble, line and all, without a word of it having changed.
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
