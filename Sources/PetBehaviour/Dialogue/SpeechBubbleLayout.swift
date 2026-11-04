import Foundation
import PetDesktop
import PetFoundation

/// The edge of the bubble that carries the tail, which points back at the pet.
public enum SpeechBubbleTail: Sendable, Equatable {
	case down
	case up
	case left
	case right
}

/// Where the bubble goes and which way its tail must point from there.
public struct SpeechBubblePlacement: Sendable, Equatable {
	public let topLeft: PixelPoint
	public let tail: SpeechBubbleTail

	public init(topLeft: PixelPoint, tail: SpeechBubbleTail) {
		self.topLeft = topLeft
		self.tail = tail
	}
}

/// Places the head bubble relative to the pet: above her head, or underneath her feet
/// when there is no room above.
///
/// It is **never** put beside her, and it is never moved inward to stay on the display:
/// it is centred on her horizontally and allowed to run off either side. Both are
/// deliberate. A side placement needs horizontal room the display often does not have,
/// and the lines are short enough that losing a character or two to the screen edge
/// beats moving the bubble away from the head it is speaking from. Keeping the
/// horizontal position a pure function of the pet is also what lets a small-window
/// renderer reserve room for the bubble in its window.
public enum SpeechBubbleLayout {
	/// Where a bubble may sit on a display: its full width, so a Dock on the left or
	/// right cannot hold the bubble away from her — she is drawn over the Dock and can
	/// be dragged into it — but not the menu bar strip, which a bubble must not cover.
	///
	/// Only the **vertical** bounds are used: the horizontal position is centred on her
	/// and may overflow the display's sides.
	public static func area(for monitor: Monitor) -> PixelRect {
		PixelRect(
			x: monitor.frame.x,
			y: monitor.visibleFrame.y,
			width: monitor.frame.width,
			height: monitor.visibleFrame.height
		)
	}

	/// - Parameters:
	///   - petFrame: the pet panel's frame, top-left origin, Y down.
	///   - area: the vertical bounds the bubble must stay within (see ``area(for:)``).
	///   - contentWidth: the bubble body, tail excluded.
	///   - contentHeight: the bubble body, tail excluded.
	///   - tailHeight: how far the tail sticks out of the body.
	public static func place(
		petFrame: PixelRect,
		contentWidth: Double,
		contentHeight: Double,
		tailHeight: Double,
		area: PixelRect
	) -> SpeechBubblePlacement {
		// Centred on her and left there: running off the display's side is accepted, so
		// there is nothing to clamp against.
		let x = petFrame.centerX - contentWidth / 2

		// The body's bottom edge sits just inside the pet panel's top, with the tail
		// hanging between the two.
		let anchorTop = petFrame.top + (petFrame.height * 0.16).rounded()
		if anchorTop - contentHeight - tailHeight >= area.top {
			return SpeechBubblePlacement(
				topLeft: PixelPoint(x: x, y: anchorTop - contentHeight - tailHeight),
				tail: .down
			)
		}

		// No room above — her head is off the screen, or the menu bar is in the way. It
		// goes under her feet instead, its tail pointing up at them.
		return SpeechBubblePlacement(
			topLeft: PixelPoint(
				x: x,
				y: petFrame.bottom.clamp(
					lower: area.top,
					upper: max(area.top, area.bottom - contentHeight - tailHeight)
				)
			),
			tail: .up
		)
	}
}
