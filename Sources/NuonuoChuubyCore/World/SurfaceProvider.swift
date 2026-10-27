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

	/// Whether the desktop is being swapped — the user switched Spaces.
	///
	/// While the transition runs, the window server reports the neighbouring desks'
	/// windows as well as this one's, laid out along the strip the transition slides
	/// along, so a large part of the list is on no display at all. Nothing can be read
	/// from that: a window edge sweeping through her is the whole desktop moving past
	/// her, the walls of a box she is in are being slid away, and the edge she is
	/// standing on belongs to a desk she has left. The simulation holds still until
	/// the list settles, which is what this flag is for.
	///
	/// Two independent signals raise it, because each misses cases the other catches:
	/// a window on no display (the strip is being reported at all) and a desktop slide
	/// (the transition is under way even when every window in the sample is still on
	/// the display, which is what a shortcut switch looks like). See
	/// ``DesktopSlideDetector``.
	public private(set) var isDesktopSwapping = false
	/// The rectangles of the most recent sample, kept only to tell a slide from a drag.
	///
	/// Deliberately **not** cleared by ``rebaselineBodySamples()``: that is about her
	/// own movement, and clearing this would blind the slide detector for a sample in
	/// the middle of the very transition it exists to catch.
	private var previousSampleBounds: [UInt32: PixelRect] = [:]
	/// Consecutive samples that looked like the desktop sliding.
	///
	/// Two rather than one: a sample taken across a gap — a suspension, a stall — is a
	/// difference spanning the whole gap, and one such pair could otherwise pass for a
	/// slide. Nothing real can produce two in a row.
	private var slideSamples = 0

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
		let monitors = displaySpace.displays
		// Windows on no display are on another desktop, not on this one. Counting
		// them would put edges she can never reach into the graph, and — worse — let
		// her drop onto one, which is precisely what a Space switch used to do.
		let windows = platform.windows().filter { monitors.shows($0.bounds) }
		isFullscreenAppActive = FullscreenDetector.isFullscreenAppActive(
			windows: windows,
			monitors: monitors
		)
		surfaces = SurfaceBuilder.build(
			windows: windows,
			monitors: monitors,
			isTerrain: { window, monitor in
				WindowTerrainEligibilityPolicy.isEligiblePlatform(
					window,
					ownPID: ownPID,
					workArea: monitor.visibleFrame
				)
			},
			occludes: { window in
				// Where its top edge is has nothing to do with whether it is opaque and
				// in front of something.
				WindowTerrainEligibilityPolicy.isEligibleAppWindow(window, ownPID: ownPID)
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
	/// A window is sampled when it is ordinary desktop content, and *marked* when it
	/// could also hold her. Which of the two a caller needs depends on the question:
	/// a window filling the display hides her but cannot hold her.
	public func sampleBodiesIfStale(displaySpace: DisplaySpace, delta: Double) {
		secondsSinceBodySample += delta
		guard secondsSinceBodySample >= Self.bodySampleInterval else { return }
		// The very first sample, and any sample after a stall, reports the nominal
		// interval rather than an unbounded gap: the edge speed is a difference
		// over time, so an enormous gap would make every sweep look like nothing.
		let elapsed = min(secondsSinceBodySample, Self.bodySampleInterval)
		secondsSinceBodySample = 0
		takeBodySample(displaySpace: displaySpace, elapsed: elapsed)
	}

	private func takeBodySample(displaySpace: DisplaySpace, elapsed: Double) {
		let ownPID = ProcessInfo.processInfo.processIdentifier
		let monitors = displaySpace.displays
		var bodies: [UInt32: WindowBody] = [:]
		var offScreen = false
		for window in platform.windows() {
			guard WindowTerrainEligibilityPolicy.isEligibleAppWindow(window, ownPID: ownPID)
			else { continue }
			guard monitors.shows(window.bounds) else {
				offScreen = true
				continue
			}
			bodies[window.id] = WindowBody(
				bounds: window.bounds,
				zIndex: window.zIndex,
				isEnclosureCandidate: WindowEnclosureEligibilityPolicy.isBoundedBody(
					window.bounds,
					monitors: monitors
				)
			)
		}

		// Nothing is a step across a desktop swap: both lists are of different desks,
		// and the windows that are in both have been slid thousands of points. So the
		// sample that notices a swap, and the first one after it, start from
		// themselves rather than from the list before them.
		//
		// The slide is measured against the **raw** previous sample rather than against
		// `previousWindowBodies`, because the rebaselining below makes that equal to the
		// new list — which would leave the transition invisible after its first sample.
		let rectangles = bodies.mapValues(\.bounds)
		let minimumStep = WindowSideCollisionPolicy.minimumEdgeSpeed * elapsed
		if DesktopSlideDetector.isSliding(
			from: previousSampleBounds,
			to: rectangles,
			minimumStep: minimumStep
		) {
			slideSamples += 1
		} else {
			slideSamples = 0
		}
		previousSampleBounds = rectangles

		let swapping = offScreen || slideSamples >= 2
		let startsAfresh = nextBodySampleIsBaseline || swapping || swapping != isDesktopSwapping
		isDesktopSwapping = swapping
		previousWindowBodies = startsAfresh ? bodies : windowBodies
		nextBodySampleIsBaseline = false
		windowBodies = bodies
		bodySampleElapsed = elapsed
		bodyRefreshVersion += 1
	}

	/// Which window is hiding the pet, if any. See ``WindowOcclusionPolicy``.
	public func coveringWindow(of owner: UInt32, body: PixelRect) -> UInt32? {
		WindowOcclusionPolicy.coveringWindow(of: owner, her: body, among: windowBodies)
	}

	/// Whether the window is on the desktop the user is looking at.
	///
	/// Presence in the body sample answers this exactly, and for free: the sample is
	/// taken with `.optionOnScreenOnly`, which leaves out the windows of every other
	/// Space — verified with a probe, together with the fact that it is the *only*
	/// signal that says so. Switching Spaces moves the desktop, not the window: its
	/// rectangle is unchanged, the public and the private live reads both go on
	/// reporting that same rectangle, and the only difference in the window's entry is
	/// a missing `kCGWindowIsOnscreen`.
	///
	/// So this is deliberately not a geometric question. "Is it inside a display" says
	/// yes for a window she can no longer be seen on, which is how she used to stay
	/// inside a box on the desk the user had left.
	public func isOnThisDesktop(_ windowID: UInt32) -> Bool {
		windowBodies[windowID] != nil
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
