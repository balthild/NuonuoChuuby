import Foundation
import Testing

@testable import NuonuoChuubyCore

/// Drives the platform ride frame by frame.
///
/// A real drag cannot be scripted — AppleScript's `set bounds` teleports a
/// window, which is a single huge jump rather than a gesture — so the ride is
/// exercised here by moving a known surface and stepping one frame at a time.
@MainActor
@Suite("Platform ride integration", .serialized)
struct PlatformRideIntegrationTests {
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

	/// A window whose top can be moved, plus the desktop floor beneath it.
	private func makeRig(
		windowTop: Double = 800, windowID: UInt32 = 4242
	) throws -> (controller: PetController, provider: SurfaceProvider, directory: URL) {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-ride-\(UUID().uuidString)")

		let space = DisplaySpace()
		let floor = SupportSurface(
			top: space.displays.first?.visibleFrame.bottom ?? 1117,
			left: 0, right: space.displays.first?.frame.right ?? 1728,
			bottom: space.displays.first?.frame.bottom ?? 1117,
			isDesktopFloor: true, sourceID: nil)
		let provider = SurfaceProvider(
			surfaces: [makeWindow(top: windowTop, id: windowID), floor])

		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: provider,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space)
		controller.debugPlaceOnSurface(makeWindow(top: windowTop, id: windowID))
		return (controller, provider, directory)
	}

	private func makeWindow(top: Double, id: UInt32 = 4242) -> SupportSurface {
		SupportSurface(
			top: top, left: 200, right: 1400, bottom: top + 400,
			isDesktopFloor: false, sourceID: id)
	}

	private func moveWindow(_ provider: SurfaceProvider, to top: Double) {
		provider.setSurfaces([
			makeWindow(top: top),
			SupportSurface(
				top: provider.surfaces.first(where: \.isDesktopFloor)?.top ?? 1117,
				left: 0, right: 1728, bottom: 1117, isDesktopFloor: true, sourceID: nil),
		])
	}

	@Test("A fast upward drag throws her off the window")
	func fastUpwardLaunch() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// A drag carries the window up 200 pt in a single frame, which is far past
		// the threshold that should fling her rather than carry her.
		moveWindow(rig.provider, to: 600)
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)

		let state = rig.controller.debugState
		#expect(state.state == .falling)
		#expect(state.fallReason == "PlatformLaunch")
		// Thrown upward, so her velocity is negative (Y grows downward).
		#expect(state.velocityY < 0)
		// She leaves from the ledge, so her feet are at the window's new top.
		#expect(abs(state.foot.y - 600) < 1)
	}

	@Test("A fast downward drag leaves her behind")
	func fastDownwardRelease() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		moveWindow(rig.provider, to: 1000)
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)

		let state = rig.controller.debugState
		#expect(state.state == .falling)
		#expect(state.fallReason == "PlatformDownwardRelease")
		// Left behind rather than thrown down, so she starts from rest.
		#expect(state.velocityY == 0)
	}

	@Test("A slow drag is ridden, not thrown")
	func slowDragIsRidden() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// 0.5 pt per frame moving up: well under the launch threshold.
		var top = 800.0
		for _ in 0..<20 {
			top -= 0.5
			moveWindow(rig.provider, to: top)
			rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		}

		let state = rig.controller.debugState
		#expect(state.state != .falling, "a slow drag must be followed")
		#expect(abs(state.foot.y - top) < 2, "her feet stay on the ledge")
	}

	@Test("A slow downward drag keeps her on the ledge")
	func slowDownwardIsFollowed() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		var top = 800.0
		for _ in 0..<20 {
			top += 0.5
			moveWindow(rig.provider, to: top)
			rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		}

		#expect(rig.controller.debugState.state != .falling)
	}

	@Test("Losing the window drops her only after the grace expires")
	func lostWindowGrace() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// The window disappears from the map entirely.
		rig.provider.setSurfaces([
			SupportSurface(
				top: 1117, left: 0, right: 1728, bottom: 1117,
				isDesktopFloor: true, sourceID: nil)
		])

		// Within the grace she is held, so a window that blinks out of the window
		// server's list mid-drag does not drop her.
		rig.controller.debugMaintainGroundSupport(delta: 0.1)
		#expect(rig.controller.debugState.state != .falling)

		// Past the grace she is dropped.
		for _ in 0..<10 {
			rig.controller.debugMaintainGroundSupport(delta: 0.1)
		}
		#expect(rig.controller.debugState.state == .falling)
	}

	@Test("A window moving while she walks still throws her")
	func rideWorksWhileWalking() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		moveWindow(rig.provider, to: 550)
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.fallReason == "PlatformLaunch")
	}

	@Test("Leaving the ground stops tracking the window she was on")
	func leavingGroundStopsTracking() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// Standing on the window, so it is being ridden.
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.trackedWindowID == 4242)

		// Picked up and released far below it.
		rig.controller.beginDrag(at: PixelPoint(x: 700, y: 800))
		rig.controller.updateDrag(to: PixelPoint(x: 700, y: 1200))
		rig.controller.endDrag(at: PixelPoint(x: 700, y: 1200))

		// This is the regression: the window she was dragged off must be
		// forgotten. If it is still tracked, then once she lands the ride snaps
		// her straight back up to its top, which looks like a teleport.
		#expect(rig.controller.debugState.trackedWindowID == nil)
		#expect(rig.controller.debugState.state == .falling)
	}

	@Test("A hop also stops tracking the window she jumped from")
	func hopStopsTracking() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.trackedWindowID == 4242)

		// A hop leaves the ground, so the only way in must clear the tracking.
		rig.controller.debugBeginHop()
		#expect(rig.controller.debugState.trackedWindowID == nil)
		#expect(rig.controller.debugState.fallReason == "TerrainHop")
	}

	@Test("Landing on a different window adopts it")
	func landingAdoptsNewWindow() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.trackedWindowID == 4242)

		// Move her onto a second window by hand, as a landing would.
		rig.controller.debugPlaceOnSurface(makeWindow(top: 400, id: 9999))
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.trackedWindowID == 9999)
	}

	@Test("Landing on a window adopts it straight away")
	func landingAdoptsWindow() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// Landed on a window that is *not* in the periodic map yet, as happens the
		// moment she touches down on one being dragged. Before this was fixed she
		// had nothing tracked for that frame, fell back to a proximity lookup,
		// missed the moving window, and read her own landing as losing support.
		let fresh = makeWindow(top: 500, id: 7777)
		rig.controller.debugLand(on: fresh)
		#expect(rig.controller.debugState.trackedWindowID == 7777)
		#expect(rig.controller.debugState.state == .landing)
	}

	@Test("Landing on the floor tracks nothing")
	func landingOnFloorTracksNothing() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		let floor = SupportSurface(
			top: 1117, left: 0, right: 1728, bottom: 1117,
			isDesktopFloor: true, sourceID: nil)
		rig.controller.debugLand(on: floor)
		#expect(rig.controller.debugState.trackedWindowID == nil)
		#expect(rig.controller.debugState.state == .landing)
	}
}
