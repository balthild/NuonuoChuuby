import Foundation
import Testing

@testable import PetBehaviour
@testable import PetDesktop
@testable import PetFoundation
@testable import PetMedia
@testable import PetSimulation

/// What she is ticked at, and why it is not always the same.
///
/// While she sleeps in the `sleep` loop nothing on screen changes faster than the clip
/// itself — 8 frames at 0.185 s — so the tick drops to 10 Hz and a tenth of the frames
/// are composited. The tests below pin the three things that make that safe: the clips
/// either side of the loop are left out, the rate comes back the moment anything happens
/// to her, and the animation keeps its own speed at the slower tick.
@MainActor
@Suite("Sleep tick rate", .serialized)
struct SleepTickRateTests {
	private static var assetsRoot: URL? { TestAssets.root }
	private static let frame = 1.0 / 60
	private static let windowID: UInt32 = 4242
	private static let windowTop: Double = 800

	enum TestSkip: Error { case missingAssets }

	private struct Rig {
		var controller: PetController
		var provider: SurfaceProvider
		var platform: MockPlatform
		var directory: URL
	}

	private func window(bounds: PixelRect) -> PlatformWindow {
		PlatformWindow(id: Self.windowID, ownerPID: 900, bounds: bounds, layer: 0, alpha: 1)
	}

	private func windowBounds(top: Double) -> PixelRect {
		PixelRect(x: 200, y: top, width: 1200, height: 400)
	}

	private func windowSurface(top: Double) -> Surface {
		Surface(
			key: SurfaceKey(owner: Self.windowID, kind: .windowTop),
			span: Span(start: 200, end: 1400),
			visible: [Span(start: 200, end: 1400)],
			offset: top,
			ownerBounds: windowBounds(top: top),
			isReachable: true
		)
	}

	/// A controller over a scripted desktop, quiet so she does nothing of her own accord.
	///
	/// `onWindow` stands her on a window top rather than the floor, because a window is
	/// the only thing that can carry her while she sleeps — the case the rate has to
	/// answer to. It is set up the way a real one is, with the platform reporting it, so
	/// the periodic graph rebuild keeps the surface she is on.
	private func makeRig(onWindow: Bool = false) throws -> Rig {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-sleeptick-\(UUID().uuidString)")

		let platform = MockPlatform.singleMonitor(width: 1728, height: 1117)
		if onWindow {
			platform.setWindows([window(bounds: windowBounds(top: Self.windowTop))])
		}
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: 1117)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: provider,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space,
			randomSeed: TestAssets.randomSeed
		)
		controller.quietMode = true
		if onWindow {
			let surface = try #require(provider.surfaces.first { $0.key.kind == .windowTop })
			controller.debugPlaceOnSurface(surface)
		}
		return Rig(
			controller: controller,
			provider: provider,
			platform: platform,
			directory: directory
		)
	}

	private func step(_ rig: Rig, frames: Int, delta: Double = SleepTickRateTests.frame) {
		for _ in 0..<frames { rig.controller.debugStep(delta: delta) }
	}

	/// Sleeps her with a nap long enough not to end under the test, and drives her on
	/// until the `sleep` loop is playing and she has been still for a second.
	private func sleepInTheLoop(_ rig: Rig) {
		rig.controller.life.sleepiness = 60
		rig.controller.beginSleep()
		rig.controller.sleepRemaining = 60
		step(rig, frames: 80)
	}

	@Test("The lie-down clip is left at the ordinary rate")
	func theSleepEnterClipIsTickedFast() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.life.sleepiness = 60
		rig.controller.beginSleep()
		rig.controller.sleepRemaining = 60
		step(rig, frames: 6)

		// A tenth of a second in she is still lying down, and `sleep_enter`'s frames are
		// 0.145 s — a 0.1 s tick cannot land those evenly, so it stays fast.
		#expect(rig.controller.state == .sleeping)
		#expect(rig.controller.animator.currentClip == "sleep_enter")
		#expect(rig.controller.wantedTickInterval == PetController.awakeTickInterval)
	}

	@Test("The sleep loop is ticked slowly once she has been still")
	func theSleepLoopIsTickedSlowly() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		sleepInTheLoop(rig)
		#expect(rig.controller.animator.currentClip == "sleep")
		#expect(rig.controller.state == .sleeping)

		// The lie-down is a second and a bit of her not moving, so by the time the loop
		// starts the stillness the slow rate needs has already accumulated — which is the
		// point of measuring stillness rather than the clip alone.
		#expect(rig.controller.wantedTickInterval == PetController.sleepingTickInterval)
		rig.controller.updateTickRate()
		#expect(rig.controller.tickIntervalSeconds == PetController.sleepingTickInterval)
	}

	@Test("The sleep loop keeps its own speed at the slow tick")
	func theSleepLoopKeepsItsSpeed() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		sleepInTheLoop(rig)
		step(rig, frames: 70)
		rig.controller.updateTickRate()
		#expect(rig.controller.tickIntervalSeconds == PetController.sleepingTickInterval)

		let before = rig.controller.animator.elapsedSeconds
		step(rig, frames: 10, delta: PetController.sleepingTickInterval)
		let advanced = rig.controller.animator.elapsedSeconds - before

		// A second of ticks has to advance a second of animation. With the ordinary
		// 0.05 s cap it would advance half of one, and the sleep loop would breathe at
		// half speed for as long as she slept.
		#expect(abs(advanced - 1) < 0.05, "the clip advanced \(advanced) s in a second of ticks")
	}

	@Test("An awake still rest is ticked slowly, because its clip is a loop")
	func theAwakeIdleLoopIsTickedSlowly() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// `returnToIdle` re-seeds the idle timer to 1.2 s at its shortest, so for the 61
		// frames below no decision comes round and she is still resting awake. Asserting on
		// a state she reached by a weighted draw would be a coin flip, and a low sleepiness
		// is not enough on its own to keep her awake (see `performance.md`, "测 idle 前先把
		// 她的状态钉死").
		rig.controller.life.sleepiness = 0
		rig.controller.returnToIdle()
		step(rig, frames: 61)

		#expect(rig.controller.state == .idle)
		#expect(rig.controller.animator.currentClip == "idle")
		// The clip is what makes this safe: a loop the render server can hold, so the tick
		// no longer owns the frames and may be as coarse as it likes.
		#expect(
			rig.controller.animator.currentLoop != nil,
			"idle is a loop, so it is handed over rather than stepped"
		)
		#expect(
			rig.controller.wantedTickInterval == PetController.sleepingTickInterval,
			"an awake still rest should cost what a sleep costs"
		)
		rig.controller.updateTickRate()
		#expect(rig.controller.tickIntervalSeconds == PetController.sleepingTickInterval)
	}

	@Test("A hand on her brings the ordinary rate back at once")
	func grabbingHerTicksFastAgain() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		sleepInTheLoop(rig)
		step(rig, frames: 70)
		rig.controller.updateTickRate()
		#expect(rig.controller.tickIntervalSeconds == PetController.sleepingTickInterval)

		// She can be picked up asleep, and the drag has to be drawn at the ordinary rate
		// from the first frame of it — not a tenth of a second later.
		rig.controller.beginDrag(at: rig.controller.foot)

		#expect(rig.controller.state == .dragging)
		#expect(rig.controller.tickIntervalSeconds == PetController.awakeTickInterval)
	}

	@Test("Waking brings the ordinary rate back at once")
	func wakingTicksFastAgain() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		sleepInTheLoop(rig)
		step(rig, frames: 70)
		rig.controller.updateTickRate()
		#expect(rig.controller.tickIntervalSeconds == PetController.sleepingTickInterval)

		// The nap ends by itself: her sleepiness is spent, so the countdown ends it.
		rig.controller.life.sleepiness = 0
		rig.controller.sleepRemaining = 0
		rig.controller.debugStep(delta: Self.frame)

		#expect(rig.controller.state == .waking)
		#expect(rig.controller.tickIntervalSeconds == PetController.awakeTickInterval)
	}

	@Test("A window carrying her brings the ordinary rate back")
	func aWindowCarryingHerKeepsHerFast() throws {
		let rig = try makeRig(onWindow: true)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		sleepInTheLoop(rig)
		#expect(rig.controller.tickIntervalSeconds == PetController.awakeTickInterval)
		rig.controller.updateTickRate()
		#expect(rig.controller.tickIntervalSeconds == PetController.sleepingTickInterval)

		// The window she is asleep on is moved. Nothing about her state changes — she is
		// asleep and stays asleep — but she rides it, so she is being moved, and a slow
		// tick would draw her stepping along the window instead of riding it.
		//
		// The graph is moved as well as the platform, because that is where a scripted
		// window comes from: the live read is the same query in the app, and would report
		// the new rectangle on this frame.
		let moved = Self.windowTop - 5
		rig.platform.setWindows([window(bounds: windowBounds(top: moved))])
		rig.provider.setSurfaces([windowSurface(top: moved)])
		rig.controller.debugStep(delta: Self.frame)

		#expect(rig.controller.state == .sleeping)
		#expect(
			rig.controller.wantedTickInterval == PetController.awakeTickInterval,
			"she was carried, so the next tick must be an ordinary one"
		)

		// And once she stops being carried, the slow rate has to wait out the stillness
		// again rather than resuming on the next quiet frame.
		step(rig, frames: 10)
		#expect(
			rig.controller.wantedTickInterval == PetController.awakeTickInterval,
			"a tenth of a second of stillness is not a still pet"
		)
		step(rig, frames: 70)
		#expect(rig.controller.wantedTickInterval == PetController.sleepingTickInterval)
	}

	@Test("The yank threshold is a speed, so a slower tick does not read a drag as a flick")
	func aSlowTickDoesNotReadADragAsAYank() throws {
		let rig = try makeRig(onWindow: true)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// 40 pt in a tenth of a second is 400 pt/s: a quick drag, well under the
		// 900 pt/s the rule is written for. Read as a raw displacement it is nearly three
		// times the per-tick threshold, and she would be thrown off the window she is
		// asleep on.
		rig.provider.setSurfaces([windowSurface(top: Self.windowTop - 40)])
		rig.controller.debugMaintainGroundSupport(delta: 0.1)

		let ridden = rig.controller.debugState
		#expect(ridden.state != .falling, "a 400 pt/s drag is something she rides")
		#expect(ridden.perchKey?.owner == Self.windowID)

		// The same 40 pt in one ordinary frame is 2400 pt/s, and that is a flick — so the rule
		// reads as the speed it is written for rather than as a distance.
		rig.provider.setSurfaces([windowSurface(top: Self.windowTop)])
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)

		let thrown = rig.controller.debugState
		#expect(thrown.state == .falling)
		#expect(thrown.fallReason == "PlatformDownwardRelease")
	}
}
