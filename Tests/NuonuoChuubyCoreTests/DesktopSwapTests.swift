import Foundation
import Testing

@testable import NuonuoChuubyCore

/// What a desktop looks like while Spaces are being switched.
///
/// Verified on this machine with a probe (`CGWindowListCopyWindowInfo`,
/// `.optionOnScreenOnly`): during the transition the window server reports the
/// neighbouring desks' windows as well as this one's, laid out along the strip the
/// transition slides across — `x = -5294`, `x = 2609` on a 1728-wide display — and
/// the list changes several times a second until it settles. A window on no display
/// at all therefore means "another desktop", which is what these tests are about.
@MainActor
@Suite("Space switch", .serialized)
struct DesktopSwapTests {
	private static var assetsRoot: URL? { TestAssets.root }

	enum TestSkip: Error { case missingAssets }

	private static let frame = 1.0 / 60
	private static let displayWidth: Double = 1728
	private static let displayHeight: Double = 1117

	private static let windowID: UInt32 = 7100
	/// A plain 600×400 window, comfortably larger than the pet.
	private static let box = PixelRect(x: 600, y: 600, width: 600, height: 400)

	/// A window of the neighbouring desk, as the transition reports one: off the
	/// right of the display.
	private static let neighbouring = PixelRect(x: 2609, y: 285, width: 860, height: 594)

	private static func window(id: UInt32, bounds: PixelRect) -> PlatformWindow {
		PlatformWindow(
			id: id,
			ownerPID: 4242,
			ownerName: "Safari",
			bounds: bounds,
			layer: 0,
			alpha: 1
		)
	}

	private struct Rig {
		var controller: PetController
		var provider: SurfaceProvider
		var platform: MockPlatform
		var space: DisplaySpace
		var directory: URL
	}

	private func makeRig() throws -> Rig {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-swap-\(UUID().uuidString)")

		let platform = MockPlatform.singleMonitor(
			width: Self.displayWidth,
			height: Self.displayHeight
		)
		platform.setWindows([Self.window(id: Self.windowID, bounds: Self.box)])
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: Self.displayHeight)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: provider,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space,
			randomSeed: TestAssets.randomSeed
		)
		// Left to act on her own she would walk off the edge the test is about.
		controller.quietMode = true
		// The live read and the sampled bodies answer from the same place, as they
		// would on a real desktop.
		controller.debugLiveWindowBoundsOverride = { [weak provider] id in
			provider?.windowBodies[id]?.bounds
		}
		return Rig(
			controller: controller,
			provider: provider,
			platform: platform,
			space: space,
			directory: directory
		)
	}

	private func advance(_ rig: Rig, seconds: Double) {
		var remaining = seconds
		while remaining > 0 {
			rig.controller.debugStep(delta: min(Self.frame, remaining))
			remaining -= Self.frame
		}
	}

	/// Puts her on the window's top edge, as landing on it would.
	private func standOnTheWindow(_ rig: Rig) throws {
		let surface = try #require(
			rig.provider.surfaces.first { $0.key == SurfaceKey(owner: Self.windowID, kind: .windowTop) }
		)
		rig.controller.debugPlaceOnSurface(surface)
		advance(rig, seconds: 0.5)
		#expect(rig.controller.debugState.state == .idle)
	}

	// MARK: - Which windows are on this desktop

	@Test("A gap in the middle of a transition does not hand her back to the simulation")
	func aGapInTheSignalDoesNotEndTheSwap() {
		// Measured shape of one gesture switch: the signal came and went four times over
		// about two seconds, because the edges of the desktop come in and out of the
		// enumeration as the gesture is steered. Releasing on the first quiet sample would
		// measure her own movement across a desktop that is still sliding.
		let platform = MockPlatform.singleMonitor(
			width: Self.displayWidth,
			height: Self.displayHeight
		)
		platform.setWindows([Self.window(id: Self.windowID, bounds: Self.box)])
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: Self.displayHeight)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		let swapping = [
			Self.window(id: Self.windowID, bounds: Self.box),
			Self.window(id: 7101, bounds: Self.neighbouring),
		]
		let settled = [Self.window(id: Self.windowID, bounds: Self.box)]

		for round in 0..<4 {
			platform.setWindows(swapping)
			provider.sampleBodiesIfStale(displaySpace: space, delta: 0.1)
			#expect(provider.isDesktopSwapping, "the swap did not start in round \(round)")

			platform.setWindows(settled)
			provider.sampleBodiesIfStale(displaySpace: space, delta: 0.1)
			#expect(provider.isDesktopSwapping, "released by one quiet sample in round \(round)")
		}

		for _ in 0..<4 { provider.sampleBodiesIfStale(displaySpace: space, delta: 0.1) }
		#expect(!provider.isDesktopSwapping, "and it does end once the desktop has settled")
	}

	@Test("A window on no display is not terrain, and marks the desktop as being swapped")
	func offDisplayWindowIsNotTerrain() {
		let platform = MockPlatform.singleMonitor(
			width: Self.displayWidth,
			height: Self.displayHeight
		)
		platform.setWindows([Self.window(id: Self.windowID, bounds: Self.box)])
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: Self.displayHeight)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		#expect(!provider.isDesktopSwapping)
		#expect(provider.surfaces.contains { $0.key.owner == Self.windowID })

		platform.setWindows([
			Self.window(id: Self.windowID, bounds: Self.box),
			Self.window(id: 7101, bounds: Self.neighbouring),
			// The other direction: the desk that has slid off to the left.
			Self.window(id: 7102, bounds: PixelRect(x: -3200, y: 251, width: 1054, height: 787)),
		])
		provider.refresh(displaySpace: space)
		provider.sampleBodiesIfStale(displaySpace: space, delta: 0.2)

		#expect(provider.isDesktopSwapping, "the neighbouring desks are in the list")
		#expect(provider.surfaces.allSatisfy { $0.key.owner != 7101 && $0.key.owner != 7102 })
		#expect(provider.windowBodies[7101] == nil)
		#expect(provider.windowBodies[7102] == nil)
		#expect(
			provider.windowBodies[Self.windowID] != nil,
			"a window that is still on the display is still hers to stand on"
		)
	}

	@Test("Nothing is measured across a swap, so no edge appears to sweep past her")
	func swapIsNotAWindowMoving() {
		let platform = MockPlatform.singleMonitor(
			width: Self.displayWidth,
			height: Self.displayHeight
		)
		platform.setWindows([Self.window(id: Self.windowID, bounds: Self.box)])
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: Self.displayHeight)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)
		provider.sampleBodiesIfStale(displaySpace: space, delta: 0.2)

		// The whole desktop slides a thousand points, which as a cross-frame
		// difference is an edge moving far faster than any drag.
		platform.setWindows([
			Self.window(
				id: Self.windowID,
				bounds: PixelRect(x: Self.box.x - 1000, y: Self.box.y, width: 600, height: 400)
			),
			Self.window(id: 7101, bounds: Self.neighbouring),
		])
		provider.sampleBodiesIfStale(displaySpace: space, delta: 0.2)

		#expect(
			provider.previousWindowBodies == provider.windowBodies,
			"the sample that notices a swap starts from itself"
		)
	}

	@Test("A desktop slid with every window still on the display is still a swap")
	func aSlideWhoseWindowsAllStayOnDisplayIsASwap() {
		// The case a shortcut switch produces: the strip is never reported, so nothing
		// is off the display, but the two windows on it are being dragged sideways
		// together — which no hand can do.
		let platform = MockPlatform.singleMonitor(
			width: Self.displayWidth,
			height: Self.displayHeight
		)
		let left = PixelRect(x: 100, y: 200, width: 600, height: 400)
		let right = PixelRect(x: 900, y: 300, width: 600, height: 400)
		platform.setWindows([
			Self.window(id: 7201, bounds: left),
			Self.window(id: 7202, bounds: right),
		])
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: Self.displayHeight)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)
		provider.sampleBodiesIfStale(displaySpace: space, delta: 0.2)
		#expect(!provider.isDesktopSwapping)

		// Both step by the same 400 pt, and stay on the display while doing it.
		for step in 1...3 {
			let shift = -400 * Double(step) / 3
			platform.setWindows([
				Self.window(
					id: 7201,
					bounds: PixelRect(x: left.x + shift, y: left.y, width: 600, height: 400)
				),
				Self.window(
					id: 7202,
					bounds: PixelRect(x: right.x + shift, y: right.y, width: 600, height: 400)
				),
			])
			provider.sampleBodiesIfStale(displaySpace: space, delta: 0.1)
			#expect(provider.windowBodies.count == 2, "both are still on the display")
		}

		#expect(provider.isDesktopSwapping, "two windows moving together is the desktop")
	}

	@Test("A window dragged off the display is no longer a surface")
	func draggedOffTheDisplayIsGone() {
		let platform = MockPlatform.singleMonitor(
			width: Self.displayWidth,
			height: Self.displayHeight
		)
		platform.setWindows([Self.window(id: Self.windowID, bounds: Self.box)])
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: Self.displayHeight)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)
		#expect(provider.surfaces.contains { $0.key.owner == Self.windowID })

		platform.setWindows([
			Self.window(
				id: Self.windowID,
				bounds: PixelRect(x: -Self.displayWidth, y: Self.box.y, width: 600, height: 400)
			)
		])
		provider.refresh(displaySpace: space)
		#expect(!provider.surfaces.contains { $0.key.owner == Self.windowID })
	}

	// MARK: - Standing on a window

	@Test("While the desktop is swapped she holds still, on the spot she was on")
	func sheHoldsStillDuringTheSwap() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		try standOnTheWindow(rig)

		let before = rig.controller.debugState

		// The neighbouring desk slides in beside this one, several times, and every
		// window edge the transition shows sweeps far past her.
		for step in 0..<6 {
			let sliding = PixelRect(
				x: Double(step) * 400 - 800,
				y: Self.box.y,
				width: 600,
				height: 400
			)
			rig.platform.setWindows([
				Self.window(id: Self.windowID, bounds: sliding),
				Self.window(id: 7101, bounds: Self.neighbouring),
			])
			advance(rig, seconds: 0.15)
		}

		let during = rig.controller.debugState
		#expect(rig.provider.isDesktopSwapping)
		#expect(during.state == .idle, "she was thrown by the transition, into \(during.state)")
		#expect(during.foot == before.foot, "she moved with the desktop")
		#expect(during.velocityX == 0, "she was given a sideways speed")
	}

	@Test("When the swap ends without her window, she falls straight down to the floor")
	func sheFallsVerticallyOnceTheDeskHasChanged() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		try standOnTheWindow(rig)
		let start = rig.controller.debugState.foot

		rig.platform.setWindows([
			Self.window(id: Self.windowID, bounds: Self.box),
			Self.window(id: 7101, bounds: Self.neighbouring),
		])
		advance(rig, seconds: 0.4)
		#expect(rig.provider.isDesktopSwapping)

		// This desk has no window under her at that height.
		rig.platform.setWindows([])
		advance(rig, seconds: 3)

		let ended = rig.controller.debugState
		let floor = try #require(rig.space.displays.first?.visibleFrame.bottom)
		#expect(ended.state == .idle, "she never settled, she is \(ended.state)")
		#expect(abs(ended.foot.y - floor) < 1, "she is at \(Int(ended.foot.y)), not on the floor")
		#expect(abs(ended.foot.x - start.x) < 1, "she drifted sideways by \(ended.foot.x - start.x) pt")
	}

	@Test("A window parked off screen for good holds her once, then is let go")
	func aPermanentOffScreenWindowDoesNotEmptyTheSession() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		try standOnTheWindow(rig)

		// Never goes away again, which is what an application that parks a window
		// off screen looks like. The cap has to end the episode, or she would stand
		// there for the rest of the session.
		rig.platform.setWindows([Self.window(id: 7101, bounds: Self.neighbouring)])
		advance(rig, seconds: 8)

		let floor = try #require(rig.space.displays.first?.visibleFrame.bottom)
		let ended = rig.controller.debugState
		#expect(rig.provider.isDesktopSwapping, "the window is still there to be seen")
		#expect(
			abs(ended.foot.y - floor) < 1,
			"she never resumed: \(Int(ended.foot.y)) with the floor at \(Int(floor))"
		)
	}

	// MARK: - Inside a window

	/// Puts her inside the scripted window, by letting go of her wholly within it.
	private func sitInsideTheWindow(_ rig: Rig) {
		rig.provider.sampleBodiesIfStale(displaySpace: rig.space, delta: 0.2)
		rig.controller.beginDrag(at: rig.controller.debugState.foot)
		rig.controller.updateDrag(to: PixelPoint(x: 900, y: 900))
		rig.controller.endDrag(at: PixelPoint(x: 900, y: 900))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)

		var remaining = 5.0
		while remaining > 0 {
			_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)
			remaining -= Self.frame
		}
		#expect(rig.controller.debugState.state == .idle, "she should be resting on the floor")
	}

	@Test("A box on another desktop lets her go, without a sideways speed")
	func boxOnAnotherDesktopLetsHerGo() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		sitInsideTheWindow(rig)

		// Nothing about the window changes: measured on this machine, a window left
		// behind by a Space switch keeps its rectangle to the point, and both the
		// public and the private live reads go on reporting it. What changes is that
		// it drops out of the on-screen enumeration — so the sample is what has to
		// say she is no longer in a box she can be seen in.
		rig.platform.setWindows([])
		rig.provider.sampleBodiesIfStale(displaySpace: rig.space, delta: 0.2)
		#expect(!rig.provider.isOnThisDesktop(Self.windowID))

		// A resting box is only read every other frame, so the first frame that sees
		// this may still be using the rectangle from before it.
		for _ in 0..<4 where rig.controller.debugState.enclosureWindowID != nil {
			_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)
		}

		let state = rig.controller.debugState
		#expect(state.enclosureWindowID == nil, "she is still held by a window on another desk")
		#expect(state.state == .falling)
		#expect(state.velocityX == 0)
	}

	@Test("A box slid wholly off the display lets her go too")
	func boxSlidOffTheDisplayLetsHerGo() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		sitInsideTheWindow(rig)

		// The other way a box stops being hers: the transition drags it out of the
		// display, so it is not somewhere she could be seen standing even though the
		// sample still has it.
		rig.controller.debugLiveWindowBoundsOverride = { _ in
			PixelRect(
				x: -Self.displayWidth,
				y: Self.box.y,
				width: Self.box.width,
				height: Self.box.height
			)
		}

		for _ in 0..<4 where rig.controller.debugState.enclosureWindowID != nil {
			_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)
		}

		let state = rig.controller.debugState
		#expect(state.enclosureWindowID == nil)
		#expect(state.state == .falling)
		#expect(state.velocityX == 0)
	}

	// MARK: - Standing on a window

	@Test("Standing on a window of another desktop, she falls to this one's floor")
	func standingOnAWindowOfAnotherDesktopDropsHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		try standOnTheWindow(rig)
		let start = rig.controller.debugState.foot

		// The desk she is on loses the window; the live read would happily keep
		// answering for it, because its rectangle has not moved at all.
		rig.platform.setWindows([])
		advance(rig, seconds: 3)

		let ended = rig.controller.debugState
		let floor = try #require(rig.space.displays.first?.visibleFrame.bottom)
		#expect(
			ended.perchKey?.owner != Self.windowID,
			"she is still anchored to a window on another desk"
		)
		#expect(abs(ended.foot.y - floor) < 1, "she is at \(Int(ended.foot.y)), not on the floor")
		#expect(abs(ended.foot.x - start.x) < 1, "she drifted sideways by \(ended.foot.x - start.x) pt")
	}
}
