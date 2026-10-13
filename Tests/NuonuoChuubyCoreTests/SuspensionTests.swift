import Foundation
import ImageIO
import Testing

@testable import NuonuoChuubyCore

/// A fullscreen app in front of everything, and the display going away.
///
/// Both suspend her, and while suspended nothing advances — the animator included,
/// which is what used to leave her frozen mid-frame and apparently broken.
@MainActor
@Suite("Suspension", .serialized)
struct SuspensionTests {
	private final class DelegateSpy: PetControllerDelegate {
		var suspensions: [Bool] = []
		var frames = 0
		func petController(_ controller: PetController, didProduceFrame image: CGImage) {
			frames += 1
		}
		func petControllerDidChangePlacement(_ controller: PetController) {}
		func petControllerDidRequestMenu(_ controller: PetController) {}
		func petController(_ controller: PetController, didChangeSuspension suspended: Bool) {
			suspensions.append(suspended)
		}
	}

	private static var assetsRoot: URL? { TestAssets.root }

	enum TestSkip: Error { case missingAssets }

	private static let frame = 1.0 / 60
	/// The graph is rebuilt every half second, so a change takes that long to land.
	private static let framesPerRefresh = 40

	private struct Rig {
		var controller: PetController
		var platform: MockPlatform
		var spy: DelegateSpy
		var directory: URL
	}

	private func makeRig() throws -> Rig {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-suspend-\(UUID().uuidString)")

		let platform = MockPlatform.singleMonitor(width: 1728, height: 1117)
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: 1117)
		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: SurfaceProvider(platform: platform),
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space
		)
		let spy = DelegateSpy()
		controller.delegate = spy
		// Let the graph settle before anything is asserted about it.
		step(controller, frames: Self.framesPerRefresh)
		return Rig(controller: controller, platform: platform, spy: spy, directory: directory)
	}

	private func step(_ controller: PetController, frames: Int) {
		for _ in 0..<frames { controller.debugStep(delta: Self.frame) }
	}

	private func run(_ rig: Rig, frames: Int) {
		step(rig.controller, frames: frames)
	}

	/// A window covering the whole display, which is what fullscreen means here: a
	/// maximised window stops at the menu bar and does not count.
	private func fullscreenWindow() -> PlatformWindow {
		PlatformWindow(
			id: 7001,
			ownerPID: 4242,
			ownerName: "Keynote",
			bounds: PixelRect(x: 0, y: 0, width: 1728, height: 1117),
			layer: 0,
			alpha: 1
		)
	}

	@Test("A fullscreen app suspends her, and its departure resumes her")
	func fullscreenSuspendsAndResumes() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		#expect(!rig.controller.isSuspended)
		#expect(rig.spy.suspensions.isEmpty, "nothing has suspended her yet")

		rig.platform.setWindows([fullscreenWindow()])
		run(rig, frames: Self.framesPerRefresh)
		#expect(rig.controller.isSuspended)
		#expect(rig.spy.suspensions == [true], "she must be told, so she can be hidden")

		// Straight to fullscreen and back again must not report anything twice.
		run(rig, frames: Self.framesPerRefresh)
		#expect(rig.spy.suspensions == [true])

		rig.platform.setWindows([])
		run(rig, frames: Self.framesPerRefresh)
		#expect(!rig.controller.isSuspended)
		#expect(rig.spy.suspensions == [true, false], "and told that she is back")
	}

	@Test("Losing every display suspends her too")
	func noDisplaySuspends() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// What the display-change notification does in the running app.
		rig.platform.setMonitors([])
		rig.controller.updateDisplaySpace(DisplaySpace(monitors: [], primaryHeight: 0))
		run(rig, frames: 2)

		#expect(rig.controller.isSuspended)
		#expect(rig.spy.suspensions == [true])
	}

	@Test("A window that moved while she was away does not hit her on the way back")
	func resumingDoesNotFlingHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		// Standing still, so her body stays where it can be measured.
		rig.controller.quietMode = true

		let her = rig.controller.debugBodyRect()

		// A window beside her whose right edge has not yet reached her, covering the
		// height her body occupies so that edge sweeping right would be a hit.
		func besideHer(right: Double) -> PlatformWindow {
			PlatformWindow(
				id: 7002,
				ownerPID: 4242,
				ownerName: "Finder",
				bounds: PixelRect(
					x: right - 600,
					y: her.top - 100,
					width: 600,
					height: her.height + 200
				),
				layer: 0,
				alpha: 1
			)
		}
		rig.platform.setWindows([besideHer(right: her.left - 40)])
		run(rig, frames: Self.framesPerRefresh)
		#expect(
			rig.controller.debugState.fallReason != "WindowSideImpact",
			"it has not reached her yet"
		)

		// Away: the fullscreen app comes up, and while she is behind it the desktop is
		// rearranged so that edge ends up past her. The difference spans the whole
		// suspension while the sampler still believes the samples are 0.1 s apart.
		rig.platform.setWindows([fullscreenWindow(), besideHer(right: her.left - 40)])
		run(rig, frames: Self.framesPerRefresh)
		#expect(rig.controller.isSuspended)

		rig.platform.setWindows([fullscreenWindow(), besideHer(right: her.left + 60)])
		run(rig, frames: Self.framesPerRefresh)
		#expect(rig.controller.isSuspended, "she is still behind the fullscreen app")

		// Leaving fullscreen exposes her again, with the window wherever it now is.
		rig.platform.setWindows([besideHer(right: her.left + 60)])
		run(rig, frames: Self.framesPerRefresh)
		#expect(!rig.controller.isSuspended, "the fullscreen app has gone")

		let state = rig.controller.debugState
		#expect(
			state.fallReason != "WindowSideImpact",
			"a window that moved while she was away was read as sweeping through her"
		)
		#expect(
			abs(state.velocityX) < 230,
			"and threw her sideways at \(Int(state.velocityX)) pt/s"
		)
	}

	@Test("Coming back from a fullscreen app leaves her standing where she was")
	func resumingKeepsHerFooting() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		// Standing still, so the only thing that can move her is the suspension.
		rig.controller.quietMode = true

		#expect(rig.controller.debugState.perchKey?.kind == .floor)
		let restingFoot = rig.controller.debugState.foot

		rig.platform.setWindows([fullscreenWindow()])
		run(rig, frames: Self.framesPerRefresh)
		#expect(rig.controller.isSuspended)

		// The work area is what the floor is measured from, and a fullscreen app
		// takes the menu bar and the Dock away, so it can arrive back larger or
		// smaller than it left.
		rig.controller.updateDisplaySpace(
			DisplaySpace(monitors: [monitor(visibleFrame: grownWorkArea)], primaryHeight: 1117)
		)
		run(rig, frames: 30)
		#expect(rig.controller.isSuspended, "still behind the fullscreen app")

		rig.platform.setWindows([])
		rig.controller.updateDisplaySpace(
			DisplaySpace(monitors: [monitor(visibleFrame: normalWorkArea)], primaryHeight: 1117)
		)
		run(rig, frames: 2)

		// A floor that moved while nothing was simulated must not be read as a yank.
		let state = rig.controller.debugState
		#expect(
			state.state != .falling,
			"the floor moving while she was suspended threw her (vy=\(state.velocityY))"
		)
		#expect(state.velocityY > -100, "and did not launch her")

		run(rig, frames: 30)
		#expect(rig.controller.debugState.perchKey?.kind == .floor)
		#expect(
			abs(rig.controller.debugState.foot.y - normalWorkArea.bottom) < 1,
			"expected her on the floor at \(Int(normalWorkArea.bottom)), found \(Int(rig.controller.debugState.foot.y))"
		)
		#expect(
			abs(rig.controller.debugState.foot.x - restingFoot.x) < 1,
			"and where she was standing across the screen"
		)
	}

	/// A display whose Dock takes a strip off the bottom, so the floor is not at the
	/// bottom of the screen.
	private var normalWorkArea: PixelRect { PixelRect(x: 85, y: 25, width: 1643, height: 1007) }

	/// The same display with the Dock hidden, as fullscreen leaves it.
	private var grownWorkArea: PixelRect { PixelRect(x: 0, y: 0, width: 1728, height: 1117) }

	private func monitor(visibleFrame: PixelRect) -> Monitor {
		Monitor(
			id: 1,
			frame: PixelRect(x: 0, y: 0, width: 1728, height: 1117),
			visibleFrame: visibleFrame,
			scale: 1
		)
	}

	@Test("Suspended, she neither moves nor animates")
	func suspendedIsFrozen() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.platform.setWindows([fullscreenWindow()])
		run(rig, frames: Self.framesPerRefresh)
		#expect(rig.controller.isSuspended)

		// The frames are the whole point: they used to keep being drawn from a
		// standing start, so she was left frozen on one of them — visible over the
		// fullscreen app, which is what made it look broken.
		let foot = rig.controller.debugState.foot
		let framesProduced = rig.spy.frames
		run(rig, frames: 120)
		#expect(rig.controller.debugState.foot == foot, "she should not have moved")
		#expect(rig.spy.frames == framesProduced, "and the animation should have stopped")

		// Dragging still answers, which is why the freeze was noticeable rather than
		// looking like a dead app: one frame changes, and then it stops again.
		rig.controller.beginDrag(at: rig.controller.debugState.foot)
		rig.controller.updateDrag(to: PixelPoint(x: 300, y: 300))
		rig.controller.endDrag(at: PixelPoint(x: 300, y: 300))
		run(rig, frames: 30)
		#expect(
			rig.controller.debugState.foot.y == 300,
			"the drag moved her, and the simulation did not take her on from there"
		)
	}
}
