import Foundation

/// Which edge of a surface's owner this is.
public enum SurfaceKind: String, Sendable, CaseIterable {
	case windowTop
	case windowBottom
	case windowLeft
	case windowRight
	case floor
}

/// Identifies a surface: the window it belongs to, plus which edge.
///
/// A floor's owner is the monitor id.
public struct SurfaceKey: Sendable, Hashable {
	public var owner: UInt32
	public var kind: SurfaceKind

	public init(owner: UInt32, kind: SurfaceKind) {
		self.owner = owner
		self.kind = kind
	}
}

/// A one-dimensional interval along an edge.
public struct Span: Sendable, Equatable {
	public var start: Double
	public var end: Double

	public init(start: Double, end: Double) {
		self.start = start
		self.end = end
	}

	public var length: Double { end - start }

	public func contains(_ t: Double) -> Bool { t >= start && t <= end }

	public func intersection(with other: Span) -> Span? {
		let lo = max(start, other.start)
		let hi = min(end, other.end)
		return lo < hi ? Span(start: lo, end: hi) : nil
	}
}

/// One edge of one window (or a monitor's floor).
///
/// `t` parameterises a position along `span`, the **whole** edge including any part
/// another window hides, so an edge cut by an occluder keeps the same `t` for the
/// same physical spot.
public struct Surface: Sendable, Equatable {
	public var key: SurfaceKey
	public var span: Span
	/// The parts of the edge that are not hidden, in order. A list rather than a
	/// single span because an occluder in the middle leaves two disjoint runs.
	/// Empty means the edge is completely covered.
	public var visible: [Span]
	/// The edge's fixed coordinate: its y for a horizontal edge, its x for a
	/// vertical one.
	public var offset: Double
	/// The owning window's full rectangle (a monitor's for a floor). Climbing needs
	/// the window's bottom edge, which the edge alone does not carry.
	public var ownerBounds: PixelRect?
	/// Whether the pet may stand on it. Only window tops and floors are enabled this
	/// round; the vertical edges are built but unused.
	public var isReachable: Bool

	public var isHorizontal: Bool { key.kind != .windowLeft && key.kind != .windowRight }

	public init(
		key: SurfaceKey,
		span: Span,
		visible: [Span],
		offset: Double,
		ownerBounds: PixelRect? = nil,
		isReachable: Bool
	) {
		self.key = key
		self.span = span
		self.visible = visible
		self.offset = offset
		self.ownerBounds = ownerBounds
		self.isReachable = isReachable
	}

	public var isFullyOccluded: Bool { visible.isEmpty }

	/// A `t` position (0…1 along `span`) mapped to its coordinate in world space.
	public func coordinate(atT t: Double) -> Double { span.start + t * span.length }

	/// The inverse: a world coordinate mapped to `t`, unclamped.
	public func t(atCoordinate coordinate: Double) -> Double {
		span.length > 0 ? (coordinate - span.start) / span.length : 0
	}

	public func isVisible(atCoordinate coordinate: Double, inset: Double = 0) -> Bool {
		visible.contains { coordinate >= $0.start + inset && coordinate <= $0.end - inset }
	}

	public func visibleRun(containingT t: Double) -> Span? {
		let coordinate = coordinate(atT: t)
		return visible.first { $0.contains(coordinate) }
	}

	public func visibleRun(containing point: PixelPoint) -> Span? {
		let coordinate = isHorizontal ? point.x : point.y
		return visible.first { $0.contains(coordinate) }
	}

	public func isVisible(at point: PixelPoint, inset: Double = 0) -> Bool {
		let coordinate = isHorizontal ? point.x : point.y
		return isVisible(atCoordinate: coordinate, inset: inset)
	}
}
