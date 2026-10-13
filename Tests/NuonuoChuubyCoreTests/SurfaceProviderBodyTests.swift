import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The window rectangles the enclosure, the side collision and the occlusion check
/// all read, and what a gap in the simulation does to them.
@MainActor
@Suite("Window body sampling")
struct SurfaceProviderBodyTests {
	private let monitor = Monitor(
		id: 1,
		frame: PixelRect(x: 0, y: 0, width: 1728, height: 1117),
		visibleFrame: PixelRect(x: 0, y: 25, width: 1728, height: 1092),
		scale: 1
	)

	private static let windowID: UInt32 = 4242

	private func window(left: Double) -> PlatformWindow {
		PlatformWindow(
			id: Self.windowID,
			ownerPID: 900,
			ownerName: "Finder",
			bounds: PixelRect(x: left, y: 200, width: 500, height: 400),
			layer: 0,
			alpha: 1
		)
	}

	private func makeProvider(left: Double) -> (SurfaceProvider, MockPlatform, DisplaySpace) {
		let platform = MockPlatform(windows: [window(left: left)], monitors: [monitor])
		let space = DisplaySpace(monitors: [monitor], primaryHeight: 1117)
		let provider = SurfaceProvider(platform: platform)
		return (provider, platform, space)
	}

	private func sample(_ provider: SurfaceProvider, _ space: DisplaySpace) {
		provider.sampleBodiesIfStale(displaySpace: space, delta: 1.0)
	}

	@Test("A window filling the display is sampled, and marked as no container")
	func aWindowFillingTheDisplayIsSampledButNotAContainer() {
		let (provider, platform, space) = makeProvider(left: 100)
		// The display's own work area: big enough that she would be sealed against
		// the screen, so it can never hold her.
		platform.setWindows([
			PlatformWindow(
				id: 9001,
				ownerPID: 900,
				ownerName: "Keynote",
				bounds: monitor.visibleFrame,
				layer: 0,
				alpha: 1
			),
			window(left: 100),
		])
		sample(provider, space)

		let filling = provider.windowBodies[9001]
		#expect(filling != nil, "a window that cannot hold her is still in front of her")
		#expect(filling?.isEnclosureCandidate == false)

		#expect(provider.windowBodies[Self.windowID]?.isEnclosureCandidate == true)
		#expect(provider.windowBodies.enclosureCandidates.keys.sorted() == [Self.windowID])
	}

	@Test("A window too large to hold her still covers the one holding her")
	func aWindowTooLargeToHoldHerStillCoversHer() {
		let (provider, platform, space) = makeProvider(left: 100)
		sample(provider, space)

		// It comes to the front, over the window she is in.
		platform.setWindows([
			PlatformWindow(
				id: 9001,
				ownerPID: 900,
				ownerName: "Keynote",
				bounds: monitor.visibleFrame,
				layer: 0,
				alpha: 1
			),
			window(left: 100),
		])
		sample(provider, space)

		let her = PixelRect(x: 200, y: 300, width: 120, height: 140)
		#expect(
			provider.coveringWindow(of: Self.windowID, body: her) == 9001,
			"a window with no room for her still hides her"
		)
	}

	@Test("Two ordinary samples measure the movement between them")
	func ordinarySamplesMeasureMovement() {
		let (provider, platform, space) = makeProvider(left: 100)
		sample(provider, space)

		platform.setWindows([window(left: 140)])
		sample(provider, space)

		#expect(provider.previousWindowBodies[Self.windowID]?.bounds.left == 100)
		#expect(provider.windowBodies[Self.windowID]?.bounds.left == 140)
	}

	@Test("The sample after a gap is a baseline, not a step across it")
	func sampleAfterAGapIsABaseline() {
		let (provider, platform, space) = makeProvider(left: 100)
		sample(provider, space)

		// The desktop is rearranged while nothing is being simulated. A window edge
		// 400 pt away, divided by the tenth of a second the sampler still believes in,
		// is 4000 pt/s at her — a window lashing past her at the clamp.
		provider.rebaselineBodySamples()
		platform.setWindows([window(left: 500)])
		sample(provider, space)

		let previous = provider.previousWindowBodies[Self.windowID]?.bounds.left
		#expect(
			previous == 500,
			"the first sample after a gap must start from itself, but it started from \(previous ?? -1)"
		)
		#expect(
			provider.previousWindowBodies[Self.windowID]?.bounds
				== provider.windowBodies[Self.windowID]?.bounds,
			"so the gap reads as no movement at all"
		)
	}

	@Test("Movement after a gap is measured from the baseline, not from before it")
	func movementAfterAGapIsMeasuredFromTheBaseline() {
		let (provider, platform, space) = makeProvider(left: 100)
		sample(provider, space)

		provider.rebaselineBodySamples()
		platform.setWindows([window(left: 500)])
		sample(provider, space)

		// Only now does the desktop genuinely move again, and it is measured against
		// where it was when she came back.
		platform.setWindows([window(left: 510)])
		sample(provider, space)

		#expect(provider.previousWindowBodies[Self.windowID]?.bounds.left == 500)
		#expect(provider.windowBodies[Self.windowID]?.bounds.left == 510)
	}

	@Test("Nothing is reported as moving before the baseline sample arrives")
	func nothingMovesBeforeTheBaselineSample() {
		let (provider, _, space) = makeProvider(left: 100)
		sample(provider, space)

		provider.rebaselineBodySamples()

		// The collision pass reads this pair. With the earlier sample gone and the
		// next one not yet taken, there is nothing to compare — so nothing can be
		// reported as having swept at her.
		#expect(provider.previousWindowBodies.isEmpty)
	}
}
