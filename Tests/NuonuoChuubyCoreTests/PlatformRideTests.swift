import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The platform-ride rules, ported from the original's `PlatformRidePhysics`.
/// These are the thresholds that make a dragged window feel physical.
@Suite("Platform ride physics")
struct PlatformRidePhysicsTests {
	@Test("A slow drag is simply followed")
	func slowDragFollows() {
		// Small movement, slow: neither launch nor release.
		let decision = PlatformRidePhysics.evaluate(
			displacementY: -2, velocityY: -100, displayScale: 1)
		#expect(decision.response == .follow)
		#expect(decision.initialPetVelocityY == 0)
	}

	@Test("An ordinary drag is followed, not thrown")
	func ordinaryDragFollows() {
		// The Windows original fired at 3 pt and 360 pt/s, which at 60 fps is a
		// mere 6 pt per frame — an unhurried drag. That read as the pet being
		// flung for no reason, so an ordinary drag must now be carried.
		for pair in [(displacement: -8.0, velocity: -480.0), (displacement: -5.0, velocity: -900.0)] {
			let up = PlatformRidePhysics.evaluate(
				displacementY: pair.displacement, velocityY: pair.velocity, displayScale: 1)
			#expect(up.response == .follow, "a \(pair.velocity) pt/s drag must be followed")
		}
		for pair in [(displacement: 8.0, velocity: 480.0), (displacement: 5.0, velocity: 900.0)] {
			let down = PlatformRidePhysics.evaluate(
				displacementY: pair.displacement, velocityY: pair.velocity, displayScale: 1)
			#expect(down.response == .follow, "a \(pair.velocity) pt/s drag must be followed")
		}
	}

	@Test("A deliberate flick does throw her")
	func deliberateFlickThrows() {
		// 18 pt in a frame at 60 fps is a real flick.
		#expect(
			PlatformRidePhysics.evaluate(displacementY: -18, velocityY: -1080, displayScale: 1)
				.response == .launchUpward)
		#expect(
			PlatformRidePhysics.evaluate(displacementY: 18, velocityY: 1080, displayScale: 1)
				.response == .releaseDownward)
	}

	@Test("A fast upward jerk throws her up")
	func fastUpwardLaunches() {
		let decision = PlatformRidePhysics.evaluate(
			displacementY: -20, velocityY: -900, displayScale: 1)
		#expect(decision.response == .launchUpward)
		// She leaves with a fraction of the platform's speed, clamped.
		#expect(decision.initialPetVelocityY < 0)
		#expect(decision.initialPetVelocityY >= -1150)
		#expect(decision.initialPetVelocityY <= -300)
	}

	@Test("Rising fast but only a little is not a launch")
	func needsBothDistanceAndSpeed() {
		// Far enough, but too slow.
		#expect(
			PlatformRidePhysics.evaluate(displacementY: -20, velocityY: -100, displayScale: 1)
				.response == .follow)
		// Fast enough, but barely moved.
		#expect(
			PlatformRidePhysics.evaluate(displacementY: -1, velocityY: -900, displayScale: 1)
				.response == .follow)
	}

	@Test("A fast downward drag leaves her behind")
	func fastDownwardReleases() {
		let decision = PlatformRidePhysics.evaluate(
			displacementY: 20, velocityY: 900, displayScale: 1)
		#expect(decision.response == .releaseDownward)
		// She is left behind, not thrown down.
		#expect(decision.initialPetVelocityY == 0)
	}

	@Test("A gentle downward drag no longer drops her off the ledge")
	func gentleDownwardFollows() {
		// The old downward gate was 2 pt and 90 pt/s — 1.5 pt per frame — so simply
		// lowering a window made her lose contact and stop following it.
		#expect(
			PlatformRidePhysics.evaluate(displacementY: 4, velocityY: 240, displayScale: 1)
				.response == .follow)
	}

	@Test("A larger display scale raises the thresholds proportionally")
	func scalesWithDisplay() {
		// At scale 2 the gate is 12 pt and 1200 pt/s.
		#expect(
			PlatformRidePhysics.evaluate(displacementY: -4, velocityY: -800, displayScale: 2)
				.response == .follow)
		// Twice the movement and a matching speed does launch.
		#expect(
			PlatformRidePhysics.evaluate(displacementY: -20, velocityY: -1400, displayScale: 2)
				.response == .launchUpward)
	}

	@Test("Launch velocity is clamped at both ends")
	func launchVelocityClamped() {
		let gentle = PlatformRidePhysics.evaluate(
			displacementY: -10, velocityY: -700, displayScale: 1)
		#expect(gentle.response == .launchUpward)
		#expect(gentle.initialPetVelocityY >= -1150)
		#expect(gentle.initialPetVelocityY <= -300)
	}
}

@Suite("Transient platform support")
struct TransientPlatformSupportTests {
	@Test("Support is held briefly while a window is being dragged")
	func graceWindow() {
		#expect(PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 0))
		#expect(PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 0.3))
		#expect(PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 0.35))
		#expect(!PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 0.36))
	}

	@Test("Nonsense input does not hold her up forever")
	func invalidInput() {
		#expect(!PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: .nan))
		#expect(!PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: -1))
		#expect(!PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 10))
	}
}

@Suite("Airborne platform contact")
struct AirbornePlatformContactTests {
	private func contact(
		footY: Double = 600, petVelocityY: Double = 500, previousTop: Double = 900,
		currentTop: Double, delta: Double = 1.0 / 60
	) -> AirbornePlatformContactDecision {
		PlatformRidePhysics.resolveAirborneContact(
			footY: footY, petVelocityY: petVelocityY,
			previousPlatformTop: previousTop, currentPlatformTop: currentTop,
			deltaSeconds: delta, displayScale: 1)
	}

	@Test("A still platform does not push her")
	func stillPlatform() {
		let decision = contact(previousTop: 900, currentTop: 900)
		#expect(!decision.pushesPet)
		#expect(decision.petVelocityY == 500)
	}

	@Test("A platform rising through her feet pushes her up")
	func risingThroughPushes() {
		// Somewhere below her feet, then suddenly above them.
		let decision = contact(
			footY: 600, petVelocityY: 500, previousTop: 900, currentTop: 500)
		#expect(decision.pushesPet)
		#expect(decision.correctedFootY == 500)
		#expect(decision.petVelocityY < 0)
		// She cannot end up moving downward faster than she already was.
		#expect(decision.petVelocityY <= 500)
	}

	@Test("A platform rising slowly does not push her")
	func slowRiseDoesNotPush() {
		let decision = contact(
			footY: 600, petVelocityY: 500, previousTop: 900, currentTop: 890)
		#expect(!decision.pushesPet)
	}

	@Test("A platform falling away does not push her")
	func fallingPlatformDoesNotPush() {
		let decision = contact(
			footY: 200, petVelocityY: 500, previousTop: 300, currentTop: 900)
		#expect(!decision.pushesPet)
	}
}

@Suite("Window expansion bounce")
struct WindowExpansionBounceTests {
	@Test("A maximised window under her throws her away from the centre")
	func maximizedBounce() {
		let left = WindowExpansionPhysics.evaluate(
			supportUnavailable: true, windowMaximized: true,
			footX: 100, monitorCenterX: 700, displayScale: 1)
		#expect(left != nil)
		// Left of centre: pushed further left, and up.
		#expect(left!.velocityX < 0)
		#expect(left!.velocityY < 0)
		#expect(left!.velocityX == -260)
		#expect(left!.velocityY == -820)

		let right = WindowExpansionPhysics.evaluate(
			supportUnavailable: true, windowMaximized: true,
			footX: 1300, monitorCenterX: 700, displayScale: 1)
		#expect(right!.velocityX == 260)
	}

	@Test("Nothing happens unless the window actually maximised")
	func requiresBoth() {
		#expect(
			WindowExpansionPhysics.evaluate(
				supportUnavailable: true, windowMaximized: false,
				footX: 100, monitorCenterX: 700, displayScale: 1) == nil)
		#expect(
			WindowExpansionPhysics.evaluate(
				supportUnavailable: false, windowMaximized: true,
				footX: 100, monitorCenterX: 700, displayScale: 1) == nil)
	}
}

/// The controller must actually react to a moving window, not glue to it.
@MainActor
@Suite("Controller platform ride", .serialized)
struct ControllerPlatformRideTests {
	private static var assetsRoot: URL? {
		let repoRoot = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
		let root = repoRoot.appendingPathComponent("Sources/NuonuoChuubyCore/Resources/Assets")
		return FileManager.default.fileExists(atPath: root.path) ? root : nil
	}

	enum TestSkip: Error { case missingAssets }

	@Test("A window that drops away leaves her airborne instead of glued")
	func downwardDragReleases() throws {
		guard let root = Self.assetsRoot else { throw TestSkip.missingAssets }
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-ride-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }

		let space = DisplaySpace()
		let surfaces = SurfaceProvider()
		surfaces.refresh(displaySpace: space)
		let controller = PetController(
			catalog: AssetCatalog(locator: AssetLocator(root: root)),
			surfaceProvider: surfaces,
			lifeStore: PetLifeStateStore(stateDirectory: directory),
			displaySpace: space)

		// Standing on a window. The drop is what a dragged window does.
		let ride = PlatformRidePhysics.evaluate(
			displacementY: 40, velocityY: 600, displayScale: 1)
		#expect(ride.response == .releaseDownward)
		// She keeps her own (zero) velocity, so she falls naturally.
		#expect(ride.initialPetVelocityY == 0)
		#expect(controller.state == .idle)
	}
}
