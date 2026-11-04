import AppKit
import PetDesktop
import PetFoundation
import QuartzCore

/// The full-display window she is drawn into while she is moving fast enough that keeping
/// a small window next to her would mean moving it every few frames — see
/// ``GridPetWindowController/wantsOverlaySurface``.
///
/// One window covering the union of every display, so a drag or a bounce that crosses
/// from one to another needs nothing to change. It is never moved, never resized once
/// shown, and it draws nothing but her and her bubble.
///
/// It **does** take input, and only over her: the root hit-tests her body ellipse and
/// answers nil everywhere else, so a click on the rest of the display goes to whatever is
/// behind, exactly as the overlay renderer does it. It has to, because this window can be
/// up while the pointer is free — inside a box she is drawn here for as long as the walls
/// are throwing her around — and a window that ignored the mouse would leave her visible
/// in it and impossible to click.
///
/// It is deliberately a flat window with two layers rather than a second presenter — the
/// only thing it has to draw is her and her bubble, and both are already layers.
@MainActor
final class OverlayPetSurface {
	let panel: PetChromePanel
	let root: OverlayPetRootView
	let pet = CALayer()
	let bubble = CALayer()

	/// The union of the displays, in the simulation's top-left space.
	///
	/// This is the frame every global point is converted against, so it is also what the
	/// bubble's host hands over as its `displayFrame`.
	private(set) var frame: PixelRect = .zero

	init() {
		panel = PetChromePanel(contentRect: .zero)
		panel.title = "pet overlay surface"
		root = OverlayPetRootView(frame: .zero)
		root.wantsLayer = true
		root.layerContentsRedrawPolicy = .never
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

	/// Puts her where she is, in the window's own coordinates, and tells the root where to
	/// hit-test her.
	func place(
		petFrame: PixelRect,
		size: Double,
		transform: CATransform3D,
		scale: CGFloat,
		bodyEllipse: CGRect
	) {
		let local = CGRect(
			x: petFrame.x - frame.x,
			y: petFrame.y - frame.y,
			width: size,
			height: size
		)
		pet.bounds = CGRect(origin: .zero, size: local.size)
		// The pivot is her bottom centre, as everywhere else: the lean rotates on the
		// ground rather than sliding her sideways.
		pet.position = CGPoint(x: local.midX, y: local.maxY)
		pet.contentsScale = scale
		pet.transform = transform
		// So a click on her works while this window is up, which it can be with the pointer
		// free — see the type's own note.
		root.petRect = local
		root.bodyEllipse = bodyEllipse
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
