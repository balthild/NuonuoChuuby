import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation
import QuartzCore

/// Draws a deleted file's fake icon in a window of its own, for the panel renderer.
///
/// The overlay draws the ghost as a layer of the window that already covers the
/// display. This one has to have a window, because the icon stands where the file was,
/// which can be anywhere on the display and is usually nowhere near her.
///
/// The window is moved through the private ``PetPanelMover``, like the pet's own panel,
/// so AppKit's frame goes stale — harmless here, because the ghost takes no input
/// (``ignoresMouseEvents``) and its position comes from the animation every frame
/// rather than from AppKit.
///
/// The icon shivers and shrinks by `transform` rather than by resizing the window, so
/// only the fade-out and the first placement actually reshape it.
@MainActor
final class PetPanelGhostIcon: GhostIconPresenting {
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
		panel.title = "pet panel ghost"
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
	/// Only the first frame reshapes it; the shiver is a transform, so every later frame
	/// is a move.
	private func place() {
		let side = NSSize(width: size, height: size)
		let rect = PixelRect(
			x: center.x - size / 2,
			y: center.y - size / 2,
			width: size,
			height: size
		)

		if panel.frame.size != side {
			panel.setFrame(
				DisplaySpace.toAppKit(rect, primaryHeight: displaySpace.primaryHeight),
				display: false
			)
		} else {
			PetPanelMover.move(
				windowID: UInt32(panel.windowNumber),
				to: PixelPoint(x: rect.x, y: rect.y)
			)
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
