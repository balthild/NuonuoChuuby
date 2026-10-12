import Foundation

/// Where the pet is anchored: a position **along an edge**, not a world point.
///
/// This is the heart of the refactor. A window's move or resize is followed
/// exactly and for free, because the world position is recomputed from the
/// current surface every frame rather than integrated from a velocity. `t` is
/// defined on the whole edge (`span`), so an edge cut by another window keeps
/// the same `t` for the same physical spot.
public struct Perch: Sendable, Equatable {
	public var key: SurfaceKey
	/// 0…1, along `span` (the whole edge).
	public var t: Double

	public init(key: SurfaceKey, t: Double) {
		self.key = key
		self.t = t
	}

	/// The world position of this perch on a given surface.
	public func position(in surface: Surface) -> PixelPoint {
		let along = surface.coordinate(atT: t)
		return surface.isHorizontal
			? PixelPoint(x: along, y: surface.offset)
			: PixelPoint(x: surface.offset, y: along)
	}

	/// The perch for `point` on `surface`.
	public static func at(_ point: PixelPoint, on surface: Surface) -> Perch {
		let coordinate = surface.isHorizontal ? point.x : point.y
		return Perch(key: surface.key, t: surface.t(atCoordinate: coordinate))
	}
}
