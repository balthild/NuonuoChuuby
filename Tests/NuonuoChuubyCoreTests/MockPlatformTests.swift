import Foundation
import Testing

@testable import NuonuoChuubyCore

/// Builds a desktop out of scripted windows and displays only — no window
/// server, no assets.
@MainActor
@Suite("Mock platform surfaces")
struct MockPlatformTests {
	private func window(
		id: UInt32, owner: String = "Safari",
		x: Double, y: Double, width: Double = 800, height: Double = 500,
		layer: Int = 0, alpha: Double = 1
	) -> PlatformWindow {
		PlatformWindow(
			id: id, ownerPID: 900 + Int32(id), ownerName: owner,
			bounds: PixelRect(x: x, y: y, width: width, height: height),
			layer: layer, alpha: alpha)
	}

	@Test("A scripted desktop yields the floor and each eligible window top")
	func scriptedDesktop() {
		let platform = MockPlatform.singleMonitor()
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: 900)
		#expect(space.displays.count == 1)

		platform.setWindows([
			window(id: 1, x: 100, y: 200),
			// Too narrow to stand on, so not terrain.
			window(id: 2, x: 100, y: 500, width: 40, height: 40),
		])

		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		let windowSurfaces = provider.surfaces.filter { $0.key.kind == .windowTop }
		#expect(windowSurfaces.count == 1)
		#expect(windowSurfaces.first?.key.owner == 1)
		#expect(windowSurfaces.first?.offset == 200)
		#expect(provider.floors.count == 1)
		#expect(provider.floors.first?.offset == space.displays[0].visibleFrame.bottom)
	}

	@Test("Chrome and raised windows are not terrain")
	func chromeIsNotTerrain() {
		let platform = MockPlatform.singleMonitor()
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: 900)
		platform.setWindows([
			window(id: 1, owner: "Dock", x: 100, y: 200),
			window(id: 2, x: 100, y: 300, layer: 3),
		])

		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		#expect(provider.surfaces.filter { $0.key.kind == .windowTop }.isEmpty)
	}

	@Test("The hidden part of an edge is not standable")
	func occludedEdgeNotStandable() {
		let platform = MockPlatform.singleMonitor(width: 1440, height: 900)
		let space = DisplaySpace(monitors: platform.monitors(), primaryHeight: 900)
		platform.setWindows([
			// Front, covering the left of the window behind.
			window(id: 2, x: 0, y: 300, width: 700, height: 500),
			// Behind: its top edge runs 100…1100, but only 700…1100 is visible.
			window(id: 1, x: 100, y: 400, width: 1000, height: 400),
		])

		let provider = SurfaceProvider(platform: platform)
		provider.refresh(displaySpace: space)

		let behind = provider.surfaces.first { $0.key == SurfaceKey(owner: 1, kind: .windowTop) }
		#expect(behind != nil)
		#expect(behind?.visible == [Span(start: 700, end: 1100)])
	}
}
