import Foundation
import Testing

@testable import NuonuoChuubyCore

/// Drives the ride frame by frame against a scripted surface graph.
///
/// A real drag cannot be scripted — AppleScript's `set bounds` teleports a
/// window, a single huge jump rather than a gesture — so the ride is exercised
/// here by moving a known surface and stepping one frame at a time. The window is
/// resolved from the graph because the window server has no such window.
@MainActor
@Suite("Platform ride integration", .serialized)
struct PlatformRideIntegrationTests {
	private static var assetsRoot: URL? { TestAssets.root }

	enum TestSkip: Error { case missingAssets }

	private static let frame = 1.0 / 60
	private static let windowID: UInt32 = 4242

	private struct Rig {
		var controller: PetController
		var provider: SurfaceProvider
		var floor: Surface
		var directory: URL
	}

	private func windowSurface(top: Double, reachable: Bool = true) -> Surface {
		Surface(
			key: SurfaceKey(owner: Self.windowID, kind: .windowTop),
			span: Span(start: 200, end: 1400),
			visible: [Span(start: 200, end: 1400)],
			offset: top,
			ownerBounds: PixelRect(x: 200, y: top, width: 1200, height: 400),
			isReachable: reachable
		)
	}

	private func makeRig(windowTop: Double = 800) throws -> Rig {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-ride-\(UUID().uuidString)")

		let space = DisplaySpace()
		let monitor = space.displays.first
		let monitorFrame = monitor?.frame ?? PixelRect(x: 0, y: 0, width: 1728, height: 1117)
		let floor = Surface(
			key: SurfaceKey(owner: monitor?.id ?? 1, kind: .floor),
			span: Span(start: monitorFrame.left, end: monitorFrame.right),
			visible: [Span(start: monitorFrame.left, end: monitorFrame.right)],
			offset: monitor?.visibleFrame.bottom ?? 1117,
			ownerBounds: monitorFrame,
			isReachable: true
		)

		let provider = SurfaceProvider(surfaces: [windowSurface(top: windowTop), floor])
		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: provider,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space
		)
		controller.debugPlaceOnSurface(windowSurface(top: windowTop))
		return Rig(controller: controller, provider: provider, floor: floor, directory: directory)
	}

	private func setWindow(_ rig: Rig, to top: Double?, reachable: Bool = true) {
		var surfaces = [rig.floor]
		if let top { surfaces.insert(windowSurface(top: top, reachable: reachable), at: 0) }
		rig.provider.setSurfaces(surfaces)
	}

	@Test("A fast upward yank releases the perch and throws her up")
	func fastUpwardLaunch() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// 200 pt in a single frame is far past what a drag does.
		setWindow(rig, to: 600)
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)

		let state = rig.controller.debugState
		#expect(state.state == .falling)
		#expect(state.fallReason == "PlatformLaunch")
		#expect(state.perchKey == nil, "the perch is cleared on release")
		// Thrown upward, so her velocity is negative (Y grows downward).
		#expect(state.velocityY < 0)
	}

	@Test("A fast downward yank releases the perch and leaves her behind")
	func fastDownwardRelease() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		setWindow(rig, to: 1000)
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)

		let state = rig.controller.debugState
		#expect(state.state == .falling)
		#expect(state.fallReason == "PlatformDownwardRelease")
		#expect(state.perchKey == nil)
		// Left behind rather than thrown down, so she starts from rest.
		#expect(state.velocityY == 0)
	}

	@Test("A slow drag carries her exactly, not approximately")
	func slowDragIsRidden() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		var top = 800.0
		for _ in 0..<40 {
			top -= 0.5
			setWindow(rig, to: top)
			rig.controller.debugMaintainGroundSupport(delta: Self.frame)
			#expect(rig.controller.debugState.state != .falling)
			// The perch is recomputed, so there is no lag to be "approximately".
			#expect(rig.controller.debugState.foot.y == top)
		}
	}

	@Test("A slow downward drag keeps her on the ledge")
	func slowDownwardIsFollowed() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		var top = 800.0
		for _ in 0..<40 {
			top += 0.5
			setWindow(rig, to: top)
			rig.controller.debugMaintainGroundSupport(delta: Self.frame)
			#expect(rig.controller.debugState.state != .falling)
			#expect(rig.controller.debugState.foot.y == top)
		}
	}

	@Test("A window dragged past the drift tolerance still carries her")
	func fasterDragIsStillRidden() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// 10 pt in one frame is 600 pt/s, which is a plain drag. It is further than she
		// may sit from where the ride last put her, and less than the 15 pt that counts
		// as a yank — so if the two thresholds are read from the same quantity, a window
		// moving at this speed reads as a lost perch and she is dropped from a ledge she
		// is riding perfectly well.
		var top = 800.0
		for _ in 0..<40 {
			top += 10
			setWindow(rig, to: top)
			rig.controller.debugMaintainGroundSupport(delta: Self.frame)
			#expect(rig.controller.debugState.state != .falling, "released from a ride, not a yank")
			#expect(rig.controller.debugState.foot.y == top)
		}
	}

	@Test("Being sent home leaves her on the floor, not on the edge she was on")
	func bringHomeReanchorsToTheFloor() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(
			rig.controller.debugState.perchKey == SurfaceKey(owner: Self.windowID, kind: .windowTop)
		)

		rig.controller.bringHome()
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)

		// Home is the floor, so that is what holds her from here on.
		#expect(rig.controller.debugState.state != .falling)
		#expect(rig.controller.debugState.perchKey == rig.floor.key)
		#expect(rig.controller.debugState.foot.y == rig.floor.offset)
	}

	@Test("A floor that goes away drops her at once, with no grace")
	func floorGoneDropsHerAtOnce() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugPlaceOnSurface(rig.floor)
		rig.provider.setSurfaces([])

		// The grace exists for a dragged window that blinks out of the window
		// server's list for a moment. A floor is a property of the display, so a floor
		// that is gone is gone: waiting out the grace only postpones the fall.
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.state == .falling)
		#expect(rig.controller.debugState.perchKey == nil)
	}

	@Test("Losing the window drops her only after the grace expires")
	func lostWindowGrace() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// The window is closed: it leaves the graph entirely.
		setWindow(rig, to: nil)

		// Within the grace she is held, so a window that blinks out of the window
		// server's list mid-drag does not drop her.
		rig.controller.debugMaintainGroundSupport(delta: 0.1)
		#expect(rig.controller.debugState.state != .falling)

		// Past the grace she is dropped.
		for _ in 0..<10 {
			rig.controller.debugMaintainGroundSupport(delta: 0.1)
		}
		#expect(rig.controller.debugState.state == .falling)
		#expect(rig.controller.debugState.perchKey == nil)
	}

	@Test("A window moving while she walks still throws her")
	func rideWorksWhileWalking() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		setWindow(rig, to: 550)
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.fallReason == "PlatformLaunch")
	}

	@Test("Losing every display drops her")
	func monitorUnplug() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// She stands on the floor, and the monitor goes away.
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		rig.provider.setSurfaces([])

		for _ in 0..<30 {
			rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		}
		#expect(rig.controller.debugState.state == .falling)
	}

	@Test("A window edge covered under her releases the perch")
	func coveredSpotReleases() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// She is anchored at the centre of the edge, x = 800. Another window is now
		// brought to the front over the middle of it, so the graph reports only the
		// two ends as visible.
		let covered = Surface(
			key: SurfaceKey(owner: Self.windowID, kind: .windowTop),
			span: Span(start: 200, end: 1400),
			visible: [Span(start: 200, end: 500), Span(start: 1100, end: 1400)],
			offset: 800,
			ownerBounds: PixelRect(x: 200, y: 800, width: 1200, height: 400),
			isReachable: true
		)
		rig.provider.setSurfaces([covered, rig.floor])

		// The window server still describes the window, so the live read succeeds
		// and reports the whole edge. Only the graph knows her spot is covered — a
		// visibility check made against the live surface would pass and she would
		// stay put on an edge another window is covering.
		rig.controller.debugLiveWindowSurfaceOverride = { _ in
			Surface(
				key: SurfaceKey(owner: Self.windowID, kind: .windowTop),
				span: Span(start: 200, end: 1400),
				visible: [Span(start: 200, end: 1400)],
				offset: 800,
				ownerBounds: PixelRect(x: 200, y: 800, width: 1200, height: 400),
				isReachable: true
			)
		}

		// Held through the grace, then dropped — she cannot stand on a covered edge.
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.state != .falling)

		for _ in 0..<30 {
			rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		}
		#expect(rig.controller.debugState.state == .falling)
		#expect(rig.controller.debugState.perchKey == nil)
	}

	@Test("A window she stands on becoming unreachable drops her")
	func unreachableDrops() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// Dragged up under the menu bar: the same edge, no longer a place she can
		// stand.
		setWindow(rig, to: 800, reachable: false)
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.state != .falling, "held through the grace")

		for _ in 0..<30 {
			rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		}
		#expect(rig.controller.debugState.state == .falling)
	}

	@Test("Leaving the ground stops tracking the window she was on")
	func leavingGroundStopsTracking() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.trackedWindowID == Self.windowID)

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
		#expect(rig.controller.debugState.trackedWindowID == Self.windowID)

		// A hop leaves the ground, so the only way in must clear the perch.
		rig.controller.debugBeginHop()
		#expect(rig.controller.debugState.trackedWindowID == nil)
		#expect(rig.controller.debugState.fallReason == "TerrainHop")
	}

	@Test("Landing on a different window adopts it")
	func landingAdoptsNewWindow() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.trackedWindowID == Self.windowID)

		// Move her onto a second window by hand, as a landing would.
		let second = Surface(
			key: SurfaceKey(owner: 9999, kind: .windowTop),
			span: Span(start: 200, end: 1400),
			visible: [Span(start: 200, end: 1400)],
			offset: 400,
			ownerBounds: PixelRect(x: 200, y: 400, width: 1200, height: 400),
			isReachable: true
		)
		rig.controller.debugPlaceOnSurface(second)
		rig.controller.debugMaintainGroundSupport(delta: Self.frame)
		#expect(rig.controller.debugState.trackedWindowID == 9999)
	}

	@Test("Landing on a window adopts it straight away")
	func landingAdoptsWindow() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		let fresh = Surface(
			key: SurfaceKey(owner: 7777, kind: .windowTop),
			span: Span(start: 200, end: 1400),
			visible: [Span(start: 200, end: 1400)],
			offset: 500,
			ownerBounds: PixelRect(x: 200, y: 500, width: 1200, height: 400),
			isReachable: true
		)
		rig.controller.debugLand(on: fresh)
		#expect(rig.controller.debugState.trackedWindowID == 7777)
		#expect(rig.controller.debugState.state == .landing)
	}

	@Test("Landing on the floor tracks nothing")
	func landingOnFloorTracksNothing() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugLand(on: rig.floor)
		#expect(rig.controller.debugState.trackedWindowID == nil)
		#expect(rig.controller.debugState.state == .landing)
	}

	/// The invariant the whole refactor is for: a grounded pet is never without a
	/// surface. Before the perch model, "landed but unsupported" was reachable.
	@Test("A grounded pet is never floating, over a long slow ride")
	func neverFloating() throws {
		let rig = try makeRig(windowTop: 800)
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		var top = 800.0
		for tick in 0..<4000 {
			// A slow, wobbly drift: well under the release threshold every frame.
			top += sin(Double(tick) * 0.05) * 0.4
			setWindow(rig, to: top)
			rig.controller.debugMaintainGroundSupport(delta: Self.frame)
			let state = rig.controller.debugState
			#expect(state.state != .falling, "released during a slow drift at tick \(tick)")
			#expect(state.perchKey != nil, "grounded but unperched at tick \(tick)")
		}
	}

	@Test("With no display she is suspended and does not move")
	func suspendedWithoutDisplay() throws {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-suspend-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }

		// No monitors at all: the session is locked or every screen slept.
		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: SurfaceProvider(platform: MockPlatform()),
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: DisplaySpace(monitors: [], primaryHeight: 0)
		)

		let before = controller.debugState.foot
		for _ in 0..<60 { controller.debugStep(delta: Self.frame) }
		// Without the suspension guard she would have been dropped by gravity.
		#expect(controller.debugState.foot == before)
		#expect(controller.state == .idle)
	}
}
