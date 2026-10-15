import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The enclosure and the side collision, driven frame by frame against a scripted
/// desktop.
///
/// A real drag cannot be scripted, and a real window cannot be moved on demand,
/// so both are exercised through the seams ``PetController`` exposes for them.
@MainActor
@Suite("Window enclosure integration", .serialized)
struct WindowEnclosureIntegrationTests {
	private static var assetsRoot: URL? { TestAssets.root }

	enum TestSkip: Error { case missingAssets }

	private static let frame = 1.0 / 60
	private static let windowID: UInt32 = 5150
	/// A plain 600×400 window, comfortably larger than the pet.
	private static let box = PixelRect(x: 600, y: 600, width: 600, height: 400)

	private struct Rig {
		var controller: PetController
		var provider: SurfaceProvider
		var platform: MockPlatform
		var space: DisplaySpace
		var directory: URL
	}

	private static func window(bounds: PixelRect) -> PlatformWindow {
		window(id: windowID, bounds: bounds)
	}

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

	private func makeRig() throws -> Rig {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-enclosure-\(UUID().uuidString)")

		let platform = MockPlatform.singleMonitor(width: 1728, height: 1117)
		platform.setWindows([Self.window(bounds: Self.box)])
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
		// The live read and the sampled bodies answer from the same place, as they
		// would on a real desktop, so a test cannot assert against one while the
		// physics reads the other.
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

	/// Drags her to a point and lets go, as the user would.
	///
	/// The body map is what a release consults, so it is sampled first: on the
	/// open desktop that has already happened by the time a drag ends.
	private func drop(_ rig: Rig, at point: PixelPoint) {
		rig.provider.sampleBodiesIfStale(displaySpace: rig.space, delta: 0.2)
		rig.controller.beginDrag(at: rig.controller.debugState.foot)
		rig.controller.updateDrag(to: point)
		rig.controller.endDrag(at: point)
	}

	/// Puts the one scripted window at a new rectangle.
	private func resizeBox(_ rig: Rig, to box: PixelRect) {
		rig.platform.setWindows([Self.window(bounds: box)])
	}

	/// Runs whole frames until the body sampler has taken another sample, which is
	/// what the collision pass keys off.
	private func stepToNextBodySample(_ rig: Rig, frames: Int = 7) {
		for _ in 0..<frames { rig.controller.debugStep(delta: Self.frame) }
	}

	// MARK: - Getting in

	@Test("Let go wholly inside a window, and it takes her in")
	func releasedInsideAWindow() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))

		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
		#expect(rig.controller.state == .falling, "inside the box she is a falling body")
	}

	@Test("Settled on a box's floor, her feet are on it — not below the window")
	func restingPutsHerFeetOnTheBoxFloor() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// Whatever is aligned to the floor must be the feet, so the fault this pins
		// scales with her size: the gap between the body's bottom and the foot anchor
		// is a fixed fraction of the sprite. Try the smallest and the largest size.
		let floor = Self.box.bottom
		for size in [PetSizePolicy.fromPercent(60), PetSizePolicy.fromPercent(150)] {
			rig.controller.setSize(size)
			drop(rig, at: PixelPoint(x: 900, y: 900))
			#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
			advance(rig, seconds: 5)

			let foot = rig.controller.debugState.foot.y
			#expect(rig.controller.debugState.state == .idle, "at \(Int(size)) she had not settled")
			#expect(
				abs(foot - floor) < 1,
				"at \(Int(size)) expected her feet on the window's bottom edge at \(Int(floor)), found \(Int(foot))"
			)
		}
	}

	@Test("Half in is not in: only a body wholly inside is taken")
	func halfInsideIsNotEnough() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// Her centre is inside the window, but her left side hangs out of it. The
		// original asked only for the centre, and she would have gone in.
		drop(rig, at: PixelPoint(x: 640, y: 900))

		#expect(rig.controller.debugState.enclosureWindowID == nil)
		#expect(rig.controller.state == .falling, "she falls to the desktop instead")
	}

	@Test("A window too small to hold her body never takes her in")
	func tooSmallToHoldHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		let snug = PixelRect(x: 800, y: 800, width: 145, height: 170)
		rig.platform.setWindows([Self.window(bounds: snug)])

		drop(rig, at: PixelPoint(x: 872, y: 890))

		#expect(rig.controller.debugState.enclosureWindowID == nil)
	}

	@Test("Two overlapping windows: the frontmost one takes her, not the smallest")
	func frontmostWindowTakesHerNotTheSmallest() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// A small window with a larger one in front of it, both holding her whole
		// body. Picking by size took her into the small one — the one she cannot be
		// seen in — and the occlusion rule then handed her on to the large one, so
		// she appeared to fall twice.
		let large = PixelRect(x: 500, y: 500, width: 900, height: 500)
		rig.platform.setWindows([
			Self.window(id: 9002, bounds: large),
			Self.window(id: Self.windowID, bounds: Self.box),
		])

		drop(rig, at: PixelPoint(x: 900, y: 900))

		#expect(
			rig.controller.debugState.enclosureWindowID == 9002,
			"she went into the window she is actually visible inside"
		)

		// And she stays there: nothing is in front of the frontmost window, so the
		// hand-over cannot fire on the very next grace.
		advance(rig, seconds: 3)
		#expect(rig.controller.debugState.enclosureWindowID == 9002)
	}

	@Test("A small window in front of a large one still takes her")
	func smallWindowInFrontStillTakesHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// The case the size rule was there for, and which frontmost gets right for
		// the same reason: she is visibly inside the small window.
		let large = PixelRect(x: 500, y: 500, width: 900, height: 500)
		rig.platform.setWindows([
			Self.window(id: Self.windowID, bounds: Self.box),
			Self.window(id: 9002, bounds: large),
		])

		drop(rig, at: PixelPoint(x: 900, y: 900))

		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
		advance(rig, seconds: 3)
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
	}

	@Test("Let go above a window in front, she lands on it instead of being swallowed")
	func landsOnTheWindowInFront() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// A large window with a smaller one in front of it, lower down. Let go
		// above the small one but inside the large one, her body is not in the
		// small window at all — so only the large one could hold her.
		let large = PixelRect(x: 500, y: 400, width: 900, height: 700)
		let small = PixelRect(x: 850, y: 650, width: 400, height: 300)
		rig.platform.setWindows([
			Self.window(id: 9002, bounds: small),
			Self.window(id: 9003, bounds: large),
		])

		drop(rig, at: PixelPoint(x: 900, y: 600))

		#expect(
			rig.controller.debugState.enclosureWindowID == nil,
			"a window top to land on is not a reason to be swallowed whole"
		)

		// And she comes down onto the small window's top edge, as she would onto
		// any other ledge.
		for _ in 0..<120 { rig.controller.debugStep(delta: Self.frame) }
		#expect(rig.controller.debugState.perchKey == SurfaceKey(owner: 9002, kind: .windowTop))
		#expect(abs(rig.controller.debugState.foot.y - small.top) < 0.001)
	}

	@Test("A window top below the box's floor does not stop the box taking her")
	func surfaceBelowTheBoxDoesNotBlock() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// The window holding her ends at y = 1000; another one starts at 1050,
		// below it. Landing on that would mean falling straight through the box she
		// is in, so it does not count as somewhere she can land.
		let below = PixelRect(x: 700, y: 1050, width: 500, height: 300)
		rig.platform.setWindows([
			Self.window(id: Self.windowID, bounds: Self.box),
			Self.window(id: 9002, bounds: below),
		])

		drop(rig, at: PixelPoint(x: 900, y: 900))

		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
	}

	// MARK: - Staying in, and getting out

	@Test("The window going away drops her, and says so")
	func losingTheWindowDropsHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)

		// The window is closed: it leaves the sample entirely.
		rig.provider.setBodies([:])
		_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)

		let state = rig.controller.debugState
		#expect(state.enclosureWindowID == nil)
		#expect(state.state == .falling)
		#expect(state.fallReason == "EnclosureWindowLost")
	}

	@Test("Shaken hard, she never escapes the box")
	func shakenNeverEscapes() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)

		for tick in 0..<2000 {
			let sway = sin(Double(tick) * 0.05) * 60
			let box = PixelRect(
				x: Self.box.x + sway,
				y: Self.box.y,
				width: Self.box.width,
				height: Self.box.height
			)
			rig.controller.debugLiveWindowBoundsOverride = { _ in box }
			_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)
			let body = rig.controller.debugBodyRect()
			// A wall only ever pushes her inward, so a subpixel remainder can leave
			// her a fraction of a point past it for a single frame — never more.
			let slack = 1.5
			#expect(body.left >= box.left - slack, "escaped left at tick \(tick)")
			#expect(body.right <= box.right + slack, "escaped right at tick \(tick)")
			#expect(body.top >= box.top - slack, "escaped up at tick \(tick)")
			#expect(body.bottom <= box.bottom + slack, "escaped down at tick \(tick)")
			// The box has to keep holding her throughout: a test that only watched
			// her position would pass even after she was thrown out, because a
			// released pet stops moving and stays roughly where she was.
			#expect(
				rig.controller.debugState.enclosureWindowID == Self.windowID,
				"thrown out of the box at tick \(tick)"
			)
		}
	}

	@Test("Growing her is what can stop a box from holding her")
	func growingHerCanEvictHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		// A window with room for her as she is, but not for twice her.
		resizeBox(rig, to: PixelRect(x: 760, y: 660, width: 300, height: 330))
		drop(rig, at: PixelPoint(x: 900, y: 900))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)

		// A modest growth still fits, so she stays put.
		rig.controller.setSize(240)
		#expect(
			rig.controller.debugState.enclosureWindowID == Self.windowID,
			"a box that still holds her keeps holding her"
		)

		// Past what the box has room for she is let out, rather than left hanging
		// through a wall.
		rig.controller.setSize(PetSizePolicy.defaultSize * 2)
		#expect(rig.controller.debugState.enclosureWindowID == nil)
		#expect(rig.controller.debugState.state == .falling)
	}

	@Test("Being picked up takes her out of the box")
	func pickingHerUpTakesHerOut() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		rig.controller.beginDrag(at: rig.controller.debugState.foot)

		#expect(rig.controller.debugState.enclosureWindowID == nil)
	}

	@Test("Being sent home takes her out of the box")
	func bringHomeTakesHerOut() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		rig.controller.bringHome()

		#expect(rig.controller.debugState.enclosureWindowID == nil)
		#expect(rig.controller.state == .idle)
	}

	// MARK: - Meals

	@Test("A queued meal makes her leave the box")
	func aMealMakesHerLeave() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)

		let accepted = rig.controller.enqueueMeals([
			DeletedItem(
				id: 1,
				originalPath: "/tmp/a.txt",
				displayName: "a.txt",
				detectedAt: Date(),
				anchor: PixelPoint(x: 300, y: 300),
				exactAnchor: true
			)
		])

		#expect(accepted == 1)
		#expect(rig.controller.debugState.enclosureWindowID == nil)
		#expect(rig.controller.state == .running, "she runs out to meet it")
	}

	@Test("Licking an icon is refused while the walls hold her")
	func iconLickRefusedInABox() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))

		#expect(!rig.controller.tryBeginIconLick(manual: true))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
	}

	// MARK: - Being covered

	/// A window that covers the box **entirely**, so she is hidden wherever she is
	/// inside it — which is the case the user reported. It still has to be small
	/// enough not to be the display's own background.
	private var coveringTheBox: PixelRect { PixelRect(x: 480, y: 420, width: 900, height: 620) }

	/// Another, differently placed window that also covers the box entirely.
	private var alsoCoveringTheBox: PixelRect {
		PixelRect(x: 450, y: 400, width: 1000, height: 700)
	}

	/// A body sample in which the box holding her sits at z-index 1, so an
	/// occluder at 0 is in front of it.
	private func hostingBodies(occludedBy occluder: PixelRect? = nil) -> [UInt32: WindowBody] {
		var bodies: [UInt32: WindowBody] = [
			Self.windowID: Self.holder(bounds: Self.box, zIndex: 1)
		]
		if let occluder {
			bodies[9001] = Self.holder(bounds: occluder, zIndex: 0)
		}
		return bodies
	}

	/// A window with room for her, as the sampler would mark one.
	private static func holder(bounds: PixelRect, zIndex: Int) -> WindowBody {
		WindowBody(bounds: bounds, zIndex: zIndex, isEnclosureCandidate: true)
	}

	/// A window that is sampled but could never hold her — one filling the display,
	/// which she would be sealed against. It still hides her.
	private static func notAHolder(bounds: PixelRect, zIndex: Int) -> WindowBody {
		WindowBody(bounds: bounds, zIndex: zIndex, isEnclosureCandidate: false)
	}

	/// Runs the enclosure for `seconds`, as the simulation clock would.
	///
	/// The full ``PetController/debugStep(delta:)`` is not used here because it
	/// re-samples the bodies from the mock platform and would clobber the scripted
	/// sample.
	private func advance(_ rig: Rig, seconds: Double) {
		var remaining = seconds
		while remaining > 0 {
			_ = rig.controller.debugUpdateEnclosure(delta: min(Self.frame, remaining))
			remaining -= Self.frame
		}
	}

	@Test("A covering window with no room for her drops her out of the box")
	func coveredBoxLetsHerGo() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)

		// Narrower than her body, so it can catch her but never hold her, and tall
		// enough to stay over her as she settles inside the box.
		let her = rig.controller.debugBodyRect()
		let snug = PixelRect(
			x: her.centerX - 72.5,
			y: her.centerY - 100,
			width: 145,
			height: 300
		)
		rig.provider.setBodies(hostingBodies(occludedBy: snug))

		// Held through the grace: switching apps covers a window for a moment.
		advance(rig, seconds: 0.3)
		#expect(
			rig.controller.debugState.enclosureWindowID == Self.windowID,
			"released before the grace had run out"
		)

		advance(rig, seconds: 0.5)
		let state = rig.controller.debugState
		#expect(state.enclosureWindowID == nil)
		#expect(state.state == .falling)
		#expect(state.fallReason == "EnclosureCovered")
	}

	@Test("A window too large to hold her still hides her")
	func aWindowTooLargeToHoldHerStillHidesHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)

		// A window filling the display comes to the front. It cannot hold her — she
		// would be sealed against the screen — so it is not a container candidate.
		// It certainly hides her, though, and a sampled window that cannot hide her
		// leaves her standing in a box that is no longer on screen at all.
		let fullScreen = PixelRect(x: 0, y: 25, width: 1728, height: 1092)
		rig.provider.setBodies([
			Self.windowID: Self.holder(bounds: Self.box, zIndex: 1),
			9001: Self.notAHolder(bounds: fullScreen, zIndex: 0),
		])

		advance(rig, seconds: 1.5)

		let state = rig.controller.debugState
		#expect(state.enclosureWindowID == nil, "she should have been let out of the covered box")
		#expect(state.fallReason == "EnclosureCovered")
	}

	@Test("A covering window with room for her takes her in instead of dropping her")
	func coveredByAWindowThatCouldHoldHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)

		rig.provider.setBodies(hostingBodies(occludedBy: coveringTheBox))
		advance(rig, seconds: 1.1)

		let state = rig.controller.debugState
		#expect(state.enclosureWindowID == 9001, "she moved into the window covering her")
		#expect(state.fallReason != "EnclosureCovered", "and was not dropped out to the desktop")
	}

	@Test("Moved into a covering window, she settles on its floor and stays")
	func transferSettlesOnTheNewFloor() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		rig.provider.setBodies(hostingBodies(occludedBy: coveringTheBox))
		advance(rig, seconds: 1.1)

		// Gravity finishes the job on the new floor, which is what makes the
		// hand-over invisible rather than a jump.
		advance(rig, seconds: 3)
		#expect(rig.controller.debugState.enclosureWindowID == 9001)
		#expect(rig.controller.debugState.state == .idle, "she came to rest in the new box")

		// Where she is now, nothing covers her — the frontmost window she was given
		// to cannot itself be covered — so the hand-over does not repeat.
		advance(rig, seconds: 5)
		#expect(rig.controller.debugState.enclosureWindowID == 9001)
	}

	@Test("Handed over to the frontmost of the windows covering her")
	func handedOverToTheFrontmost() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))

		// Four ordinary windows, hers furthest back. She goes to the one the user
		// is actually looking at.
		rig.provider.setBodies([
			Self.windowID: Self.holder(bounds: Self.box, zIndex: 3),
			9001: Self.holder(bounds: coveringTheBox, zIndex: 2),
			9002: Self.holder(bounds: alsoCoveringTheBox, zIndex: 0),
			9003: Self.holder(bounds: coveringTheBox, zIndex: 1),
		])
		advance(rig, seconds: 1.1)

		#expect(rig.controller.debugState.enclosureWindowID == 9002)
	}

	@Test("Uncovering the box within the grace keeps her in it")
	func uncoveringInTimeKeepsHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))

		rig.provider.setBodies(hostingBodies(occludedBy: coveringTheBox))
		advance(rig, seconds: 0.3)
		rig.provider.setBodies(hostingBodies())
		advance(rig, seconds: 0.5)

		#expect(
			rig.controller.debugState.enclosureWindowID == Self.windowID,
			"a cover that went away in time leaves her where she was"
		)
	}

	@Test("A window BEHIND the one holding her changes nothing")
	func windowBehindChangesNothing() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))

		// The same large window, this time behind hers: a window behind the one
		// holding her hides neither of them.
		rig.provider.setBodies([
			Self.windowID: Self.holder(bounds: Self.box, zIndex: 0),
			9001: Self.holder(bounds: alsoCoveringTheBox, zIndex: 1),
		])
		advance(rig, seconds: 2)

		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
	}

	@Test("A window in front that misses her leaves the box alone")
	func occluderThatMissesHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))

		// A window opened alongside hers, covering the left of the display but
		// never reaching her.
		rig.provider.setBodies(
			hostingBodies(occludedBy: PixelRect(x: 0, y: 0, width: 700, height: 1117))
		)
		advance(rig, seconds: 2)

		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
	}

	// MARK: - Dragging the box up and down

	/// Lets her settle on the box's floor, with the box where it is.
	private func settle(_ rig: Rig, seconds: Double = 5) {
		advance(rig, seconds: seconds)
	}

	/// Moves the scripted box and steps one frame, as dragging it would.
	private func dragBox(_ rig: Rig, byY delta: Double, frames: Int) {
		var box = Self.box
		for _ in 0..<frames {
			box = PixelRect(x: box.x, y: box.y + delta, width: box.width, height: box.height)
			rig.controller.debugLiveWindowBoundsOverride = { _ in box }
			_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)
		}
	}

	@Test("Dragging the box slowly up carries her with it, without bouncing her")
	func slowUpwardDragCarriesHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		settle(rig)
		#expect(rig.controller.debugState.state == .idle, "she should be resting before the drag")
		let settled = rig.controller.debugState.foot.y

		// 5 pt a frame is 300 pt/s: an ordinary drag, well under the yank.
		var box = Self.box
		for tick in 0..<30 {
			box = PixelRect(x: box.x, y: box.y - 5, width: box.width, height: box.height)
			rig.controller.debugLiveWindowBoundsOverride = { _ in box }
			_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)

			#expect(
				rig.controller.debugState.state == .idle,
				"bounced her on a slow drag at tick \(tick)"
			)
			#expect(
				rig.controller.debugState.velocityY <= 0,
				"kicked her upward at tick \(tick) instead of carrying her"
			)
		}

		// Carried the whole way, so her foot rose by the same 150 pt the box did.
		let risen = settled - rig.controller.debugState.foot.y
		#expect(abs(risen - 150) < 2, "expected to ride up with the floor, but rose \(risen) pt")
	}

	@Test("Yanking the box up throws her inside it")
	func yankingTheBoxUpThrowsHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		settle(rig)

		// 20 pt a frame is 1200 pt/s: past the threshold, so it is a throw.
		dragBox(rig, byY: -20, frames: 3)

		#expect(rig.controller.debugState.state == .falling)
		#expect(
			rig.controller.debugState.velocityY < -500,
			"flung up rather than carried: \(rig.controller.debugState.velocityY)"
		)
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
	}

	@Test("A flick delivered wholly between two box reads still throws her")
	func aFlickBetweenReadsStillThrowsHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		settle(rig)
		#expect(rig.controller.state == .idle, "she should be resting before the flick")

		// Two frames are the whole gesture: 40 pt in 33 ms, which is 1200 pt/s.
		// The box is not read on the first of them — a resting pet's box is read
		// at half rate — so the second read has to judge the wall by how fast it
		// went over both frames. Judging it by the distance instead, against the
		// position from before the flick, reads the whole gesture as one slow
		// move of the same size and carries her through it instead of throwing her.
		dragBox(rig, byY: -20, frames: 2)

		#expect(rig.controller.debugState.state == .falling, "a flick is a flick")
		#expect(rig.controller.debugState.velocityY < -300, "flung up with the wall")
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)
	}

	@Test("A box dragged down fast is left behind, not stuck to its floor")
	func fastDownwardDragLeavesHerBehind() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		settle(rig)
		#expect(rig.controller.state == .idle, "she should be resting before the drag")
		let footBefore = rig.controller.debugState.foot.y

		// 40 pt a frame is 2400 pt/s, far past the 15 pt that counts as a yank.
		var box = Self.box
		for _ in 0..<4 {
			box = PixelRect(x: box.x, y: box.y + 40, width: box.width, height: box.height)
			rig.controller.debugLiveWindowBoundsOverride = { _ in box }
			_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)
		}

		let moved = rig.controller.debugState.foot.y - footBefore
		#expect(
			rig.controller.debugState.state == .falling,
			"the floor was yanked out from under her, so she is falling"
		)
		#expect(
			moved < 20,
			"the box fell \(Int(box.bottom - Self.box.bottom)) pt and carried her \(Int(moved)) with it"
		)

		// Once the drag stops she is still in mid-air and has to fall the rest of the
		// way. Being put straight down on the new floor would mean the record of her
		// standing on it outlived the yank that took it away.
		_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)
		#expect(
			rig.controller.debugState.state == .falling,
			"she was in mid-air when the drag stopped, but is \(rig.controller.debugState.state)"
		)

		// And then she comes down onto the floor it left behind, standing on it at
		// the feet — the window's own bottom edge.
		let floor = box.bottom
		advance(rig, seconds: 5)
		#expect(rig.controller.debugState.state == .idle, "she should have settled")
		#expect(
			abs(rig.controller.debugState.foot.y - floor) < 1,
			"expected her on the new floor at \(Int(floor)), found \(Int(rig.controller.debugState.foot.y))"
		)
	}

	@Test("Dragging the box slowly down carries her down with it")
	func slowDownwardDragCarriesHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		settle(rig)
		let settled = rig.controller.debugState.foot.y

		var box = Self.box
		for tick in 0..<30 {
			box = PixelRect(x: box.x, y: box.y + 5, width: box.width, height: box.height)
			rig.controller.debugLiveWindowBoundsOverride = { _ in box }
			_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)

			// The floor moving away from her must not leave her airborne: being left
			// behind here is what showed a fall animation on a slow downward drag.
			#expect(
				rig.controller.debugState.state == .idle,
				"she was dropped by a slow downward drag at tick \(tick)"
			)
		}

		// Carried the whole way, so her foot went down with the box.
		let fallen = rig.controller.debugState.foot.y - settled
		#expect(abs(fallen - 150) < 2, "expected to ride down with the floor, fell \(fallen) pt")
	}

	@Test("Letting go of the drag does not bounce her")
	func stoppingTheDragDoesNotBounceHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		settle(rig)

		// Drag up, then hold still: the floor stops under her. She must stop with it
		// rather than keeping the speed it had and flying off it.
		dragBox(rig, byY: -5, frames: 20)
		for tick in 0..<30 {
			_ = rig.controller.debugUpdateEnclosure(delta: Self.frame)
			let state = rig.controller.debugState
			#expect(state.state == .idle, "thrown off the floor at tick \(tick) after the drag stopped")
			#expect(state.velocityY <= 0, "kicked upward at tick \(tick)")
		}
	}

	// MARK: - Side impact

	@Test("A window edge sweeping sideways through her throws her clear")
	func sideEdgeThrowsHer() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		rig.controller.debugLiveWindowBoundsOverride = { _ in nil }

		// She stands on the floor at x = 864, so her body spans 793.5…932.75.
		// The window's left edge begins just past her and sweeps in over her.
		rig.platform.setWindows([
			Self.window(bounds: PixelRect(x: 934, y: 600, width: 466, height: 500))
		])
		stepToNextBodySample(rig, frames: 1)

		rig.platform.setWindows([
			Self.window(bounds: PixelRect(x: 865, y: 600, width: 535, height: 500))
		])
		stepToNextBodySample(rig)

		let state = rig.controller.debugState
		#expect(state.fallReason == "WindowSideImpact")
		#expect(state.state == .falling)
		#expect(state.velocityX < 0, "thrown the way the edge was travelling")
		#expect(state.velocityY < 0, "and lifted off the floor rather than pushed along it")
	}

	@Test("A window that merely appears does not hit her")
	func aWindowThatAppearsIsNotAHit() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }
		rig.controller.debugLiveWindowBoundsOverride = { _ in nil }

		// Nothing to compare against: a window with no earlier sample is not a
		// window that moved, however close to her it lands.
		rig.platform.setWindows([
			Self.window(bounds: PixelRect(x: 700, y: 600, width: 500, height: 500))
		])
		stepToNextBodySample(rig)

		#expect(rig.controller.debugState.state != .falling)
		#expect(rig.controller.debugState.fallReason != "WindowSideImpact")
	}

	@Test("While a box holds her, a window sweeping past is not a hit on her")
	func noSideImpactInsideABox() throws {
		let rig = try makeRig()
		defer { try? FileManager.default.removeItem(at: rig.directory) }

		drop(rig, at: PixelPoint(x: 900, y: 900))
		#expect(rig.controller.debugState.enclosureWindowID == Self.windowID)

		// Swept sideways, which from the outside is exactly the sweep she would be
		// thrown clear of. The box is the whole world in there; the collision pass
		// must not add a second set of rules on top of it.
		for tick in 0..<30 {
			let box = PixelRect(
				x: Self.box.x + Double(tick) * 8,
				y: Self.box.y,
				width: Self.box.width,
				height: Self.box.height
			)
			rig.controller.debugLiveWindowBoundsOverride = { _ in box }
			rig.platform.setWindows([Self.window(bounds: box)])
			rig.controller.debugStep(delta: Self.frame)
			#expect(
				rig.controller.debugState.enclosureWindowID == Self.windowID,
				"ejected at tick \(tick)"
			)
		}
	}
}
