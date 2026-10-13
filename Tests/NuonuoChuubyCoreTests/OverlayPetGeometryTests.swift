import Testing

@testable import NuonuoChuubyCore

@Suite("Overlay pet geometry")
struct OverlayPetGeometryTests {
	private func monitor(
		_ id: UInt32,
		_ x: Double,
		_ y: Double,
		_ width: Double,
		_ height: Double
	)
		-> Monitor
	{
		let frame = PixelRect(x: x, y: y, width: width, height: height)
		return Monitor(id: id, frame: frame, visibleFrame: frame, scale: 2)
	}

	private func pet(_ x: Double, _ y: Double, _ size: Double = 220) -> PixelRect {
		PixelRect(x: x, y: y, width: size, height: size)
	}

	@Test("A pet on the primary display keeps its global coordinates")
	func localFrameOnThePrimaryDisplay() {
		let display = PixelRect(x: 0, y: 0, width: 1728, height: 1117)
		let local = OverlayPetGeometry.localPetFrame(petFrame: pet(600, 400), displayFrame: display)
		#expect(local == pet(600, 400))
	}

	/// A display left of (or above) the primary has a negative origin in global
	/// top-left coordinates, so the overlay's own space has to be shifted by it.
	@Test("A display left of the primary shifts the pet back into its own space")
	func localFrameOnADisplayWithNegativeOrigin() {
		let display = PixelRect(x: -1920, y: -200, width: 1920, height: 1080)
		let local = OverlayPetGeometry.localPetFrame(petFrame: pet(-1500, 100), displayFrame: display)
		#expect(local == pet(420, 300))
	}

	/// She may hang off her display's left edge; the result is then negative. The
	/// overlay must not clamp it, or she would be drawn inside the screen instead.
	@Test("A pet off the display's left edge keeps a negative local origin")
	func localFramePastTheDisplayEdge() {
		let display = PixelRect(x: 0, y: 0, width: 1728, height: 1117)
		let local = OverlayPetGeometry.localPetFrame(petFrame: pet(-80, 400), displayFrame: display)
		#expect(local.x == -80)
		#expect(local.width == 220)
	}

	@Test("The overlay holding her centre is the one she is drawn into")
	func hostingDisplayIsTheOneWithHerCentre() {
		let displays = [monitor(1, 0, 0, 1728, 1117), monitor(2, -1920, 0, 1920, 1080)]
		#expect(OverlayPetGeometry.hostingDisplayIndex(for: pet(1500, 400), displays: displays) == 0)
		#expect(OverlayPetGeometry.hostingDisplayIndex(for: pet(-1900, 400), displays: displays) == 1)
	}

	/// Her top reaches into the menu bar, which the display's *full* bounds cover
	/// and its visible frame does not — the overlay has to be the full frame.
	@Test("A pet in the menu bar strip still belongs to that display")
	func hostingDisplayIncludesTheMenuBarStrip() {
		let displays = [monitor(1, 0, 0, 1728, 1117)]
		#expect(OverlayPetGeometry.hostingDisplayIndex(for: pet(600, 2), displays: displays) == 0)
	}

	@Test("A pet past every display is still drawn somewhere")
	func hostingFallsBackToTheFirstDisplay() {
		let displays = [monitor(1, 0, 0, 1728, 1117)]
		#expect(OverlayPetGeometry.hostingDisplayIndex(for: pet(9000, 9000), displays: displays) == 0)
	}

	@Test("No displays means no overlay")
	func hostingIsNilWithoutDisplays() {
		#expect(OverlayPetGeometry.hostingDisplayIndex(for: pet(600, 400), displays: []) == nil)
	}

	/// The bubble is placed globally but drawn into one overlay's layer, so the
	/// placement has to come back into that overlay's own space.
	@Test("A global point is shifted by the display's origin")
	func localPointIsTranslatedByTheDisplayOrigin() {
		let display = PixelRect(x: -1920, y: -200, width: 1920, height: 1080)
		let local = OverlayPetGeometry.localTopLeft(PixelPoint(x: -1500, y: 100), in: display)
		#expect(local == PixelPoint(x: 420, y: 300))
	}

	@Test("The overlay holding a point is the one that contains it")
	func hostingADisplayForAPointUsesThePointItself() {
		let displays = [monitor(1, 0, 0, 1728, 1117), monitor(2, -1920, 0, 1920, 1080)]
		#expect(
			OverlayPetGeometry.hostingDisplayIndex(for: PixelPoint(x: 10, y: 10), displays: displays) == 0
		)
		#expect(
			OverlayPetGeometry.hostingDisplayIndex(
				for: PixelPoint(x: -1900, y: 400),
				displays: displays
			) == 1
		)
	}

	@Test("A point past every display still lands on the first")
	func hostingAPointFallsBackToTheFirstDisplay() {
		let displays = [monitor(1, 0, 0, 1728, 1117)]
		#expect(
			OverlayPetGeometry.hostingDisplayIndex(
				for: PixelPoint(x: 9000, y: 9000),
				displays: displays
			) == 0
		)
	}

	@Test("No displays means no overlay for a point either")
	func hostingAPointIsNilWithoutDisplays() {
		#expect(
			OverlayPetGeometry.hostingDisplayIndex(for: PixelPoint(x: 10, y: 10), displays: []) == nil
		)
	}
}
