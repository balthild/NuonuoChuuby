import AppKit

/// The bubble's metrics and the one drawing routine they describe.
///
/// It lives apart from `OverlaySpeechBubbleController`, which only rasterises the
/// result and caches it, so the geometry and the picture can be tested without a
/// window or a layer.
@MainActor
public enum SpeechBubbleDrawing {
	public static let horizontalPadding: CGFloat = 12
	public static let verticalPadding: CGFloat = 7
	public static let tailHeight: CGFloat = 7
	public static let halfTailWidth: CGFloat = 5
	public static let maximumTextWidth: CGFloat = 240
	public static let cornerRadius: CGFloat = 9

	public static func textAttributes() -> [NSAttributedString.Key: Any] {
		[
			.font: NSFont.systemFont(ofSize: 13),
			.foregroundColor: NSColor.labelColor,
		]
	}

	// MARK: - Metrics

	public static func measuredTextSize(_ text: String) -> NSSize {
		if let cached = measuredTextCache[text] { return cached }
		let constraint = NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude)
		let bounding = (text as NSString).boundingRect(
			with: constraint,
			options: [.usesLineFragmentOrigin],
			attributes: textAttributes()
		)
		let size = NSSize(width: ceil(bounding.width), height: ceil(bounding.height))
		// Her lines are a small fixed set, so this settles after a few bubbles.
		if measuredTextCache.count > 64 { measuredTextCache.removeAll(keepingCapacity: true) }
		measuredTextCache[text] = size
		return size
	}

	/// Measured line sizes, keyed by the line, since the font and the width limit
	/// are fixed for the life of the process.
	private static var measuredTextCache: [String: NSSize] = [:]

	/// The bubble body for `text`, tail excluded — what the layout sizes against,
	/// since which way the tail points is decided after the fit is known.
	public static func bodySize(for text: String) -> NSSize {
		let size = measuredTextSize(text)
		return NSSize(
			width: size.width + horizontalPadding * 2,
			height: size.height + verticalPadding * 2
		)
	}

	/// The whole bubble, tail included, in its current orientation.
	public static func preferredSize(for text: String, tail: SpeechBubbleTail) -> NSSize {
		let body = bodySize(for: text)
		switch tail {
		case .down:
			return NSSize(width: body.width, height: body.height + tailHeight)
		case .left, .right:
			return NSSize(width: body.width + tailHeight, height: body.height)
		}
	}

	/// The rounded body, inset from the tail's edge.
	public static func bodyRect(in bounds: NSRect, tail: SpeechBubbleTail) -> NSRect {
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
			NSRect(x: 0, y: 0, width: max(0, bounds.width - tailHeight), height: bounds.height)
		}
	}

	/// The tail triangle, its base pulled just inside the body so the two shapes
	/// overlap and their union has no sliver along the joint.
	public static func tailTriangle(
		in body: NSRect,
		bounds: NSRect,
		tail: SpeechBubbleTail
	) -> CGPath {
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

	// MARK: - Drawing

	/// Draws the whole bubble into the current graphics context, `bounds` being its
	/// top-left origin, Y-down box.
	public static func draw(in bounds: NSRect, tail: SpeechBubbleTail, text: String) {
		let bubbleRect = bodyRect(in: bounds, tail: tail)

		// Stroking the body and the tail separately would outline their shared
		// edge too, drawing a line across the tail's base; union them first.
		let body = CGPath(
			roundedRect: bubbleRect,
			cornerWidth: cornerRadius,
			cornerHeight: cornerRadius,
			transform: nil
		)
		let path = NSBezierPath(
			cgPath: body.union(tailTriangle(in: bubbleRect, bounds: bounds, tail: tail))
		)

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
			attributes: textAttributes()
		)
	}

	/// Rasterises the bubble once, for a layer to composite.
	///
	/// The bubble's colours are dynamic, so the appearance is pinned here rather
	/// than inherited from whatever happens to be current when the context is made:
	/// the caller caches the result and has to be able to tell when it is stale.
	public static func image(
		size: NSSize,
		tail: SpeechBubbleTail,
		text: String,
		scale: CGFloat,
		isDark: Bool
	) -> CGImage? {
		let pixelWidth = Int((size.width * scale).rounded())
		let pixelHeight = Int((size.height * scale).rounded())
		guard pixelWidth > 0, pixelHeight > 0, let space = CGColorSpace(name: CGColorSpace.sRGB)
		else { return nil }
		guard
			let context = CGContext(
				data: nil,
				width: pixelWidth,
				height: pixelHeight,
				bitsPerComponent: 8,
				bytesPerRow: 0,
				space: space,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else { return nil }

		context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
		// A bitmap context is Y-up while every rectangle in the layout above is
		// Y-down, so flip the context rather than the geometry.
		context.translateBy(x: 0, y: CGFloat(pixelHeight))
		context.scaleBy(x: scale, y: -scale)

		let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
		appearance?.performAsCurrentDrawingAppearance {
			let previous = NSGraphicsContext.current
			NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
			draw(in: NSRect(origin: .zero, size: size), tail: tail, text: text)
			NSGraphicsContext.current = previous
		}
		return context.makeImage()
	}
}
