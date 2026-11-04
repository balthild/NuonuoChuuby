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
/// The window is a plain window the size of the icon, placed once: the icon stands
/// where the file was and never moves, so nothing here has to follow anything.
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

	public private(set) var isDismissed = false

	public init(displaySpace: DisplaySpace) {
		self.displaySpace = displaySpace
		panel = PetChromePanel(contentRect: .zero, ignoresMouseEvents: true)
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
		place()
	}

	/// Moves and reshapes the icon for one frame of the meal animation.
	public func update(_ visual: MealConsumptionVisual) {
		guard !isDismissed else { return }
		center = visual.center
		layer.opacity = Float(visual.opacity)
		layer.transform = GhostIconStyle.animationTransform(visual)
		place()
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

	/// Puts the window on the icon's square.
	///
	/// The ghost appears where the file was and does not move, so this reshapes it on the
	/// first frame and does nothing after: the shiver is a transform on the layer, not a
	/// move of the window.
	private func place() {
		let side = NSSize(width: size, height: size)
		let rect = PixelRect(
			x: center.x - size / 2,
			y: center.y - size / 2,
			width: size,
			height: size
		)
		let target = DisplaySpace.toAppKit(rect, primaryHeight: displaySpace.primaryHeight)
		if panel.frame != target {
			panel.setFrame(target, display: false)
		}

		layer.contentsScale = scale(at: center)
		layer.bounds = CGRect(origin: .zero, size: side)
		layer.position = CGPoint(x: side.width / 2, y: side.height / 2)
		panel.orderFrontRegardless()
	}

	private func scale(at point: PixelPoint) -> CGFloat {
		displaySpace.display(containing: point)?.scale ?? displaySpace.displays.first?.scale ?? 1
	}
}
