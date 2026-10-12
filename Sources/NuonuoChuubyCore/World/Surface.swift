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
/// `t` parameterises a position along `span`, which is the **whole** edge
/// including any part another window hides. That is deliberate: an edge split by
/// an occluder keeps the same `t` for the same physical spot, so a perch survives
/// the edge being cut (refactor-plan §4.1).
public struct Surface: Sendable, Equatable {
	public var key: SurfaceKey
	/// The whole edge.
	public var span: Span
	/// The parts of the edge that are not hidden, in order. A list rather than a
	/// single span because an occluder in the middle of an edge leaves two
	/// disjoint visible runs (refactor-plan §4.2, "把遮挡者的区间减掉，剩下的").
	/// Empty means the edge is completely covered.
	public var visible: [Span]
	/// The edge's fixed coordinate: its y for a horizontal edge, its x for a
	/// vertical one.
	public var offset: Double
	/// Whether the pet may currently stand on it. Only window tops and floors are
	/// enabled this round (decision D3); the vertical edges are built but unused.
	public var isReachable: Bool

	public init(
		key: SurfaceKey, span: Span, visible: [Span], offset: Double, isReachable: Bool
	) {
		self.key = key
		self.span = span
		self.visible = visible
		self.offset = offset
		self.isReachable = isReachable
	}

	public var isFullyOccluded: Bool { visible.isEmpty }

	public func isVisible(_ t: Double) -> Bool { visible.contains { $0.contains(t) } }
}
