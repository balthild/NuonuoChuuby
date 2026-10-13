import Foundation
import Testing

@testable import NuonuoChuubyCore

/// A window dragged faster than she can fall.
///
/// The release that starts a fall is decided from a **live** read of the window,
/// every frame. The landing that ends it is decided from the terrain graph, which
/// is rebuilt every half second. A window that moves far in that half second is
/// therefore judged against a position it no longer has.
@MainActor
@Suite("Airborne support", .serialized)
struct AirborneSupportTests {
	private static var assetsRoot: URL? {
		let repoRoot = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let root = repoRoot.appendingPathComponent("Sources/NuonuoChuubyCore/Resources/Assets")
		return FileManager.default.fileExists(atPath: root.path) ? root : nil
	}

	enum TestSkip: Error { case missingAssets }

	private static let frame = 1.0 / 60
	private static let windowID: UInt32 = 6060
	/// The window dragged up under her in the tests that need a second one.
	private static let otherWindowID: UInt32 = 7070

	private struct Rig {
		var controller: PetController
		var provider: SurfaceProvider
		var platform: MockPlatform
		var directory: URL
	}

	private static func window(_ top: Double, id: UInt32 = windowID) -> PlatformWindow {
		PlatformWindow(
			id: id,
			ownerPID: 4242,
			ownerName: "Safari",
			bounds: PixelRect(x: 400, y: top, width: 800, height: 400),
			layer: 0,
			alpha: 1
		)
	}

	private static func surface(_ top: Double, id: UInt32 = windowID) -> Surface {
		Surface(
			key: SurfaceKey(owner: id, kind: .windowTop),
			span: Span(start: 400, end: 1200),
			visible: [Span(start: 400, end: 1200)],
			offset: top,
			ownerBounds: PixelRect(x: 400, y: top, width: 800, height: 400),
			isReachable: true
		)
	}

	/// A rig with a real scripted desktop behind it, so a fall can be stepped.
	///
	/// `otherTop` adds a second window, the one the tests below drag up under her.
	private func makeRig(top: Double = 800, otherTop: Double? = nil) throws -> Rig {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-airborne-\(UUID().uuidString)")

		let platform = MockPlatform.singleMonitor(width: 1728, height: 1117)
		var windows = [Self.window(top)]
		if let otherTop { windows.append(Self.window(otherTop, id: Self.otherWindowID)) }
		platform.setWindows(windows)
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: 1117)
		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: provider,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space
		)
		guard let perchSurface = provider.surfaces.first(where: { $0.key.kind == .windowTop })
		else { throw TestSkip.missingAssets }
		controller.debugPlaceOnSurface(perchSurface)
		return Rig(
			controller: controller,
			provider: provider,
			platform: platform,
			directory: directory
		)
	}

	/// Drags the window to `top` over `frames`, stepping the simulation as it goes.
	///
	/// The scripted desktop and the live read both follow, as they would on a real
	/// one; the terrain graph is left to its own half-second rhythm, which is the
	/// whole point.
	/// Runs the simulation with the window at each of `tops`, one frame apiece.
	///
	/// The scripted desktop and the live read both follow the window, as they would
	/// on a real one; the terrain graph is left to its own half-second rhythm, which
	/// is the whole point.
	///
	/// Every frame is checked, including the ones long after the drag has stopped,
	/// because that is where a stale position does its damage: she is put down on an
	/// edge the window left hundreds of points ago, released again by the live read,
	/// and repeats.
	private func run(_ rig: Rig, tops: [Double]) {
		for top in tops {
			rig.platform.setWindows([Self.window(top)])
			rig.controller.debugLiveWindowSurfaceOverride = { _ in Self.surface(top) }
			rig.controller.debugStep(delta: Self.frame)

			// A window she is anchored to is where the window is.
			let state = rig.controller.debugState
			if state.perchKey?.kind == .windowTop {
				#expect(
					abs(state.foot.y - top) < 1,
					"anchored at y=\(state.foot.y) while the window's top is at \(top), as \(state.state.rawValue)"
				)
			}
		}
	}

	private func ramp(from: Double, to: Double, frames: Int) -> [Double] {
		(1...frames).map { from + (to - from) * Double($0) / Double(frames) }
	}

	private func holding(at top: Double, frames: Int) -> [Double] {
		Array(repeating: top, count: frames)
	}

	@Test("A window dragged down faster than she falls still catches her")
	func fastDownwardDragIsCaught() throws {
		let rig = try makeRig(top: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// 50 pt a frame is 3000 pt/s, far past what gravity can follow.
		run(rig, tops: ramp(from: 800, to: 1000, frames: 4) + holding(at: 1000, frames: 180))

		let state = rig.controller.debugState
		#expect(
			state.perchKey == SurfaceKey(owner: Self.windowID, kind: .windowTop),
			"she should be standing on the window, but is \(state.state) at y=\(state.foot.y)"
		)
		#expect(
			abs(state.foot.y - 1000) < 1,
			"expected her on the window's new top edge, found y=\(state.foot.y)"
		)
	}

	@Test("A window dragged up faster than she can be thrown does not swallow her")
	func fastUpwardDragDoesNotSwallowHer() throws {
		let rig = try makeRig(top: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// 30 pt a frame is 1800 pt/s. She is thrown upward at about 880 pt/s, so the
		// window overtakes her from below and she would end up inside it.
		run(rig, tops: ramp(from: 800, to: 300, frames: 20) + holding(at: 300, frames: 180))

		let state = rig.controller.debugState
		#expect(
			state.perchKey == SurfaceKey(owner: Self.windowID, kind: .windowTop),
			"she should be on the window's top edge, but is \(state.state) at y=\(state.foot.y)"
		)
		#expect(
			abs(state.foot.y - 300) < 1,
			"expected her on the window's new top edge, found y=\(state.foot.y)"
		)
		#expect(state.foot.y < 1117, "she fell straight past the window to the bottom of the display")
	}

	/// She hops off a window that is then taken away, while a second one is dragged up
	/// under her.
	///
	/// Nothing arms a window deliberately here — a hop is her own doing, not a window
	/// being yanked — so this is the discovered catcher's job alone. With the window she
	/// left gone there is nothing else below her, and the rising one moves 40 pt between
	/// graph rebuilds, which steps clean over the band the landing test looks in: she
	/// used to go straight past it to the floor.
	@Test("A window rising into her path catches her instead of being fallen through")
	func windowRisingUnderAFallingPetCatchesHer() throws {
		let rig = try makeRig(top: 300, otherTop: 400)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugBeginHop()

		var other = 400.0
		step(rig, other: other)
		for _ in 1...6 {
			other -= 40
			step(rig, other: other)
		}
		for _ in 1...200 {
			step(rig, other: other)
		}

		let state = rig.controller.debugState
		#expect(
			state.foot.y < 1117,
			"she fell straight past the rising window to the floor, at y=\(state.foot.y)"
		)
		#expect(
			state.perchKey == SurfaceKey(owner: Self.otherWindowID, kind: .windowTop),
			"she should be on the window that rose to meet her, but is \(state.state) at y=\(state.foot.y)"
		)
		#expect(
			abs(state.foot.y - other) < 1,
			"expected her on that window's top edge at y=\(other), found y=\(state.foot.y)"
		)
	}

	/// One frame with only the second window left on the desktop.
	private func step(_ rig: Rig, other: Double) {
		rig.platform.setWindows([Self.window(other, id: Self.otherWindowID)])
		rig.controller.debugLiveWindowSurfaceOverride = { _ in
			Self.surface(other, id: Self.otherWindowID)
		}
		rig.controller.debugStep(delta: Self.frame)
	}
}
