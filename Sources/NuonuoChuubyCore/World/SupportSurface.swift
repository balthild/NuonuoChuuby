import Foundation

/// A horizontal edge the pet can stand on: a desktop floor or (later) a window's
/// top edge. Kept in top-left, Y-down global coordinates.
public struct SupportSurface: Sendable, Equatable {
	public var top: Double
	public var left: Double
	public var right: Double
	public var bottom: Double
	public var isDesktopFloor: Bool
	/// The owning window's number, absent for a desktop floor.
	public var sourceID: UInt32?

	public var width: Double { right - left }

	/// A window whose bottom is above its top edge's usable area still counts as
	/// a platform, so `effectiveBottom` is used when deciding reachability.
	public var effectiveBottom: Double { max(top, bottom) }

	public func containsX(_ x: Double, inset: Double = 0) -> Bool {
		x >= left + inset && x <= right - inset
	}
}
