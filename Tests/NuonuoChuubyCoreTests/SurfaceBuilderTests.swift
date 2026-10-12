import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The one-dimensional occlusion subtraction, ported from Ledgeling's world
/// tests. These are the cases that decide whether the pet can stand on an edge
/// she cannot see.
@Suite("Surface builder occlusion")
struct SurfaceBuilderTests {
	private let monitor = Monitor(
		id: 99,
		frame: PixelRect(x: 0, y: 0, width: 1440, height: 900),
		visibleFrame: PixelRect(x: 0, y: 25, width: 1440, height: 875),
		scale: 1)

	private func window(id: UInt32, x: Double, y: Double, w: Double, h: Double) -> PlatformWindow {
		PlatformWindow(
			id: id, ownerPID: 900, ownerName: "App",
			bounds: PixelRect(x: x, y: y, width: w, height: h), layer: 0, alpha: 1)
	}

	private func build(_ windows: [PlatformWindow], monitors: [Monitor]? = nil) -> [Surface] {
		SurfaceBuilder.build(
			windows: windows, monitors: monitors ?? [monitor],
			isEligible: { window, monitor in
				WindowTerrainEligibilityPolicy.isEligiblePlatform(
					window, ownPID: 1, workArea: monitor.visibleFrame)
			})
	}

	/// The front-to-back list, so index 0 is the occluder.
	private func top(of id: UInt32, in graph: [Surface]) -> Surface? {
		graph.first { $0.key == SurfaceKey(owner: id, kind: .windowTop) }
	}

	@Test("Every edge of a window is built, and the floor alongside")
	func buildsAllEdges() {
		let graph = build([window(id: 1, x: 100, y: 200, w: 800, h: 500)])
		let kinds = Set(graph.filter { $0.key.owner == 1 }.map(\.key.kind))
		#expect(kinds == Set([.windowTop, .windowBottom, .windowLeft, .windowRight]))
		#expect(graph.contains { $0.key.kind == .floor })
	}

	@Test("A window behind does not hide the one in front of it")
	func behindDoesNotOcclude() {
		let front = window(id: 1, x: 0, y: 200, w: 600, h: 500)
		let behind = window(id: 2, x: 0, y: 200, w: 600, h: 500)
		let graph = build([front, behind])
		#expect(top(of: 1, in: graph)?.visible == [Span(start: 0, end: 600)])
	}

	@Test("A window in front hides the part of the edge it covers")
	func frontPartiallyOccludes() {
		let front = window(id: 1, x: 0, y: 200, w: 600, h: 500)
		let behind = window(id: 2, x: 100, y: 200, w: 1000, h: 500)
		let graph = build([front, behind])
		#expect(top(of: 2, in: graph)?.span == Span(start: 100, end: 1100))
		#expect(top(of: 2, in: graph)?.visible == [Span(start: 600, end: 1100)])
	}

	@Test("An occluder in the middle leaves two visible runs")
	func middleOccluderSplits() {
		let front = window(id: 1, x: 500, y: 200, w: 200, h: 500)
		let behind = window(id: 2, x: 100, y: 200, w: 1000, h: 500)
		let graph = build([front, behind])
		#expect(
			top(of: 2, in: graph)?.visible == [
				Span(start: 100, end: 500), Span(start: 700, end: 1100),
			])
	}

	@Test("A window with identical bounds to the one in front is fully hidden")
	func identicalBoundsFullyOccluded() {
		let front = window(id: 1, x: 200, y: 300, w: 800, h: 500)
		let behind = window(id: 2, x: 200, y: 300, w: 800, h: 500)
		let graph = build([front, behind])
		#expect(top(of: 2, in: graph)?.visible.isEmpty == true)
		#expect(top(of: 2, in: graph)?.isFullyOccluded == true)
		// The whole edge is still recorded, so a perch on it keeps its `t`.
		#expect(top(of: 2, in: graph)?.span == Span(start: 200, end: 1000))
	}

	@Test("A smaller window tucked inside a bigger one is fully hidden")
	func nestedFullyOccluded() {
		let front = window(id: 1, x: 0, y: 100, w: 1400, h: 700)
		let behind = window(id: 2, x: 300, y: 200, w: 400, h: 300)
		let graph = build([front, behind])
		#expect(top(of: 2, in: graph)?.visible.isEmpty == true)
	}

	@Test("An occluder that only overlaps vertically below the edge does not hide it")
	func occluderBelowEdgeDoesNotHide() {
		// The front window starts well below the back window's top edge.
		let front = window(id: 1, x: 0, y: 500, w: 1400, h: 300)
		let behind = window(id: 2, x: 100, y: 200, w: 1000, h: 500)
		let graph = build([front, behind])
		#expect(top(of: 2, in: graph)?.visible == [Span(start: 100, end: 1100)])
	}

	@Test("An ordinary window in front does hide the edge")
	func eligibleFrontOccludes() {
		let front = window(id: 1, x: 400, y: 200, w: 300, h: 500)
		let behind = window(id: 2, x: 100, y: 200, w: 1000, h: 500)
		let graph = build([front, behind])
		#expect(
			top(of: 2, in: graph)?.visible == [
				Span(start: 100, end: 400), Span(start: 700, end: 1100),
			])
	}

	@Test("A raised overlay in front does not hide the edge")
	func ineligibleFrontDoesNotOcclude() {
		// Our own pet panel: floating level, transparent, sitting right where the
		// pet is. Treating it as an occluder hid the edge she was landing on, so
		// she fell straight past every window.
		let overlay = PlatformWindow(
			id: 1, ownerPID: 900, ownerName: "NuonuoChuuby",
			bounds: PixelRect(x: 400, y: 200, width: 300, height: 300), layer: 3, alpha: 1)
		let behind = window(id: 2, x: 100, y: 200, w: 1000, h: 500)
		let graph = build([overlay, behind])
		#expect(top(of: 2, in: graph)?.visible == [Span(start: 100, end: 1100)])
	}

	@Test("A fully transparent window in front does not hide the edge")
	func transparentFrontDoesNotOcclude() {
		let overlay = PlatformWindow(
			id: 1, ownerPID: 900, ownerName: "HUD",
			bounds: PixelRect(x: 400, y: 200, width: 300, height: 300), layer: 0, alpha: 0.01)
		let behind = window(id: 2, x: 100, y: 200, w: 1000, h: 500)
		let graph = build([overlay, behind])
		#expect(top(of: 2, in: graph)?.visible == [Span(start: 100, end: 1100)])
	}

	@Test("A window whose top is under the menu bar yields no surface")
	func menuBarTopIneligible() {
		let graph = build([window(id: 1, x: 100, y: 10, w: 800, h: 500)])
		#expect(top(of: 1, in: graph) == nil)
	}

	@Test("Each monitor contributes its own floor")
	func oneFloorPerMonitor() {
		let second = Monitor(
			id: 2,
			frame: PixelRect(x: 1440, y: 0, width: 1920, height: 1080),
			visibleFrame: PixelRect(x: 1440, y: 25, width: 1920, height: 1055),
			scale: 1)
		let graph = build([], monitors: [monitor, second])
		let floors = graph.filter { $0.key.kind == .floor }
		#expect(floors.count == 2)
		#expect(floors.first { $0.key.owner == 2 }?.span == Span(start: 1440, end: 3360))
	}
}
