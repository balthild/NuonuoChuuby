import AppKit

/// Draws the current sprite frame and decides which clicks belong to the pet.
///
/// The window is a square, but the pet only occupies its centre. Clicks outside
/// the body ellipse are reported as "not mine" so they fall through to whatever
/// is behind the pet.
public final class PetView: NSView {
	/// Body ellipse in the view's coordinate space, derived from the character's
	/// canvas collision box.
	public var bodyEllipse: CGRect = .zero {
		didSet { if bodyEllipse != oldValue { window?.invalidateShadow() } }
	}

	public var image: CGImage? {
		didSet { needsDisplay = true }
	}

	/// -1 draws the pet mirrored (facing left), +1 as authored.
	public var facing: Double = 1 {
		didSet { if facing != oldValue { needsDisplay = true } }
	}

	public var onMouseDown: ((NSEvent) -> Void)?
	public var onMouseDragged: ((NSEvent) -> Void)?
	public var onMouseUp: ((NSEvent) -> Void)?
	public var onRightMouseDown: ((NSEvent) -> Void)?

	override public var isFlipped: Bool { true }
	override public var acceptsFirstResponder: Bool { false }

	override public func draw(_ dirtyRect: NSRect) {
		guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
		context.interpolationQuality = .high
		// The view is flipped so its coordinates match the simulation's (top-left
		// origin, Y down), but `CGContext.draw(_:in:)` assumes a bottom-left
		// origin and would render the frame upside down. `NSImage.draw(in:)` would
		// compensate for the flip by itself; the CGImage call does not, so the
		// counter-flip has to be explicit.
		context.saveGState()
		context.translateBy(x: 0, y: bounds.height)
		context.scaleBy(x: 1, y: -1)
		if facing < 0 {
			context.translateBy(x: bounds.width, y: 0)
			context.scaleBy(x: -1, y: 1)
		}
		context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
		context.restoreGState()
	}

	override public func hitTest(_ point: NSPoint) -> NSView? {
		let local = convert(point, from: superview)
		guard bounds.contains(local) else { return nil }
		return PetView.ellipseContains(bodyEllipse, local) ? self : nil
	}

	public static func ellipseContains(_ ellipse: CGRect, _ point: CGPoint) -> Bool {
		guard ellipse.width > 0, ellipse.height > 0 else { return false }
		let normalizedX = (point.x - ellipse.midX) / (ellipse.width / 2)
		let normalizedY = (point.y - ellipse.midY) / (ellipse.height / 2)
		return normalizedX * normalizedX + normalizedY * normalizedY <= 1
	}

	override public func mouseDown(with event: NSEvent) { onMouseDown?(event) }
	override public func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
	override public func mouseUp(with event: NSEvent) { onMouseUp?(event) }
	override public func rightMouseDown(with event: NSEvent) { onRightMouseDown?(event) }
}
