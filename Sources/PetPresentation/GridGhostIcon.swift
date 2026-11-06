import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation
import QuartzCore

/// Draws a deleted file's fake icon in a window of its own, for the grid renderer.
///
/// The overlay draws the ghost as a layer of the window that already covers the
/// display. This one has to have a window, because the icon stands where the file was,
/// which can be anywhere on the display and is usually nowhere near her.
///
/// The window is an empty box shaped around the whole thing the icon will do — it appears
/// where the file was, and then, once she starts chewing, shivers and is drawn into her
/// mouth. **The box does not follow the icon.** A layer's position is free and a window's
/// is not (`performance.md`, "拖动 vs `setFrame`"), so the box is reshaped only when the
/// animation's own extent changes and the icon moves inside it. What keeps it over her
/// while that happens is its level, not an order re-asserted on every frame: see
/// ``PetChromePanel/ghostPanelLevel``.
@MainActor
final class GridGhostIcon: GhostIconPresenting {
	/// Everything the icon never animates. `opacity` is deliberately absent, so the
	/// fade-out is the one implicit animation it does get.
	private static let noActions: [String: CAAction] = [
		"position": NSNull(),
		"bounds": NSNull(),
		"contents": NSNull(),
		"contentsScale": NSNull(),
		"hidden": NSNull(),
	]

	private let panel: PetChromePanel
	private let root: PetLayerHostView
	private let layer = CALayer()
	private let displaySpace: DisplaySpace

	private var center: PixelPoint = .zero
	private var size: Double = 0
	/// The extent the window is shaped for, in global top-left coordinates. The icon is
	/// drawn at an offset inside it rather than the window being moved onto the icon.
	private var box: PixelRect = .zero

	public private(set) var isDismissed = false

	public init(displaySpace: DisplaySpace) {
		self.displaySpace = displaySpace
		panel = PetChromePanel(
			contentRect: .zero,
			ignoresMouseEvents: true,
			level: PetChromePanel.ghostPanelLevel
		)
		panel.title = "pet ghost"
		root = PetLayerHostView(frame: .zero)
		root.wantsLayer = true
		// Flipped like the overlay's root, so the shiver's rotation turns the same way.
		root.layer?.isGeometryFlipped = true

		layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
		layer.contentsGravity = .resize
		layer.minificationFilter = .linear
		layer.magnificationFilter = .linear
		layer.isOpaque = false
		layer.actions = Self.noActions
		layer.isHidden = true
		root.layer?.addSublayer(layer)
		panel.contentView = root
	}

	/// The window outlives a display change here, so there is nothing to re-attach.
	public func rebind() {}

	public func show(icon: NSImage?, at center: PixelPoint, size: Double) {
		self.center = center
		self.size = size
		layer.contents = icon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
		layer.opacity = 1
		layer.transform = CATransform3DIdentity
		layer.isHidden = false
		// The icon's own square around the anchor. It grows to the animation's own extent on
		// the first frame of the chew — she can walk to the ghost for seconds before that, and
		// shrinking the box to the icon is what keeps it from covering what it passes over.
		// The window is empty either way, so the one reshape that follows is not something the
		// eye can catch.
		box = PixelRect(
			x: center.x - size / 2,
			y: center.y - size / 2,
			width: size,
			height: size
		)
		// Ordering a window in lets AppKit reassert the frame it believes in, so the real
		// position is put back afterwards — the same order her own window uses.
		panel.orderFrontRegardless()
		reshape(to: box)
		placeLayer()
	}

	/// Draws one frame of the meal animation.
	///
	/// The window is only reshaped when the animation's extent changes, which is once: the
	/// box is the same on every frame of the chew, which is what
	/// ``MealConsumptionAnimation/box(from:to:halfExtent:)`` guarantees. Everything after
	/// that is a layer move.
	public func update(_ visual: MealConsumptionVisual) {
		guard !isDismissed else { return }
		if let box = visual.box, box != self.box {
			reshape(to: box)
		}
		center = visual.center
		layer.opacity = Float(visual.opacity)
		layer.transform = GhostIconStyle.animationTransform(visual)
		placeLayer()
	}

	public func fadeOut() {
		isDismissed = true
		let layer = self.layer
		let panel = self.panel
		CATransaction.begin()
		CATransaction.setAnimationDuration(GhostIconStyle.fadeDuration)
		CATransaction.setCompletionBlock {
			panel.orderOut(nil)
			layer.opacity = 1
		}
		layer.opacity = 0
		CATransaction.commit()
	}

	public func hide() {
		layer.isHidden = true
		panel.orderOut(nil)
	}

	/// Puts the window on a new extent.
	///
	/// Called once per shape, never per frame: it is the `setFrame` this renderer used to do
	/// on every frame of the chew, which `performance.md` measures as the most expensive
	/// thing a window can be asked to do.
	private func reshape(to box: PixelRect) {
		self.box = box
		let target = DisplaySpace.toAppKit(box, primaryHeight: displaySpace.primaryHeight)
		if panel.frame != target {
			panel.setFrame(target, display: false)
		}
	}

	/// Draws the icon at its current centre, inside the box the window is shaped for.
	private func placeLayer() {
		let side = NSSize(width: size, height: size)
		layer.contentsScale = scale(at: center)
		layer.bounds = CGRect(origin: .zero, size: side)
		// The layer's anchor is its centre, so it wants the icon's centre in the window's own
		// space: the box's origin taken off the global centre. Doing it this way rather than
		// moving the window onto the icon is the whole point — the root is flipped like the
		// overlay's, so this offset is measured from the window's top-left like the rest.
		layer.position = CGPoint(x: center.x - box.x, y: center.y - box.y)
	}

	private func scale(at point: PixelPoint) -> CGFloat {
		displaySpace.display(containing: point)?.scale ?? displaySpace.displays.first?.scale ?? 1
	}
}
