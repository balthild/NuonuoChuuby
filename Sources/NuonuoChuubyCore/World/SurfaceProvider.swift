import AppKit

/// Builds the list of surfaces the pet can land on: each display's floor, plus
/// the top edge of every ordinary window.
///
/// The window tops come from ``SurfaceBuilder``'s graph, which subtracts
/// anything a window in front hides — so the pet never stands on an edge that is
/// covered by another window. The public shape stays `[SupportSurface]`; the
/// graph is the single source behind it.
@MainActor
public final class SurfaceProvider {
	public private(set) var surfaces: [SupportSurface] = []

	/// Windows change constantly, so the map is rebuilt on an interval rather
	/// than per frame.
	private static let refreshInterval: Double = 0.5
	private var secondsSinceWindowRefresh: Double = .greatestFiniteMagnitude
	private var windowSurfaces: [SupportSurface] = []
	private let platform: Platform

	public init(platform: Platform = MacOSPlatform()) {
		self.platform = platform
	}

	/// Test seam: builds a provider over a known surface map, without consulting
	/// the window server.
	init(surfaces: [SupportSurface]) {
		self.surfaces = surfaces
		self.platform = MacOSPlatform()
	}

	/// Test seam: replaces the map, as ``refresh(displaySpace:)`` would.
	func setSurfaces(_ surfaces: [SupportSurface]) {
		self.surfaces = surfaces
	}

	public func refresh(displaySpace: DisplaySpace) {
		let windows = platform.windows()
		let monitors = displaySpace.displays
		let ownPID = ProcessInfo.processInfo.processIdentifier

		let graph = SurfaceBuilder.build(
			windows: windows, monitors: monitors,
			isEligible: { window, monitor in
				WindowTerrainEligibilityPolicy.isEligiblePlatform(
					window, ownPID: ownPID, workArea: monitor.visibleFrame)
			})
		windowSurfaces = supportSurfaces(from: graph, monitors: monitors, windows: windows)
		// Highest first, floors last: the pet lands on the first surface it
		// crosses, so ordering keeps the nearest platform on top.
		surfaces = windowSurfaces.sorted { $0.top < $1.top }
	}

	/// Flattens the graph's standable edges (window tops and floors) back into the
	/// flat surface list the controller still consumes, one entry per visible run
	/// per monitor.
	private func supportSurfaces(
		from graph: [Surface], monitors: [Monitor], windows: [PlatformWindow]
	) -> [SupportSurface] {
		let bodies = Dictionary(windows.map { ($0.id, $0.bounds) }, uniquingKeysWith: { first, _ in first })
		var result: [SupportSurface] = []

		for surface in graph where surface.isReachable {
			switch surface.key.kind {
			case .floor:
				guard let monitor = monitors.first(where: { $0.id == surface.key.owner }) else { continue }
				result.append(
					SupportSurface(
						top: surface.offset, left: surface.span.start, right: surface.span.end,
						bottom: monitor.frame.bottom, isDesktopFloor: true, sourceID: nil))

			case .windowTop:
				let bottom = bodies[surface.key.owner]?.bottom ?? surface.offset
				for run in surface.visible {
					for monitor in monitors {
						// The edge itself has to be somewhere she can reach on this monitor.
						guard surface.offset >= monitor.visibleFrame.top,
							surface.offset < monitor.visibleFrame.bottom
						else { continue }
						let left = max(run.start, monitor.frame.left)
						let right = min(run.end, monitor.frame.right)
						guard right - left >= WindowTerrainEligibilityPolicy.minimumWidth else { continue }
						result.append(
							SupportSurface(
								top: surface.offset, left: left, right: right, bottom: bottom,
								isDesktopFloor: false, sourceID: surface.key.owner))
					}
				}

			default:
				// Vertical and bottom edges are built but not enabled this round (D3).
				continue
			}
		}
		return result
	}

	/// Called from the simulation tick; re-enumerates windows only occasionally.
	public func refreshIfStale(displaySpace: DisplaySpace, delta: Double) {
		secondsSinceWindowRefresh += delta
		guard secondsSinceWindowRefresh >= Self.refreshInterval else { return }
		secondsSinceWindowRefresh = 0
		refresh(displaySpace: displaySpace)
	}

	public var desktopFloors: [SupportSurface] {
		surfaces.filter(\.isDesktopFloor)
	}

	/// The surface a descending foot crosses between `fromY` and `toY`.
	public func landingSurface(footX: Double, fromY: Double, toY: Double, inset: Double = 10) -> SupportSurface? {
		surfaces
			.filter { $0.top >= fromY - 1 && $0.top <= toY + 1 && $0.containsX(footX, inset: inset) }
			.min { $0.top < $1.top }
	}

	/// The surface directly under a foot, tolerating a small gap.
	public func support(footX: Double, footY: Double, tolerance: Double = 8) -> SupportSurface? {
		surfaces
			.filter { $0.containsX(footX, inset: 8) && abs($0.top - footY) <= tolerance }
			.min { abs($0.top - footY) < abs($1.top - footY) }
	}

	/// The highest platform strictly below `currentTop` at this x — what she
	/// drops onto when sliding or jumping off an edge.
	public func surfaceBelow(footX: Double, currentTop: Double) -> SupportSurface? {
		surfaces
			.filter { $0.top > currentTop + 1 && $0.containsX(footX, inset: 8) }
			.min { $0.top < $1.top }
	}
}
