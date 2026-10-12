import Foundation

/// The edge of the bubble that carries the tail, which points back at the pet.
public enum SpeechBubbleTail: Sendable, Equatable {
	case down
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

/// Places the head bubble relative to the pet, preferring above the head and
/// falling back beside it when there is no room. The tail follows the
/// placement, so it always points at the pet.
public enum SpeechBubbleLayout {
	/// - Parameters:
	///   - petFrame: the pet panel's frame, top-left origin, Y down.
	///   - workArea: the visible area of the pet's display.
	///   - contentWidth: the bubble body, tail excluded.
	///   - contentHeight: the bubble body, tail excluded.
	///   - tailHeight: how far the tail sticks out of the body.
	public static func place(
		petFrame: PixelRect,
		contentWidth: Double,
		contentHeight: Double,
		tailHeight: Double,
		workArea: PixelRect,
		sideGap: Double = 6
	) -> SpeechBubblePlacement {
		// The body's bottom edge sits just inside the pet panel's top, with the
		// tail hanging between the two.
		let anchorTop = petFrame.top + (petFrame.height * 0.16).rounded()
		if anchorTop - contentHeight - tailHeight >= workArea.top {
			return SpeechBubblePlacement(
				topLeft: PixelPoint(
					x: centredX(petFrame: petFrame, width: contentWidth, workArea: workArea),
					y: anchorTop - contentHeight - tailHeight
				),
				tail: .down
			)
		}

		// No room above: tuck it into the pet's upper fifth and move to a side.
		let sideTop = clamp(
			petFrame.top + petFrame.height / 5,
			workArea.top,
			max(workArea.top, workArea.bottom - contentHeight)
		)
		if petFrame.right + sideGap + contentWidth + tailHeight <= workArea.right {
			// The tail sits on the bubble's left edge, pointing back left at her.
			return SpeechBubblePlacement(
				topLeft: PixelPoint(x: petFrame.right + sideGap, y: sideTop),
				tail: .left
			)
		}
		if petFrame.left - sideGap - contentWidth - tailHeight >= workArea.left {
			return SpeechBubblePlacement(
				topLeft: PixelPoint(
					x: petFrame.left - sideGap - contentWidth - tailHeight,
					y: sideTop
				),
				tail: .right
			)
		}

		// Neither side has room either, so keep it on screen above the pet with
		// the tail down rather than spilling off the display.
		return SpeechBubblePlacement(
			topLeft: PixelPoint(
				x: centredX(petFrame: petFrame, width: contentWidth, workArea: workArea),
				y: clamp(
					petFrame.top + petFrame.height / 5,
					workArea.top,
					max(workArea.top, workArea.bottom - contentHeight - tailHeight)
				)
			),
			tail: .down
		)
	}

	/// Horizontally centred on the pet but never pushed off the display.
	private static func centredX(petFrame: PixelRect, width: Double, workArea: PixelRect) -> Double {
		clamp(
			petFrame.centerX - width / 2,
			workArea.left,
			max(workArea.left, workArea.right - width)
		)
	}

	private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
		min(max(value, lower), upper)
	}
}
