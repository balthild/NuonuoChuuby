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

		let windowSurfaces = provider.surfaces.filter { !$0.isDesktopFloor }
		#expect(windowSurfaces.count == 1)
		#expect(windowSurfaces.first?.sourceID == 1)
		#expect(windowSurfaces.first?.top == 200)
		#expect(provider.desktopFloors.count == 1)
		#expect(provider.desktopFloors.first?.top == space.displays[0].visibleFrame.bottom)
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

		#expect(provider.surfaces.filter { !$0.isDesktopFloor }.isEmpty)
	}
}
