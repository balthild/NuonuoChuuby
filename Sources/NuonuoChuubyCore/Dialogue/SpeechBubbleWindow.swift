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

/// Draws a rounded caption with a small tail pointing down at the pet.
final class SpeechBubbleView: NSView {
	var text: String = "" {
		didSet { needsDisplay = true; invalidateIntrinsicContentSize() }
	}

	private let horizontalPadding: CGFloat = 12
	private let verticalPadding: CGFloat = 7
	private let tailHeight: CGFloat = 7
	private let maximumTextWidth: CGFloat = 240

	override var isFlipped: Bool { true }

	private var textAttributes: [NSAttributedString.Key: Any] {
		[
			.font: NSFont.systemFont(ofSize: 13),
			.foregroundColor: NSColor.labelColor,
		]
	}

	private var textSize: NSSize {
		let constraint = NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude)
		let bounding = (text as NSString).boundingRect(
			with: constraint, options: [.usesLineFragmentOrigin], attributes: textAttributes)
		return NSSize(width: ceil(bounding.width), height: ceil(bounding.height))
	}

	var preferredSize: NSSize {
		let size = textSize
		return NSSize(
			width: size.width + horizontalPadding * 2,
			height: size.height + verticalPadding * 2 + tailHeight)
	}

	override func draw(_ dirtyRect: NSRect) {
		let bubbleRect = NSRect(
			x: 0, y: 0,
			width: bounds.width,
			height: max(0, bounds.height - tailHeight))

		let path = NSBezierPath(roundedRect: bubbleRect, xRadius: 9, yRadius: 9)
		// The tail sits just left of centre so it does not cover the pet's face.
		let tailX = bubbleRect.midX
		let tail = NSBezierPath()
		tail.move(to: NSPoint(x: tailX - 5, y: bubbleRect.maxY))
		tail.line(to: NSPoint(x: tailX + 5, y: bubbleRect.maxY))
		tail.line(to: NSPoint(x: tailX, y: bounds.height))
		tail.close()
		path.append(tail)

		NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
		path.fill()
		NSColor.separatorColor.setStroke()
		path.lineWidth = 1
		path.stroke()

		let inset = NSRect(
			x: horizontalPadding, y: verticalPadding,
			width: bubbleRect.width - horizontalPadding * 2,
			height: bubbleRect.height - verticalPadding * 2)
		(text as NSString).draw(
			with: inset, options: [.usesLineFragmentOrigin], attributes: textAttributes)
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

	/// Places the bubble above `head` (global top-left coordinates) and hides it
	/// after `duration`.
	public func show(_ text: String, above head: PixelPoint, displaySpace: DisplaySpace, duration: Double = 3.2) {
		guard !text.isEmpty else { return }
		view.text = text
		let size = view.preferredSize
		panel.setContentSize(size)

		let frame = DisplaySpace.toAppKit(
			PixelRect(x: head.x - Double(size.width) / 2, y: head.y - Double(size.height) - 6,
				width: Double(size.width), height: Double(size.height)),
			primaryHeight: displaySpace.primaryHeight)
		panel.setFrame(frame, display: true)
		view.frame = NSRect(origin: .zero, size: size)
		view.needsDisplay = true
		panel.alphaValue = 1
		panel.orderFrontRegardless()

		hideWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.hide() }
		hideWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
	}

	public func hide() {
		hideWorkItem?.cancel()
		hideWorkItem = nil
		panel.orderOut(nil)
	}
}
