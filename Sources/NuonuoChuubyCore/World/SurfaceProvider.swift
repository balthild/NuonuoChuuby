import AppKit

/// Builds the list of surfaces the pet can land on.
///
/// Only desktop floors exist for now; window tops are added by the terrain
/// provider. A desktop floor is the bottom of each display's visible area,
/// which already excludes the Dock and menu bar.
@MainActor
public final class SurfaceProvider {
	public private(set) var surfaces: [SupportSurface] = []

	public init() {}

	public func refresh(displaySpace: DisplaySpace) {
		surfaces = displaySpace.displays.map { display in
			SupportSurface(
				top: display.visibleFrame.bottom,
				left: display.frame.left,
				right: display.frame.right,
				bottom: display.frame.bottom,
				isDesktopFloor: true,
				sourceID: nil
			)
		}
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
}
