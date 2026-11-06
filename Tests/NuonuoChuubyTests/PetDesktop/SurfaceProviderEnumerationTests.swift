import Foundation
import Testing

@testable import PetDesktop
@testable import PetFoundation

/// How many times the window server is asked for the list, which is the whole point
/// of two readers sharing one enumeration.
///
/// A wrapper rather than a change to ``MockPlatform``: the count is the subject here,
/// and a mock that counted its own calls would be a mock with a second job.
@MainActor
private final class CountingPlatform: Platform {
	private let scriptedWindows: [PlatformWindow]
	private let scriptedMonitors: [Monitor]
	private(set) var enumerationCount = 0

	init(windows: [PlatformWindow], monitors: [Monitor]) {
		self.scriptedWindows = windows
		self.scriptedMonitors = monitors
	}

	func windows() -> [PlatformWindow] {
		enumerationCount += 1
		return scriptedWindows.enumerated().map { index, window in
			var window = window
			window.zIndex = index
			return window
		}
	}

	func monitors() -> [Monitor] { scriptedMonitors }
}

/// The graph rebuild (2 Hz) and the body sample (10 Hz) want the same window list,
/// and the graph's own enumeration of it was the redundant one.
@MainActor
@Suite("Window enumeration sharing")
struct SurfaceProviderEnumerationTests {
	private static let monitor = Monitor(
		id: 1,
		frame: PixelRect(x: 0, y: 0, width: 1728, height: 1117),
		visibleFrame: PixelRect(x: 0, y: 25, width: 1728, height: 1092),
		scale: 1
	)

	private static let window = PlatformWindow(
		id: 4242,
		ownerPID: 900,
		bounds: PixelRect(x: 200, y: 300, width: 600, height: 400),
		layer: 0,
		alpha: 1
	)

	private func makeProvider() -> (SurfaceProvider, CountingPlatform, DisplaySpace) {
		let platform = CountingPlatform(windows: [Self.window], monitors: [Self.monitor])
		let space = DisplaySpace(monitors: [Self.monitor], primaryHeight: 1117)
		return (SurfaceProvider(platform: platform), platform, space)
	}

	/// One tick at 60 Hz, at which either reader may or may not be due — in the order
	/// the simulation calls them.
	private func tick(_ provider: SurfaceProvider, _ space: DisplaySpace) {
		provider.refreshIfStale(displaySpace: space, delta: 1.0 / 60)
		provider.sampleBodiesIfStale(displaySpace: space, delta: 1.0 / 60)
	}

	@Test("A graph rebuild is served from the list the body sample just took")
	func theGraphReusesTheSamplesList() {
		let (provider, platform, space) = makeProvider()
		// One second at 60 Hz: ten body samples at 10 Hz, two graph rebuilds at 2 Hz.
		// The rebuilds are the ticks where both readers are due, and the sample's list is
		// the same instant's worth of information the graph would read for itself.
		for _ in 0..<60 { tick(provider, space) }

		// One enumeration per sample, plus the very first rebuild's own — there was no
		// list to be offered then. A rebuild that enumerated for itself would put this
		// at `bodyRefreshVersion + 2`.
		#expect(
			platform.enumerationCount == provider.bodyRefreshVersion + 1,
			"\(platform.enumerationCount) enumerations for \(provider.bodyRefreshVersion) samples"
		)
		#expect(provider.surfaces.contains { $0.key.kind == .windowTop })
	}

	@Test("An event-driven rebuild enumerates, so it is never built from an old sample")
	func aForcedRefreshEnumerates() {
		let (provider, platform, space) = makeProvider()
		provider.sampleBodiesIfStale(displaySpace: space, delta: 0.1)
		let before = platform.enumerationCount

		provider.refresh(displaySpace: space)

		#expect(
			platform.enumerationCount == before + 1,
			"the end of a drag, and the end of a fall, are asked fresh"
		)
	}

	@Test("A list no sample has refreshed stops being reused")
	func theListExpiresWithoutSamples() {
		let (provider, platform, space) = makeProvider()
		provider.sampleBodiesIfStale(displaySpace: space, delta: 0.1)
		provider.refreshIfStale(displaySpace: space, delta: 1.0 / 60)
		#expect(platform.enumerationCount == 1, "the rebuild was served by the sample")

		// Now the sample stops, which is what a suspended simulation looks like: only the
		// graph runs. It must not go on building from a list taken before the screen
		// locked, because its fullscreen reading is what ends a suspension.
		for _ in 0..<40 { provider.refreshIfStale(displaySpace: space, delta: 1.0 / 60) }

		#expect(
			platform.enumerationCount > 1,
			"the graph went on reusing a list no sample had refreshed"
		)
	}
}
