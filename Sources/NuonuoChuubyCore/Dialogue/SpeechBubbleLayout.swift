import Foundation

/// Places the head bubble relative to the pet, preferring above the head and
/// falling back beside it when there is no room.
public enum SpeechBubbleLayout {
	/// - Parameters:
	///   - petFrame: the pet panel's frame, top-left origin, Y down.
	///   - bubbleSize: the bubble's width and height in points.
	///   - workArea: the visible area of the pet's display.
	/// - Returns: the bubble's top-left corner.
	public static func topLeft(
		petFrame: PixelRect,
		bubbleWidth: Double,
		bubbleHeight: Double,
		workArea: PixelRect,
		sideGap: Double = 6
	) -> PixelPoint {
		// Horizontally centred on the pet but never pushed off the display.
		var left = clamp(
			petFrame.left + petFrame.width / 2 - bubbleWidth / 2,
			workArea.left,
			max(workArea.left, workArea.right - bubbleWidth)
		)

		// The bubble's bottom edge sits just inside the pet panel's top.
		var top = petFrame.top + (petFrame.height * 0.16).rounded() - bubbleHeight

		if top < workArea.top {
			// No room above: tuck it into the pet's upper fifth and move to the
			// nearer side that has space.
			top = clamp(
				petFrame.top + petFrame.height / 5,
				workArea.top,
				max(workArea.top, workArea.bottom - bubbleHeight)
			)
			if petFrame.right + bubbleWidth + sideGap <= workArea.right {
				left = petFrame.right + sideGap
			} else if petFrame.left - bubbleWidth - sideGap >= workArea.left {
				left = petFrame.left - bubbleWidth - sideGap
			}
		}

		return PixelPoint(x: left, y: top)
	}

	private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
		min(max(value, lower), upper)
	}
}
