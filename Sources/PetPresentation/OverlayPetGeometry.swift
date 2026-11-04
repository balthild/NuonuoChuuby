import CoreGraphics
import PetDesktop
import PetFoundation

/// Geometry for drawing the pet inside a full-display overlay.
///
/// Shared by everything that draws into those overlays — the pet window, the speech
/// bubble and the ghost icons — so it lives on its own rather than inside the one that
/// owns the windows.
public enum OverlayPetGeometry {
	/// The pet's rectangle, expressed in the overlay's own coordinate space.
	///
	/// Both inputs are top-left origin, Y-down (`DisplaySpace` convention), so this
	/// is a translation by the negative of the display's origin. The result can have
	/// a negative origin while she straddles the left or top edge of her display.
	public static func localPetFrame(petFrame: PixelRect, displayFrame: PixelRect) -> PixelRect {
		let origin = localTopLeft(PixelPoint(x: petFrame.x, y: petFrame.y), in: displayFrame)
		return PixelRect(
			x: origin.x,
			y: origin.y,
			width: petFrame.width,
			height: petFrame.height
		)
	}

	/// A global point, expressed in the overlay's own coordinate space.
	public static func localTopLeft(_ point: PixelPoint, in displayFrame: PixelRect) -> PixelPoint {
		PixelPoint(x: point.x - displayFrame.x, y: point.y - displayFrame.y)
	}

	/// The overlay that holds `point`.
	///
	/// Falls back to the first display, so something momentarily past every screen
	/// edge is still drawn somewhere rather than disappearing. `nil` only when there
	/// are no displays at all, which the simulation already treats as a suspension.
	public static func hostingDisplayIndex(for point: PixelPoint, displays: [Monitor]) -> Int? {
		guard !displays.isEmpty else { return nil }
		return displays.firstIndex { $0.frame.contains(point) } ?? 0
	}

	/// The overlay she is drawn into: the display whose full bounds hold her centre.
	public static func hostingDisplayIndex(for petFrame: PixelRect, displays: [Monitor]) -> Int? {
		hostingDisplayIndex(
			for: PixelPoint(x: petFrame.centerX, y: petFrame.centerY),
			displays: displays
		)
	}
}
