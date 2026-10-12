import Foundation
import Testing

@testable import NuonuoChuubyCore

@Suite("Window terrain eligibility")
struct WindowTerrainEligibilityTests {
	private let workArea = PixelRect(x: 0, y: 25, width: 1440, height: 875)

	private func window(
		number: UInt32 = 1, pid: Int32 = 500, owner: String = "Safari",
		x: Double = 200, y: Double = 200, width: Double = 800, height: Double = 600,
		layer: Int = 0, alpha: Double = 1
	) -> PlatformWindow {
		PlatformWindow(
			id: number, ownerPID: pid, ownerName: owner,
			bounds: PixelRect(x: x, y: y, width: width, height: height),
			layer: layer, alpha: alpha)
	}

	@Test("An ordinary app window is a platform")
	func ordinaryWindow() {
		#expect(WindowTerrainEligibilityPolicy.isEligiblePlatform(
			window(), ownPID: 1, workArea: workArea))
	}

	@Test("Our own windows are never terrain")
	func ownWindowsExcluded() {
		#expect(!WindowTerrainEligibilityPolicy.isEligiblePlatform(
			window(), ownPID: 500, workArea: workArea))
	}

	@Test("Raised and lowered windows are chrome, not terrain")
	func nonZeroLayerExcluded() {
		#expect(!WindowTerrainEligibilityPolicy.isEligiblePlatform(
			window(layer: 25), ownPID: 1, workArea: workArea))
		#expect(!WindowTerrainEligibilityPolicy.isEligiblePlatform(
			window(layer: -1), ownPID: 1, workArea: workArea))
	}

	@Test("System chrome owners are excluded")
	func systemOwnersExcluded() {
		for owner in ["Dock", "Window Server", "Control Center", "WindowManager"] {
			#expect(!WindowTerrainEligibilityPolicy.isEligiblePlatform(
				window(owner: owner), ownPID: 1, workArea: workArea), "\(owner) should be excluded")
		}
	}

	@Test("Tiny or fully transparent windows are excluded")
	func tinyAndInvisible() {
		#expect(!WindowTerrainEligibilityPolicy.isEligiblePlatform(
			window(width: 100), ownPID: 1, workArea: workArea))
		#expect(!WindowTerrainEligibilityPolicy.isEligiblePlatform(
			window(height: 40), ownPID: 1, workArea: workArea))
		#expect(!WindowTerrainEligibilityPolicy.isEligiblePlatform(
			window(alpha: 0), ownPID: 1, workArea: workArea))
	}

	@Test("A window hidden under the menu bar is unreachable")
	func underTheMenuBar() {
		#expect(!WindowTerrainEligibilityPolicy.isEligiblePlatform(
			window(y: 0), ownPID: 1, workArea: workArea))
	}

	@Test("An unnamed owner is not trusted as terrain")
	func unnamedOwner() {
		#expect(!WindowTerrainEligibilityPolicy.isEligiblePlatform(
			window(owner: ""), ownPID: 1, workArea: workArea))
	}
}

@Suite("Window terrain surfaces")
@MainActor
struct WindowSurfaceTests {
	@Test("A window top becomes a standable surface")
	func windowBecomesSurface() {
		let displaySpace = DisplaySpace()
		guard let display = displaySpace.displays.first else { return }
		let area = display.visibleFrame
		let terrain = PlatformWindow(
			id: 7, ownerPID: 500, ownerName: "Safari",
			bounds: PixelRect(x: area.left + 100, y: area.top + 200, width: 800, height: 500),
			layer: 0, alpha: 1)

		let surfaces = WindowSurfaceProvider.surfaces(from: [terrain], displaySpace: displaySpace)
		let surface = surfaces.first { $0.sourceID == 7 }
		#expect(surface != nil)
		#expect(surface?.isDesktopFloor == false)
		#expect(surface?.top == area.top + 200)
		#expect(surface?.bottom == area.top + 700)
	}
}

@Suite("Terrain behaviour planner")
struct TerrainBehaviorPlannerTests {
	@Test("A desktop floor mostly turns around, sometimes hops")
	func desktopFloor() {
		var hops = 0
		for step in 0..<1000 {
			let action = TerrainBehaviorPlanner.chooseAtEdge(
				isDesktopFloor: true, randomUnit: Double(step) / 1000)
			if action == .hop { hops += 1 }
		}
		#expect(hops == 220)
	}

	@Test("A window top also offers slide and jump down")
	func windowTop() {
		let actions = (0..<1000).map {
			TerrainBehaviorPlanner.chooseAtEdge(isDesktopFloor: false, randomUnit: Double($0) / 1000)
		}
		#expect(actions.filter { $0 == .hop }.count == 200)
		#expect(actions.filter { $0 == .slideDown }.count == 140)
		#expect(actions.filter { $0 == .jumpDown }.count == 140)
		#expect(actions.filter { $0 == .turnAround }.count == 520)
	}

	@Test("Random input is clamped rather than trapping")
	func clampedInput() {
		#expect(TerrainBehaviorPlanner.chooseAtEdge(isDesktopFloor: false, randomUnit: 5) == .turnAround)
		#expect(TerrainBehaviorPlanner.chooseAtEdge(isDesktopFloor: true, randomUnit: -5) == .hop)
	}
}

@Suite("Window climb planner")
struct WindowClimbPlannerTests {
	private func surface(
		id: UInt32?, top: Double, left: Double = 200, right: Double = 900, floor: Bool = false
	) -> SupportSurface {
		SupportSurface(top: top, left: left, right: right, bottom: top + 500, isDesktopFloor: floor, sourceID: id)
	}

	@Test("A higher window directly above is climbable")
	func climbableTarget() {
		let ground = surface(id: nil, top: 900, left: 0, right: 1440, floor: true)
		let target = surface(id: 42, top: 500)
		let plan = WindowClimbPlanner.choose(
			surfaces: [target, ground], currentSupport: ground, footX: 700, scale: 1, randomUnit: 0)
		#expect(plan != nil)
		#expect(plan?.targetSurfaceID == 42)
		#expect(plan?.height == 400)
		#expect(plan?.targetTop == 500)
	}

	@Test("Nothing is chosen when no window is above")
	func noTargetAbove() {
		let ground = surface(id: nil, top: 900, left: 0, right: 1440, floor: true)
		let below = surface(id: 42, top: 1400)
		#expect(WindowClimbPlanner.choose(
			surfaces: [below, ground], currentSupport: ground, footX: 700, scale: 1, randomUnit: 0) == nil)
	}

	@Test("A target too small to stand on is rejected")
	func tooShort() {
		let ground = surface(id: nil, top: 900, left: 0, right: 1440, floor: true)
		let target = surface(id: 42, top: 870)
		#expect(WindowClimbPlanner.choose(
			surfaces: [target, ground], currentSupport: ground, footX: 700, scale: 1, randomUnit: 0) == nil)
	}

	@Test("The surface being stood on is never its own climb target")
	func excludesCurrentSupport() {
		// A wide floor with a narrower window floating above it, which is what a
		// real approach looks like: the wall's foot is on the floor she is on.
		let current = surface(id: 42, top: 900, left: 0, right: 1440)
		let other = surface(id: 43, top: 500)
		let plan = WindowClimbPlanner.choose(
			surfaces: [current, other], currentSupport: current, footX: 500, scale: 1, randomUnit: 0)
		#expect(plan?.targetSurfaceID == 43)
	}

	@Test("Climb duration is bounded at both ends")
	func durationBounds() {
		#expect(WindowClimbPlanner.climbDuration(height: 10, scale: 1, speedMultiplier: 1) == 2.0)
		#expect(WindowClimbPlanner.climbDuration(height: 5_000, scale: 1, speedMultiplier: 1) == 6.4)
	}
}
