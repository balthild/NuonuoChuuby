import Foundation

/// Turns a front-to-back window list and a display set into the surface graph.
///
/// Pure: the only inputs are window rectangles and their order (the z-order).
public enum SurfaceBuilder {
	/// Which way an edge runs, so the right coordinate is compared.
	private enum Axis {
		case horizontal
		case vertical

		/// The interval along this edge that `window` hides, if it covers it at all.
		func occludedInterval(covering coordinate: Double, of window: PlatformWindow) -> Span? {
			switch self {
			case .horizontal:
				guard window.bounds.top <= coordinate, coordinate < window.bounds.bottom else {
					return nil
				}
				return Span(start: window.bounds.left, end: window.bounds.right)
			case .vertical:
				guard window.bounds.left <= coordinate, coordinate < window.bounds.right else {
					return nil
				}
				return Span(start: window.bounds.top, end: window.bounds.bottom)
			}
		}
	}

	/// Builds every edge of every eligible window, plus a floor per monitor.
	///
	/// - Parameters:
	///   - windows: front to back, so index 0 is frontmost (see ``PlatformWindow/zIndex``).
	///   - monitors: the displays, each contributing a floor.
	///   - isEligible: whether a window may be terrain on a given monitor.
	public static func build(
		windows: [PlatformWindow],
		monitors: [Monitor],
		isEligible: (PlatformWindow, Monitor) -> Bool
	) -> [Surface] {
		var result: [Surface] = []

		for monitor in monitors {
			let span = Span(start: monitor.frame.left, end: monitor.frame.right)
			result.append(
				Surface(
					key: SurfaceKey(owner: monitor.id, kind: .floor),
					span: span,
					visible: [span],
					offset: monitor.visibleFrame.bottom,
					ownerBounds: monitor.frame,
					isReachable: true
				)
			)
		}

		let eligible = windows.map { window in monitors.contains { isEligible(window, $0) } }

		for (index, window) in windows.enumerated() {
			guard eligible[index] else { continue }
			// Only an ordinary app window hides an edge; our own overlays, the Dock
			// and HUDs are not desktop content.
			let occluders = (0..<index).filter { eligible[$0] }.map { windows[$0] }
			result.append(contentsOf: edges(of: window, occludedBy: occluders))
		}

		return result
	}

	private static func edges(
		of window: PlatformWindow,
		occludedBy occluders: [PlatformWindow]
	) -> [Surface] {
		let bounds = window.bounds
		// Only the top edge is standable this round (D3); the other three are
		// built for completeness.
		let horizontal: [(SurfaceKind, Double)] = [
			(.windowTop, bounds.top), (.windowBottom, bounds.bottom),
		]
		let vertical: [(SurfaceKind, Double)] = [
			(.windowLeft, bounds.left), (.windowRight, bounds.right),
		]

		var result: [Surface] = []
		for (kind, y) in horizontal {
			let span = Span(start: bounds.left, end: bounds.right)
			result.append(
				Surface(
					key: SurfaceKey(owner: window.id, kind: kind),
					span: span,
					visible: visibleRuns(of: span, covering: y, along: .horizontal, by: occluders),
					offset: y,
					ownerBounds: bounds,
					isReachable: kind == .windowTop
				)
			)
		}
		for (kind, x) in vertical {
			let span = Span(start: bounds.top, end: bounds.bottom)
			result.append(
				Surface(
					key: SurfaceKey(owner: window.id, kind: kind),
					span: span,
					visible: visibleRuns(of: span, covering: x, along: .vertical, by: occluders),
					offset: x,
					ownerBounds: bounds,
					isReachable: false
				)
			)
		}
		return result
	}

	private static func visibleRuns(
		of span: Span,
		covering coordinate: Double,
		along axis: Axis,
		by occluders: [PlatformWindow]
	) -> [Span] {
		var runs = [span]
		for occluder in occluders {
			guard let hidden = axis.occludedInterval(covering: coordinate, of: occluder) else { continue }
			runs = runs.flatMap { subtract(hidden, from: $0) }
			if runs.isEmpty { break }
		}
		return runs
	}

	private static func subtract(_ cut: Span, from run: Span) -> [Span] {
		guard let overlap = run.intersection(with: cut) else { return [run] }
		var parts: [Span] = []
		if run.start < overlap.start { parts.append(Span(start: run.start, end: overlap.start)) }
		if overlap.end < run.end { parts.append(Span(start: overlap.end, end: run.end)) }
		return parts
	}
}
