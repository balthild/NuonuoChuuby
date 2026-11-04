import AppKit
import PetDesktop
import PetFoundation
import QuartzCore

/// The full-display window she is drawn into while she is moving fast enough that keeping
/// a small window next to her would mean moving it every few frames — see
/// ``PetPanelWindowController/wantsOverlaySurface``.
///
/// One window covering the union of every display, so a drag or a bounce that crosses
/// from one to another needs nothing to change. It is never moved, never resized once
/// shown, and takes no input: it exists so that those frames cost one layer position each
/// instead of a window move.
///
/// It is deliberately a flat window with two layers rather than a second presenter — the
/// only thing it has to draw is her and her bubble, and both are already layers.
@MainActor
final class PetOverlaySurface {
	let panel: PetChromePanel
	let root: PetLayerHostView
	let pet = CALayer()
	let bubble = CALayer()

	/// The union of the displays, in the simulation's top-left space.
	///
	/// This is the frame every global point is converted against, so it is also what the
	/// bubble's host hands over as its `displayFrame`.
	private(set) var frame: PixelRect = .zero

	init() {
		panel = PetChromePanel(contentRect: .zero, ignoresMouseEvents: true)
		panel.title = "pet drag surface"
		root = PetLayerHostView(frame: .zero)
		root.wantsLayer = true
		// The layers are positioned in the simulation's top-left space, like every other
		// root that holds her.
		root.layer?.isGeometryFlipped = true

		pet.anchorPoint = CGPoint(x: 0.5, y: 1)
		pet.actions = OverlayPetWindowController.petLayerActions
		bubble.anchorPoint = .zero
		bubble.actions = OverlayPetWindowController.bubbleLayerActions
		for layer in [pet, bubble] {
			layer.contentsGravity = .resize
			layer.minificationFilter = .linear
			layer.magnificationFilter = .linear
			layer.isOpaque = false
			layer.isHidden = true
			root.layer?.addSublayer(layer)
		}

		panel.contentView = root
	}

	/// Covers `space` and brings herself forward, leaving her layer hidden until a
	/// placement puts her somewhere.
	func show(covering space: DisplaySpace) {
		frame = Self.union(of: space.displays.map(\.frame))
		panel.setFrame(
			DisplaySpace.toAppKit(frame, primaryHeight: space.primaryHeight),
			display: false
		)
		pet.isHidden = false
		panel.orderFrontRegardless()
	}

	func hide() {
		pet.isHidden = true
		bubble.isHidden = true
		panel.orderOut(nil)
	}

	/// Puts her where she is, in the window's own coordinates.
	func place(petFrame: PixelRect, size: Double, transform: CATransform3D, scale: CGFloat) {
		pet.bounds = CGRect(x: 0, y: 0, width: size, height: size)
		// The pivot is her bottom centre, as everywhere else: the lean rotates on the
		// ground rather than sliding her sideways.
		pet.position = CGPoint(
			x: petFrame.x - frame.x + size / 2,
			y: petFrame.y - frame.y + size
		)
		pet.contentsScale = scale
		pet.transform = transform
	}

	/// The bounding box of every display, which is what the one window has to cover. It
	/// can start at a negative coordinate when a display sits left of or above the
	/// primary one.
	private static func union(of frames: [PixelRect]) -> PixelRect {
		guard let first = frames.first else { return .zero }
		var left = first.left
		var top = first.top
		var right = first.right
		var bottom = first.bottom
		for frame in frames.dropFirst() {
			left = min(left, frame.left)
			top = min(top, frame.top)
			right = max(right, frame.right)
			bottom = max(bottom, frame.bottom)
		}
		return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
	}
}
