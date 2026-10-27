import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The three dots that hold the overlay's shape at full size.
///
/// They exist because a Space transition freezes the **bounding box** of a window's
/// opaque pixels: with only her sprite opaque, everything that moves out of where she was
/// is cut off. The dots make the box the window, while clicks keep being routed per pixel
/// — measured with a probe, which is what makes this combination possible at all.
/// See `Docs/Internal/rendering.md`.
@MainActor
@Suite("Overlay shape corners")
struct OverlayShapeCornerTests {
	private typealias Dot = (origin: CGPoint, size: CGSize)

	private let size = CGSize(width: 1728, height: 1117)

	/// The box the window server would see: the dots are the extreme opaque pixels.
	private func boundingBox(of dots: [Dot]) -> CGRect? {
		guard let first = dots.first else { return nil }
		var box = CGRect(origin: first.origin, size: first.size)
		for dot in dots.dropFirst() {
			box = box.union(CGRect(origin: dot.origin, size: dot.size))
		}
		return box
	}

	@Test("Three dots: two at the bottom, one at the top centre")
	func threeDots() {
		let dots = OverlayPetWindowController.shapeCorners(in: size)
		#expect(dots.count == 3)

		let atBottom = dots.filter { $0.origin.y > size.height / 2 }
		#expect(atBottom.count == 2, "two at the bottom")
		#expect(atBottom.contains { $0.origin.x < size.width / 2 }, "one bottom left")
		#expect(atBottom.contains { $0.origin.x > size.width / 2 }, "one bottom right")

		let top = dots.filter { $0.origin.y <= size.height / 2 }
		#expect(top.count == 1, "one at the top")
		#expect(
			abs(top[0].origin.x + top[0].size.width / 2 - size.width / 2) < 1,
			"the top dot is centred, where the menu bar holds nothing"
		)
	}

	@Test("Nothing sits in the top corners, where the Apple menu and Notification Centre are")
	func topCornersAreFree() {
		let side: CGFloat = 2
		for dot in OverlayPetWindowController.shapeCorners(in: size)
		where dot.origin.y < size.height / 2 {
			#expect(dot.origin.x > side * 4, "a dot is near the top left corner")
			#expect(dot.origin.x + dot.size.width < size.width - side * 4, "near the top right")
		}
	}

	@Test("The dots are clear of every display edge, where a pointer stops")
	func dotsAreInsetFromTheEdges() {
		let inset = OverlayPetWindowController.shapeCornerInset
		#expect(inset > 0, "a dot on an edge would be easy to click")

		for dot in OverlayPetWindowController.shapeCorners(in: size) {
			#expect(dot.origin.x >= inset, "a dot is on the left edge")
			#expect(dot.origin.x + dot.size.width <= size.width - inset, "on the right edge")
			#expect(dot.origin.y >= inset, "on the top edge")
			#expect(dot.origin.y + dot.size.height <= size.height - inset, "on the bottom edge")
		}
	}

	@Test("Their bounding box is the window, inset by exactly one dot's clearance")
	func boundingBoxCoversTheWindowLessTheInset() throws {
		// The box is what a transition freezes, so it has to reach every edge she can be
		// seen at. It stops `shapeCornerInset` short on all four sides on purpose — that is
		// the price of not putting a dot anywhere a pointer can stop.
		let inset = OverlayPetWindowController.shapeCornerInset
		for size in [
			CGSize(width: 1728, height: 1117),
			CGSize(width: 1440, height: 900),
			CGSize(width: 5120, height: 1440),
		] {
			let box = try #require(boundingBox(of: OverlayPetWindowController.shapeCorners(in: size)))

			#expect(box.minX == inset, "at \(Int(size.width))×\(Int(size.height))")
			#expect(box.minY == inset, "at \(Int(size.width))×\(Int(size.height))")
			#expect(box.maxX == size.width - inset, "at \(Int(size.width))×\(Int(size.height))")
			#expect(box.maxY == size.height - inset, "at \(Int(size.width))×\(Int(size.height))")
		}
	}

	@Test("Every dot sits inside the window, so none of it is clipped away")
	func dotsAreInsideTheWindow() {
		for dot in OverlayPetWindowController.shapeCorners(in: size) {
			#expect(dot.origin.x >= 0 && dot.origin.y >= 0)
			#expect(dot.origin.x + dot.size.width <= size.width)
			#expect(dot.origin.y + dot.size.height <= size.height)
		}
	}

	@Test("A window too small to hold the dots gets none, rather than an inverted one")
	func tinyWindowsGetNoDots() {
		#expect(OverlayPetWindowController.shapeCorners(in: CGSize(width: 1, height: 1)).isEmpty)
		#expect(OverlayPetWindowController.shapeCorners(in: .zero).isEmpty)
	}

	@Test("The dots are as close to invisible as an 8-bit channel allows")
	func alphaIsOneStep() {
		// One step is the least that can be part of the shape; anything more starts to be
		// visible as a darkening of the display.
		#expect(OverlayPetWindowController.shapeCornerAlpha > 0)
		#expect(OverlayPetWindowController.shapeCornerAlpha <= 1.0 / 255.0)
	}
}
