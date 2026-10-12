import AppKit

/// The simulation is kept in **top-left origin, Y-down** coordinates (matching
/// the original Windows implementation) so the ported physics math is unchanged.
/// AppKit works in bottom-left origin, Y-up; this type owns the conversion.
public struct DisplaySpace: Sendable {
	public struct Display: Sendable, Equatable, Identifiable {
		public let id: UInt32
		/// Full display bounds in top-left, Y-down global coordinates.
		public let frame: PixelRect
		/// The area not covered by the Dock and menu bar.
		public let visibleFrame: PixelRect
		public let scale: Double
	}

	public let displays: [Display]
	/// The primary display's height, which defines the Y flip for every display.
	public let primaryHeight: Double

	@MainActor
	public init() {
		let screens = NSScreen.screens
		let primary = NSScreen.screens.first
		let primaryHeight = Double(primary?.frame.height ?? 0)
		self.primaryHeight = primaryHeight
		self.displays = screens.compactMap { screen in
			guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
			else { return nil }
			return Display(
				id: number.uint32Value,
				frame: DisplaySpace.toTopLeft(screen.frame, primaryHeight: primaryHeight),
				visibleFrame: DisplaySpace.toTopLeft(screen.visibleFrame, primaryHeight: primaryHeight),
				scale: Double(screen.backingScaleFactor)
			)
		}
	}

	public static func toTopLeft(_ rect: CGRect, primaryHeight: Double) -> PixelRect {
		let top = primaryHeight - Double(rect.origin.y) - Double(rect.height)
		return PixelRect(
			x: Double(rect.origin.x), y: top,
			width: Double(rect.width), height: Double(rect.height))
	}

	public static func toAppKit(_ rect: PixelRect, primaryHeight: Double) -> CGRect {
		let bottom = primaryHeight - rect.y - rect.height
		return CGRect(x: rect.x, y: bottom, width: rect.width, height: rect.height)
	}

	/// The display whose visible area contains the point, else the nearest one.
	public func display(containing point: PixelPoint) -> Display? {
		if let exact = displays.first(where: { $0.visibleFrame.contains(point) }) {
			return exact
		}
		return displays.min { lhs, rhs in
			DisplaySpace.distanceSquared(from: point, to: lhs.visibleFrame)
				< DisplaySpace.distanceSquared(from: point, to: rhs.visibleFrame)
		}
	}

	private static func distanceSquared(from point: PixelPoint, to rect: PixelRect) -> Double {
		let dx = max(max(rect.left - point.x, 0), point.x - rect.right)
		let dy = max(max(rect.top - point.y, 0), point.y - rect.bottom)
		return dx * dx + dy * dy
	}
}

extension PixelRect {
	public func contains(_ point: PixelPoint) -> Bool {
		point.x >= left && point.x <= right && point.y >= top && point.y <= bottom
	}

	public func insetBy(dx: Double, dy: Double) -> PixelRect {
		PixelRect(x: x + dx, y: y + dy, width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
	}
}
