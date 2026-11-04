import AppKit
import PetDesktop
import PetFoundation
import QuartzCore

/// The full-display window she is drawn into while she is moving fast enough that keeping
/// a small window next to her would mean moving it every few frames — see
/// ``GridPetWindowController/wantsOverlaySurface``.
///
/// One window covering the union of every display, so a drag or a bounce that crosses
/// from one to another needs nothing to change. It is never moved and never resized once
/// shown, and it draws nothing but her, her bubble, and the dots that hold its shape.
///
/// It **does** take input, and only over her: the root hit-tests her body ellipse and
/// answers nil everywhere else, so a click on the rest of the display goes to whatever is
/// behind, exactly as the overlay renderer does it. It has to, because this window can be
/// up while the pointer is free — inside a box she is drawn here for as long as the walls
/// are throwing her around — and a window that ignored the mouse would leave her visible
/// in it and impossible to click.
///
/// It is deliberately a flat window rather than a second presenter — the only things it
/// has to draw are her and her bubble, and both are already layers.
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

	/// The dots that hold this window's **shape** at its full size.
	///
	/// This window needed them and did not have them, which is why she used to be sliced
	/// across when a Space was switched while she was being drawn here: a transition freezes
	/// each window's shape — the bounding box of its opaque pixels — at the moment it begins
	/// and goes on drawing the contents, so a window whose shape is only her silhouette is
	/// cut the instant she moves out of it. She is drawn here exactly when she is moving
	/// fastest (see ``GridPetWindowController/wantsOverlaySurface``), so the two met often,
	/// and the dots the two renderers put up are what stops it. See
	/// ``PetLayerConventions/shapeCorners(in:)``.
	private var shapeDots: [CALayer] = []

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
		pet.actions = PetLayerConventions.petActions
		bubble.anchorPoint = .zero
		bubble.actions = PetLayerConventions.bubbleActions
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
		layoutShapeDots(in: CGSize(width: frame.width, height: frame.height))
		pet.isHidden = false
		panel.orderFrontRegardless()
	}

	/// Puts the shape-holding dots at the window's extremes, above her and her bubble.
	private func layoutShapeDots(in size: CGSize) {
		for dot in shapeDots { dot.removeFromSuperlayer() }
		shapeDots = PetLayerConventions.shapeCorners(in: size).map { corner in
			let dot = CALayer()
			dot.anchorPoint = .zero
			dot.bounds = CGRect(origin: .zero, size: corner.size)
			dot.position = corner.origin
			dot.backgroundColor = CGColor(
				red: 0,
				green: 0,
				blue: 0,
				alpha: PetLayerConventions.shapeCornerAlpha
			)
			dot.actions = PetLayerConventions.shapeCornerActions
			root.layer?.addSublayer(dot)
			return dot
		}
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
