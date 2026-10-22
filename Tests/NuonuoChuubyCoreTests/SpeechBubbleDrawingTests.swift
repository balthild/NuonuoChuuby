import AppKit
import Testing

@testable import NuonuoChuubyCore

/// These pin the geometry the two bubble renderers share. The window renderer
/// draws it into an `NSView` and the overlay renderer into a `CGImage`, so a
/// change here changes both and must be deliberate.
@Suite("Speech bubble drawing")
@MainActor
struct SpeechBubbleDrawingTests {
	@Test("The body is the measured text plus the padding")
	func bodySizeIsTheTextPlusPadding() {
		let text = "走两步"
		let measured = SpeechBubbleDrawing.measuredTextSize(text)
		let body = SpeechBubbleDrawing.bodySize(for: text)
		#expect(body.width == measured.width + SpeechBubbleDrawing.horizontalPadding * 2)
		#expect(body.height == measured.height + SpeechBubbleDrawing.verticalPadding * 2)
	}

	/// Only the edge the tail hangs off has to grow, which is why the layout can
	/// size the body before it knows which way the tail will point.
	@Test("Only the tail's own edge grows the box")
	func preferredSizeGrowsOnTheTailsOwnEdge() {
		let text = "走两步"
		let body = SpeechBubbleDrawing.bodySize(for: text)
		let down = SpeechBubbleDrawing.preferredSize(for: text, tail: .down)
		let up = SpeechBubbleDrawing.preferredSize(for: text, tail: .up)
		let left = SpeechBubbleDrawing.preferredSize(for: text, tail: .left)
		let right = SpeechBubbleDrawing.preferredSize(for: text, tail: .right)

		#expect(down.width == body.width)
		#expect(down.height == body.height + SpeechBubbleDrawing.tailHeight)
		#expect(up.width == body.width)
		#expect(up.height == body.height + SpeechBubbleDrawing.tailHeight)
		#expect(left.width == body.width + SpeechBubbleDrawing.tailHeight)
		#expect(left.height == body.height)
		#expect(right == left)
	}

	@Test("The body keeps clear of the tail's edge")
	func bodyRectLeavesRoomForTheTail() {
		let bounds = NSRect(x: 0, y: 0, width: 100, height: 50)
		let tail = SpeechBubbleDrawing.tailHeight

		let down = SpeechBubbleDrawing.bodyRect(in: bounds, tail: .down)
		#expect(down == NSRect(x: 0, y: 0, width: 100, height: 50 - tail))

		let up = SpeechBubbleDrawing.bodyRect(in: bounds, tail: .up)
		#expect(up == NSRect(x: 0, y: tail, width: 100, height: 50 - tail))

		let left = SpeechBubbleDrawing.bodyRect(in: bounds, tail: .left)
		#expect(left == NSRect(x: tail, y: 0, width: 100 - tail, height: 50))

		let right = SpeechBubbleDrawing.bodyRect(in: bounds, tail: .right)
		#expect(right == NSRect(x: 0, y: 0, width: 100 - tail, height: 50))
	}

	@Test("A downward tail hangs off the body's bottom edge, centred on it")
	func downwardTailPointsBelowTheBody() {
		let bounds = NSRect(x: 0, y: 0, width: 100, height: 50)
		let body = SpeechBubbleDrawing.bodyRect(in: bounds, tail: .down)
		let box = SpeechBubbleDrawing.tailTriangle(in: body, bounds: bounds, tail: .down)
			.boundingBox

		#expect(box.midX == bounds.midX)
		#expect(box.maxY == bounds.height)
		#expect(box.minY < body.maxY)
	}

	@Test("An upward tail hangs off the body's top edge, centred on it")
	func upwardTailPointsAboveTheBody() {
		let bounds = NSRect(x: 0, y: 0, width: 100, height: 50)
		let body = SpeechBubbleDrawing.bodyRect(in: bounds, tail: .up)
		let box = SpeechBubbleDrawing.tailTriangle(in: body, bounds: bounds, tail: .up)
			.boundingBox

		#expect(box.midX == bounds.midX)
		#expect(box.minY == 0)
		#expect(box.maxY > body.minY)
	}

	@Test("A left tail points off the body's left edge, centred on it")
	func leftTailPointsLeftOfTheBody() {
		let bounds = NSRect(x: 0, y: 0, width: 100, height: 50)
		let body = SpeechBubbleDrawing.bodyRect(in: bounds, tail: .left)
		let box = SpeechBubbleDrawing.tailTriangle(in: body, bounds: bounds, tail: .left)
			.boundingBox

		#expect(box.midY == bounds.midY)
		#expect(box.minX == 0)
		#expect(box.maxX > body.minX)
	}

	@Test("A right tail points off the body's right edge, centred on it")
	func rightTailPointsRightOfTheBody() {
		let bounds = NSRect(x: 0, y: 0, width: 100, height: 50)
		let body = SpeechBubbleDrawing.bodyRect(in: bounds, tail: .right)
		let box = SpeechBubbleDrawing.tailTriangle(in: body, bounds: bounds, tail: .right)
			.boundingBox

		#expect(box.midY == bounds.midY)
		#expect(box.maxX == bounds.width)
		#expect(box.minX < body.maxX)
	}

	/// The layer path rasterises once and is never resized, so the bitmap has to be
	/// the exact pixel size the display scale calls for or the text is blurry.
	@Test("The raster is the bubble at the display scale")
	func imageUsesTheDisplayScale() {
		let size = NSSize(width: 120, height: 36)
		let image = SpeechBubbleDrawing.image(
			size: size,
			tail: .down,
			text: "走两步",
			scale: 2,
			isDark: false
		)
		#expect(image?.width == 240)
		#expect(image?.height == 72)
	}

	@Test("A bubble too small to have pixels has no raster")
	func imageIsNilWithoutPositivePixels() {
		let image = SpeechBubbleDrawing.image(
			size: NSSize(width: 0, height: 0),
			tail: .down,
			text: "走两步",
			scale: 2,
			isDark: false
		)
		#expect(image == nil)
	}
}
