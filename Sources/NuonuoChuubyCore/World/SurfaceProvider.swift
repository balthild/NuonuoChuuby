import AppKit

/// Builds the list of surfaces the pet can land on: each display's floor, plus
/// the top edge of every ordinary window.
///
/// A desktop floor is the bottom of a display's visible area, which already
/// excludes the Dock and menu bar. Window tops are re-read periodically, because
/// other apps move their windows underneath the pet.
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
		let floors = displaySpace.displays.map { display in
			SupportSurface(
				top: display.visibleFrame.bottom,
				left: display.frame.left,
				right: display.frame.right,
				bottom: display.frame.bottom,
				isDesktopFloor: true,
				sourceID: nil
			)
		}
		windowSurfaces = WindowSurfaceProvider.surfaces(
			from: WindowSurfaceProvider.eligibleWindows(
				from: platform.windows(),
				ownPID: ProcessInfo.processInfo.processIdentifier,
				displaySpace: displaySpace),
			displaySpace: displaySpace)
		// Highest first, floors last: the pet lands on the first surface it
		// crosses, so ordering keeps the nearest platform on top.
		surfaces = (windowSurfaces + floors).sorted { $0.top < $1.top }
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
