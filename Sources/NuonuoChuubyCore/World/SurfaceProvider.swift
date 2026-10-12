import AppKit

/// The surfaces the pet can stand on: each display's floor, plus every window
/// edge, from ``SurfaceBuilder``'s graph.
@MainActor
public final class SurfaceProvider {
	public private(set) var surfaces: [Surface] = []
	/// Set by ``refresh(displaySpace:)``; the simulation suspends while true.
	public private(set) var isFullscreenAppActive = false

	/// Windows change constantly, so the graph is rebuilt on an interval.
	private static let refreshInterval: Double = 0.5
	private var secondsSinceWindowRefresh: Double = .greatestFiniteMagnitude
	private let platform: Platform

	public init(platform: Platform = MacOSPlatform()) {
		self.platform = platform
	}

	/// Test seam: builds a provider over a known graph, without touching the
	/// window server.
	init(surfaces: [Surface]) {
		self.surfaces = surfaces
		self.platform = MacOSPlatform()
	}

	/// Test seam: replaces the graph, as ``refresh(displaySpace:)`` would.
	func setSurfaces(_ surfaces: [Surface]) {
		self.surfaces = surfaces
	}

	public func refresh(displaySpace: DisplaySpace) {
		let ownPID = ProcessInfo.processInfo.processIdentifier
		let windows = platform.windows()
		isFullscreenAppActive = FullscreenDetector.isFullscreenAppActive(
			windows: windows,
			monitors: displaySpace.displays
		)
		surfaces = SurfaceBuilder.build(
			windows: windows,
			monitors: displaySpace.displays,
			isEligible: { window, monitor in
				WindowTerrainEligibilityPolicy.isEligiblePlatform(
					window,
					ownPID: ownPID,
					workArea: monitor.visibleFrame
				)
			}
		)
	}

	/// Called from the simulation tick; re-enumerates windows only occasionally.
	public func refreshIfStale(displaySpace: DisplaySpace, delta: Double) {
		secondsSinceWindowRefresh += delta
		guard secondsSinceWindowRefresh >= Self.refreshInterval else { return }
		secondsSinceWindowRefresh = 0
		refresh(displaySpace: displaySpace)
	}

	public var floors: [Surface] {
		surfaces.filter { $0.key.kind == .floor }
	}

	/// The standable surface under a foot, tolerating a small gap.
	public func support(at point: PixelPoint, tolerance: Double = 8) -> Surface? {
		standable(horizontalOnly: true)
			.filter { $0.isVisible(at: point, inset: 8) && abs($0.offset - point.y) <= tolerance }
			.min { abs($0.offset - point.y) < abs($1.offset - point.y) }
	}

	/// The surface a descending foot crosses between `fromY` and `toY`.
	public func landingSurface(
		footX: Double,
		fromY: Double,
		toY: Double,
		inset: Double = 10
	) -> Surface? {
		standable(horizontalOnly: true)
			.filter {
				$0.offset >= fromY - 1 && $0.offset <= toY + 1
					&& $0.isVisible(atCoordinate: footX, inset: inset)
			}
			.min { $0.offset < $1.offset }
	}

	/// The highest surface strictly below `currentTop` at this x — what she drops
	/// onto when sliding or jumping off an edge.
	public func surfaceBelow(footX: Double, currentTop: Double) -> Surface? {
		standable(horizontalOnly: true)
			.filter { $0.offset > currentTop + 1 && $0.isVisible(atCoordinate: footX, inset: 8) }
			.min { $0.offset < $1.offset }
	}

	/// The edges the pet may use, window tops and floors only this round (D3).
	private func standable(horizontalOnly: Bool) -> [Surface] {
		surfaces.filter {
			$0.isReachable && (!horizontalOnly || $0.isHorizontal)
		}
	}
}
