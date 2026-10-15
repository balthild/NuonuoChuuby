import AppKit
import QuartzCore
import Testing

@testable import NuonuoChuubyCore

/// The fake icon drawn as a layer of the pet's overlay. It is placed in global
/// top-left coordinates but lives in one display's own space, so the display's
/// origin has to come back out of it.
@MainActor
@Suite("Overlay ghost icon")
struct OverlayGhostIconTests {
	private final class Host: GhostIconLayerHosting {
		/// Settable, so a test can stand in for a display change rebuilding the
		/// overlay the icon was attached to.
		var parent = CALayer()
		var displayFrame: PixelRect
		var scale: CGFloat = 2

		init(displayFrame: PixelRect = PixelRect(x: 0, y: 0, width: 1728, height: 1117)) {
			self.displayFrame = displayFrame
		}

		func ghostIconLayerTarget(at point: PixelPoint) -> GhostIconLayerTarget? {
			GhostIconLayerTarget(parent: parent, displayFrame: displayFrame, scale: scale)
		}
	}

	private func attachedLayer(_ host: Host) -> CALayer? {
		host.parent.sublayers?.first
	}

	@Test("The icon is centred where the deleted one was")
	func iconIsPlacedAtTheAnchor() {
		let host = Host()
		let ghost = OverlayGhostIcon(host: host)
		ghost.show(icon: nil, at: PixelPoint(x: 500, y: 300), size: 56)

		let layer = try! #require(attachedLayer(host))
		#expect(layer.superlayer === host.parent)
		#expect(layer.position == CGPoint(x: 500, y: 300))
		#expect(layer.bounds.size == CGSize(width: 56, height: 56))
		#expect(layer.contentsScale == 2)
		#expect(!layer.isHidden)
	}

	/// A display left of the primary has a negative origin, so the placement has to
	/// be shifted into that overlay's own space.
	@Test("A display with a negative origin shifts the placement")
	func negativeDisplayOriginIsSubtracted() {
		let host = Host(displayFrame: PixelRect(x: -1920, y: -200, width: 1920, height: 1080))
		let ghost = OverlayGhostIcon(host: host)
		ghost.show(icon: nil, at: PixelPoint(x: -1500, y: 100), size: 40)

		let layer = try! #require(attachedLayer(host))
		#expect(layer.position == CGPoint(x: 420, y: 300))
	}

	@Test("Hiding takes it off screen but keeps it for a later show")
	func hideKeepsTheIcon() {
		let host = Host()
		let ghost = OverlayGhostIcon(host: host)
		ghost.show(icon: nil, at: PixelPoint(x: 10, y: 20), size: 40)
		ghost.hide()

		let layer = try! #require(attachedLayer(host))
		#expect(layer.isHidden)

		ghost.show(icon: nil, at: PixelPoint(x: 30, y: 40), size: 40)
		#expect(!layer.isHidden)
		#expect(layer.position == CGPoint(x: 30, y: 40))
	}

	/// The icon is dismissed when the meal it stands for is over, and the fade that
	/// follows takes its layer out of the tree and puts its opacity back. A dismissed
	/// icon stays in the presenter's list until the next meal prunes it, so an overlay
	/// rebuilt during that window used to hand it a fresh parent — a fully opaque ghost
	/// with nothing left to take it down.
	///
	/// The wait is what makes this the real sequence rather than a race with the fade:
	/// the fade has already finished when the overlay is rebuilt.
	@Test("A dismissed icon is not put back by a display change")
	func dismissedIconIsNotReattached() async throws {
		let host = Host()
		let ghost = OverlayGhostIcon(host: host)
		ghost.show(icon: nil, at: PixelPoint(x: 10, y: 20), size: 40)
		ghost.fadeOut()
		try await Task.sleep(nanoseconds: 500_000_000)

		host.parent = CALayer()
		ghost.rebind()

		#expect(host.parent.sublayers == nil)
	}
}
