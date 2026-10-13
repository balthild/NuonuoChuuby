import AppKit

/// The surfaces the pet can stand on: each display's floor, plus every window
/// edge, from ``SurfaceBuilder``'s graph.
///
/// It also keeps the window **rectangles**, which the enclosure and the side
/// collision need — a task that has a different sampling rate from the graph, so
/// it gets its own cadence here rather than sharing this one.
@MainActor
public final class SurfaceProvider {
	public private(set) var surfaces: [Surface] = []
	/// Set by ``refresh(displaySpace:)``; the simulation suspends while true.
	public private(set) var isFullscreenAppActive = false

	/// The windows that could hold her, keyed by window id. The z-order travels
	/// with them, because whether she is hidden is a question about which of them
	/// are in front of the one holding her.
	public private(set) var windowBodies: [UInt32: WindowBody] = [:]
	/// The same, one sample earlier: a side collision is a difference between
	/// two samples, so both are needed.
	public private(set) var previousWindowBodies: [UInt32: WindowBody] = [:]
	/// Bumped on every body sample, so the collision pass runs once per sample
	/// instead of once per frame.
	public private(set) var bodyRefreshVersion = 0
	/// Simulated seconds between the two most recent body samples.
	public private(set) var bodySampleElapsed: Double = 0
	/// Set by ``rebaselineBodySamples()``: the next sample is a starting point.
	private var nextBodySampleIsBaseline = false

	/// Windows change constantly, so the graph is rebuilt on an interval.
	private static let refreshInterval: Double = 0.5
	/// The body sample runs far faster than the graph, because the side collision
	/// is a difference between consecutive samples and the original sampled its
	/// window list every 0.06 s for exactly that reason. On our 0.5 s cadence the
	/// same thresholds read a drag as a crawl and the throw lands half a second
	/// late. Measured on this machine, one enumeration is 0.48 ms for 25 windows,
	/// so 10 Hz costs about half a percent of one core.
	private static let bodySampleInterval: Double = 0.1

	private var secondsSinceWindowRefresh: Double = .greatestFiniteMagnitude
	private var secondsSinceBodySample: Double = .greatestFiniteMagnitude
	private let platform: Platform

	public init(platform: Platform = MacOSPlatform()) {
		self.platform = platform
	}

	/// Test seam: builds a provider over a known graph, without touching the
	/// window server.
	init(surfaces: [Surface]) {
		self.surfaces = surfaces
		self.platform = MockPlatform()
	}

	/// Test seam: replaces the graph, as ``refresh(displaySpace:)`` would.
	func setSurfaces(_ surfaces: [Surface]) {
		self.surfaces = surfaces
	}

	/// Test seam: replaces the body sample, as ``sampleBodiesIfStale`` would.
	func setBodies(_ bodies: [UInt32: WindowBody], previous: [UInt32: WindowBody] = [:]) {
		previousWindowBodies = previous
		windowBodies = bodies
		bodySampleElapsed = Self.bodySampleInterval
		bodyRefreshVersion += 1
	}

	/// Forgets the earlier sample, so the next one is a baseline rather than a step.
	///
	/// A side collision is a difference between two samples and is scaled by the
	/// interval between them. After a gap in the simulation — a locked screen, a
	/// fullscreen app — the two samples are that whole gap apart while the code still
	/// believes they are a tenth of a second apart, so ordinary movement reads as a
	/// window lashing past her.
	///
	/// Dropping the earlier sample is not enough on its own: the sample held **now**
	/// is from before the gap too, and it would become the earlier sample of the next
	/// pair — a difference spanning the gap all over again, one sample later. So the
	/// next sample is told to start from itself, which makes its difference zero.
	public func rebaselineBodySamples() {
		previousWindowBodies = [:]
		nextBodySampleIsBaseline = true
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

	/// Called from the simulation tick, on its own faster clock than the graph.
	///
	/// A window is a body when its rectangle could hold her: an ordinary app
	/// window that is not merely the display's own background. Whether she can
	/// stand on its top edge is irrelevant here — she goes in through the middle.
	public func sampleBodiesIfStale(displaySpace: DisplaySpace, delta: Double) {
		secondsSinceBodySample += delta
		guard secondsSinceBodySample >= Self.bodySampleInterval else { return }
		// The very first sample, and any sample after a stall, reports the nominal
		// interval rather than an unbounded gap: the edge speed is a difference
		// over time, so an enormous gap would make every sweep look like nothing.
		let elapsed = min(secondsSinceBodySample, Self.bodySampleInterval)
		secondsSinceBodySample = 0

		let ownPID = ProcessInfo.processInfo.processIdentifier
		var bodies: [UInt32: WindowBody] = [:]
		for window in platform.windows() {
			guard WindowTerrainEligibilityPolicy.isEligibleAppWindow(window, ownPID: ownPID)
			else { continue }
			guard
				WindowEnclosureEligibilityPolicy.isBoundedBody(
					window.bounds,
					monitors: displaySpace.displays
				)
			else { continue }
			bodies[window.id] = WindowBody(bounds: window.bounds, zIndex: window.zIndex)
		}

		previousWindowBodies = nextBodySampleIsBaseline ? bodies : windowBodies
		nextBodySampleIsBaseline = false
		windowBodies = bodies
		bodySampleElapsed = elapsed
		bodyRefreshVersion += 1
	}

	/// Which window is hiding the pet, if any. See ``WindowOcclusionPolicy``.
	public func coveringWindow(of owner: UInt32, body: PixelRect) -> UInt32? {
		WindowOcclusionPolicy.coveringWindow(of: owner, her: body, among: windowBodies)
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
