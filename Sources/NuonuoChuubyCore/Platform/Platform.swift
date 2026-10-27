import Foundation

/// A window as the operating system reports it.
///
/// The list order **is** the z-order: index 0 is frontmost, and occluders are the
/// windows before it in the list.
public struct PlatformWindow: Sendable, Equatable {
	/// `CGWindowID`, used as the owner of a surface key.
	public var id: UInt32
	public var ownerPID: Int32
	public var ownerName: String
	/// Top-left origin, Y down, in points.
	public var bounds: PixelRect
	/// `CGWindowLevel`. Ordinary app windows sit at 0.
	public var layer: Int
	public var alpha: Double
	/// 0 = frontmost.
	public var zIndex: Int

	public init(
		id: UInt32,
		ownerPID: Int32,
		ownerName: String,
		bounds: PixelRect,
		layer: Int,
		alpha: Double = 1,
		zIndex: Int = 0
	) {
		self.id = id
		self.ownerPID = ownerPID
		self.ownerName = ownerName
		self.bounds = bounds
		self.layer = layer
		self.alpha = alpha
		self.zIndex = zIndex
	}
}

/// A display, in top-left, Y-down global coordinates (see ``DisplaySpace``).
public struct Monitor: Sendable, Equatable, Identifiable {
	public var id: UInt32
	/// Full display bounds.
	public var frame: PixelRect
	/// What the Dock and the menu bar do not cover.
	public var visibleFrame: PixelRect
	public var scale: Double

	public init(id: UInt32, frame: PixelRect, visibleFrame: PixelRect, scale: Double) {
		self.id = id
		self.frame = frame
		self.visibleFrame = visibleFrame
		self.scale = scale
	}
}

extension Array where Element == Monitor {
	/// Whether any of these displays shows any part of the rectangle.
	///
	/// A rectangle that is on no display at all is not on this desktop: during a
	/// Space switch the window server reports the neighbouring desks' windows too,
	/// laid out along the strip the transition slides across, with coordinates far
	/// outside every display. See `Docs/Internal/platform-quirks.md`.
	public func shows(_ rect: PixelRect) -> Bool {
		contains { $0.frame.intersects(rect) }
	}
}

/// The windowing system, behind the smallest surface the simulation needs
/// (geometry only).
@MainActor
public protocol Platform {
	func windows() -> [PlatformWindow]
	/// An empty array means the session is locked or there is no display. Callers
	/// must treat that as "suspend", never as an empty desktop.
	func monitors() -> [Monitor]
}
