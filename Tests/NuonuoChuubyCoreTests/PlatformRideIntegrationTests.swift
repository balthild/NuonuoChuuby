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
			displaySpace: space,
			randomSeed: TestAssets.randomSeed
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
			displaySpace: DisplaySpace(monitors: [], primaryHeight: 0),
			randomSeed: TestAssets.randomSeed
		)

		let before = controller.debugState.foot
		for _ in 0..<60 { controller.debugStep(delta: Self.frame) }
		// Without the suspension guard she would have been dropped by gravity.
		#expect(controller.debugState.foot == before)
		#expect(controller.state == .idle)
	}

	/// A hop is a leap with a sideways component, not a vertical bounce: from the
	/// edge of one window it must carry her across the gap onto the next one.
	///
	/// Upstream gives `BeginTerrainHop` a velocity of `315 * scale` sideways and
	/// `560 * scale` up. The port kept only the rise, so she went straight back down
	/// onto the window she left and "jumping from one window to another" never
	/// happened. Measured sideways travel at scale 1, over the ~0.68 s the rise
	/// lasts, is about 180 pt.
	@Test("A hop at an edge carries her onto the window next to it")
	func hopCrossesToTheNeighbouringWindow() throws {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-hop-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }

		let platform = MockPlatform.singleMonitor(width: 1728, height: 1117)
		// Two windows at the same height, side by side, the gap far narrower than a
		// hop — the arrangement the original was filmed with.
		platform.setWindows([
			PlatformWindow(
				id: 1001,
				ownerPID: 4242,
				ownerName: "Safari",
				bounds: PixelRect(x: 200, y: 300, width: 1200, height: 400),
				layer: 0,
				alpha: 1
			),
			PlatformWindow(
				id: 1002,
				ownerPID: 4242,
				ownerName: "Notes",
				bounds: PixelRect(x: 1430, y: 300, width: 270, height: 400),
				layer: 0,
				alpha: 1
			),
		])
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
		let left = try #require(
			provider.surfaces.first { $0.key.owner == 1001 },
			"the first window should be terrain"
		)
		controller.debugPlaceOnSurface(left)

		// Walk her up to the far end of the first window; the hop is far shorter
		// than the window is wide, so she has to start near the gap.
		controller.debugBeginWalk(toX: 1300)
		var arrived = false
		for _ in 0..<600 {
			controller.debugStep(delta: Self.frame)
			if abs(controller.debugState.foot.x - 1300) <= 5 {
				arrived = true
				break
			}
		}
		#expect(arrived, "she never reached the far end of the first window")

		controller.debugBeginHop(direction: 1)
		for _ in 0..<180 { controller.debugStep(delta: Self.frame) }

		let state = controller.debugState
		#expect(
			state.perchKey == SurfaceKey(owner: 1002, kind: .windowTop),
			"she should have crossed onto the second window, but is \(state.state) at \(state.foot)"
		)
		#expect(
			state.foot.x > left.span.end,
			"she did not clear the first window, at x=\(state.foot.x)"
		)
		#expect(
			abs(state.foot.y - 300) < 1,
			"she should be on the second window's top, y=\(state.foot.y)"
		)
	}

	// MARK: - Patrol

	/// A scripted desktop she can actually be stepped across: two windows side by
	/// side at nearly the same height, plus the floor.
	private struct PatrolRig {
		var controller: PetController
		var provider: SurfaceProvider
		var platform: MockPlatform
		var directory: URL
	}

	private func makePatrolRig() throws -> PatrolRig {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-patrol-\(UUID().uuidString)")

		let platform = MockPlatform.singleMonitor(width: 1728, height: 1117)
		platform.setWindows([
			PlatformWindow(
				id: 1001,
				ownerPID: 4242,
				ownerName: "Safari",
				bounds: PixelRect(x: 200, y: 300, width: 1200, height: 400),
				layer: 0,
				alpha: 1
			),
			// Slightly lower, so "which surface is under her feet" has one answer.
			PlatformWindow(
				id: 1002,
				ownerPID: 4242,
				ownerName: "Notes",
				bounds: PixelRect(x: 1430, y: 310, width: 270, height: 400),
				layer: 0,
				alpha: 1
			),
		])
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
		let left = try #require(
			provider.surfaces.first { $0.key.owner == 1001 },
			"the first window should be terrain"
		)
		controller.debugPlaceOnSurface(left)
		return PatrolRig(
			controller: controller,
			provider: provider,
			platform: platform,
			directory: directory
		)
	}

	/// Steps until she reaches wherever the patrol was headed, or the budget runs out.
	/// Steps until one patrol leg ends: she reaches the end she set out for and picks
	/// the next one, or an edge action takes her off the ground.
	///
	/// The end of a leg is read off what it *does* next rather than by comparing her
	/// foot to the target, which would mean duplicating the arrival tolerance here —
	/// and a duplicated copy of it passes a frame early, because the controller's
	/// check runs before it moves her and this one would run after.
	private func runToPatrolLegEnd(_ rig: PatrolRig, frames: Int = 900) -> Bool {
		let target = rig.controller.debugPatrolTargetX
		for _ in 0..<frames {
			rig.controller.debugStep(delta: Self.frame)
			guard rig.controller.debugState.movementPurpose == .patrol else { return true }
			if rig.controller.debugPatrolTargetX != target { return true }
		}
		return false
	}

	/// The reason no edge action ever fired: she went to the middle of the run and
	/// turned around there, never to an end. The original patrols between the two
	/// ends, and the ends are the only place a hop, a slide or a jump is decided.
	@Test("A patrol sets out for an end of her surface, not a point in the middle")
	func patrolSetsOutForAnEnd() throws {
		let rig = try makePatrolRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugBeginPatrol()
		#expect(rig.controller.debugState.movementPurpose == .patrol)

		let margin = rig.controller.debugPatrolStopMargin
		let target = rig.controller.debugPatrolTargetX
		let ends = [200 + margin, 1400 - margin]
		#expect(
			ends.contains { abs($0 - target) < 0.001 },
			"expected the patrol to head for one of \(ends), but it went to \(target)"
		)
	}

	@Test("Reaching an end and turning around sends her to the other end")
	func turningAroundAtAnEndPatrolsBack() throws {
		let rig = try makePatrolRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// Coming back is what she does when the edge action says `turnAround`.
		rig.controller.debugForcedTerrainEdgeAction = .turnAround
		// Only a leg out to an edge keeps her patrolling; a stroll would end her walk.
		rig.controller.debugForcedEdgeLeg = true
		rig.controller.debugBeginPatrol(direction: 1)

		let margin = rig.controller.debugPatrolStopMargin
		#expect(abs(rig.controller.debugPatrolTargetX - (1400 - margin)) < 0.001)
		#expect(runToPatrolLegEnd(rig), "she never reached the end of the window")

		#expect(
			rig.controller.debugState.movementPurpose == .patrol,
			"a turn-around at the end must keep her patrolling, not stop her"
		)
		#expect(
			abs(rig.controller.debugPatrolTargetX - (200 + margin)) < 0.001,
			"she should be heading for the other end, but is going to \(rig.controller.debugPatrolTargetX)"
		)
	}

	/// The behaviour the user could not get: from a window's edge, she crosses the
	/// gap onto the window beside it.
	///
	/// The hop itself is pinned by `hopCrossesToTheNeighbouringWindow`; what this
	/// adds is that a **patrol** is what starts it. Before the patrol was ported she
	/// never walked to an edge, so nothing downstream of that ever ran.
	@Test("A patrol that reaches the edge hops across the gap to the next window")
	func patrolHopCrossesTheGap() throws {
		let rig = try makePatrolRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.debugForcedTerrainEdgeAction = .hop
		rig.controller.debugBeginPatrol(direction: 1)
		#expect(runToPatrolLegEnd(rig), "she never reached the end of the window")

		for _ in 0..<180 { rig.controller.debugStep(delta: Self.frame) }

		let state = rig.controller.debugState
		#expect(
			state.perchKey == SurfaceKey(owner: 1002, kind: .windowTop),
			"she should have crossed onto the neighbouring window, but is \(state.state) at \(state.foot)"
		)
		#expect(state.foot.x > 1400, "she did not clear the window she jumped from")
	}

	/// A patrol runs for minutes, so the needs have to be able to stop it — nothing
	/// else looks at them while she walks.
	///
	/// She is exhausted here, which is the one need that is not a hunger reaction and
	/// so has no shared cooldown in the way.
	@Test("An exhausted pet stops patrolling and falls asleep")
	func anExhaustedPetStopsPatrolling() throws {
		let rig = try makePatrolRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// The interruption is gated on the mode, so she must be allowed to act.
		rig.controller.quietMode = false
		// A turn-around keeps a walk going indefinitely, so nothing else can account
		// for her stopping.
		rig.controller.debugForcedTerrainEdgeAction = .turnAround
		rig.controller.debugForcedEdgeLeg = true
		rig.controller.debugSetLife(sleepiness: 70)
		rig.controller.debugBeginPatrol(direction: 1)

		var sleptAt: Double?
		for frame in 0..<900 {
			rig.controller.debugStep(delta: Self.frame)
			if rig.controller.debugState.state == .sleeping {
				sleptAt = Double(frame) * Self.frame
				break
			}
		}

		// The check runs every five seconds, so the first one after that.
		let when = try #require(sleptAt, "she walked straight through being exhausted")
		#expect(
			when >= 5 && when < 6,
			"expected the need check to stop her a little after five seconds, not at \(when)"
		)
	}

	/// The other half of the rule: with nothing pressing she keeps walking. Without
	/// this, the test above would also pass if every patrol simply ended at five
	/// seconds.
	@Test("A patrol is not interrupted when no need is pressing")
	func anUnhurriedPetKeepsPatrolling() throws {
		let rig = try makePatrolRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		rig.controller.quietMode = false
		rig.controller.debugForcedTerrainEdgeAction = .turnAround
		rig.controller.debugForcedEdgeLeg = true
		// The defaults: hunger 36, sleepiness 20, both well under the thresholds.
		rig.controller.debugBeginPatrol(direction: 1)

		for _ in 0..<1500 {
			rig.controller.debugStep(delta: Self.frame)
			let state = rig.controller.debugState
			#expect(
				state.movementPurpose == .patrol,
				"she stopped patrolling with no need to stop for, at \(state.state)"
			)
		}
	}

	/// Walks alternate between going somewhere and stopping, rather than only ever
	/// going somewhere.
	///
	/// The ratchet is what pins the parameter: every unit the draw produces below
	/// `edgeLegChance` has to be an edge leg and everything above it a stroll, so a
	/// chance left at 0 or 1 — either of which would put her back to walking without
	/// pause — shows up here as a count at one end of the range. The bound is wide
	/// because this is a coin, not a schedule; 300 draws at 0.6 sit within about 3
	/// points of the mean with 3 standard deviations either side.
	@Test("Roughly three legs in five are out to an edge")
	func edgeLegsAreTheMajority() throws {
		let rig = try makePatrolRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		let draws = 300
		let edges = (0..<draws).count { _ in rig.controller.debugRollIsEdgeLeg() }
		#expect(edges >= 135 && edges <= 225, "\(edges) of \(draws) legs went to an edge")
	}

	/// A leg that ends at a point rather than at an edge is what gives a walk an
	/// ending at all: nothing else stops a patrol but an edge or a pressing need.
	@Test("A stroll ends the walk at a point instead of patrolling on")
	func aStrollEndsTheWalk() throws {
		let rig = try makePatrolRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// Turn-arounds keep her on the surface, so the only thing that can end this
		// walk is the leg kind itself.
		rig.controller.debugForcedTerrainEdgeAction = .turnAround
		rig.controller.debugForcedEdgeLeg = false
		#expect(rig.controller.debugBeginAutonomousWalk())
		#expect(
			rig.controller.debugState.movementPurpose == .wander,
			"a stroll is walked under its own purpose, not as a patrol"
		)

		var stopped = false
		for _ in 0..<1200 {
			rig.controller.debugStep(delta: Self.frame)
			if rig.controller.debugState.movementPurpose == .none {
				stopped = true
				break
			}
		}
		#expect(stopped, "she never settled at the end of the stroll")
	}

	/// The user-facing point of the leg kind: reaching an end with no edge action
	/// available does not mean another lap, it means deciding again.
	@Test("A leg that reaches the end with nothing to do there is decided afresh")
	func theLegEndIsDecidedAfresh() throws {
		let rig = try makePatrolRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// No edge action either way, and the next leg is pinned to a stroll.
		rig.controller.debugForcedTerrainEdgeAction = .turnAround
		rig.controller.debugForcedEdgeLeg = false
		rig.controller.debugBeginPatrol(direction: 1)
		#expect(runToPatrolLegEnd(rig), "she never reached the end of the window")

		#expect(
			rig.controller.debugState.movementPurpose == .wander,
			"with nothing to do at the end she should stroll, but is \(rig.controller.debugState.movementPurpose)"
		)

		var stopped = false
		for _ in 0..<1200 {
			rig.controller.debugStep(delta: Self.frame)
			if rig.controller.debugState.movementPurpose == .none {
				stopped = true
				break
			}
		}
		#expect(stopped, "she never settled after strolling from the end")
	}
}
