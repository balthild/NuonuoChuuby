import AppKit
import QuartzCore

/// Where an overlay-drawn ghost icon puts its layer.
public struct GhostIconLayerTarget {
	/// The layer inside one overlay window to add the icon's layer to.
	public let parent: CALayer
	/// That overlay's display frame, to convert the global centre into the
	/// overlay's own coordinates.
	public let displayFrame: PixelRect
	/// The display's backing scale, to rasterise the icon at.
	public let scale: CGFloat
}

/// Supplies the layer an overlay ghost icon attaches to.
@MainActor
public protocol GhostIconLayerHosting: AnyObject {
	/// The overlay that holds `point` (global, Y-down), or `nil` when no display
	/// does.
	func ghostIconLayerTarget(at point: PixelPoint) -> GhostIconLayerTarget?
}

/// Draws a deleted item's fake icon as a `CALayer` inside the pet's full-display
/// overlay, instead of as a panel of its own.
///
/// The panel it replaces had to be created, ordered in and moved on the window
/// server for every meal; a sublayer is composited with the pet she is walking
/// towards, inside a window that never moves.
@MainActor
public final class OverlayGhostIcon: GhostIconPresenting {
	/// Everything the icon never animates. `opacity` is deliberately absent, so the
	/// fade-out is the one implicit animation it does get.
	private static let noActions: [String: CAAction] = [
		"position": NSNull(),
		"bounds": NSNull(),
		"contents": NSNull(),
		"contentsScale": NSNull(),
		"hidden": NSNull(),
	]

	private static let fadeDuration: CFTimeInterval = 0.25

	private let host: any GhostIconLayerHosting
	private let layer = CALayer()
	private var center: PixelPoint = .zero
	private var size: Double = 0

	/// Set once the icon has been dismissed, so the presenter that owns it can drop
	/// it from its list.
	private(set) var isDismissed = false

	init(host: any GhostIconLayerHosting) {
		self.host = host
		layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
		layer.contentsGravity = .resize
		layer.minificationFilter = .linear
		layer.magnificationFilter = .linear
		layer.isOpaque = false
		layer.actions = Self.noActions
		layer.isHidden = true
	}

	/// Re-attaches to the overlay after a display change rebuilt it. A no-op when
	/// the icon is not on screen.
	func rebind() {
		guard !layer.isHidden else { return }
		attach()
	}

	public func show(icon: NSImage?, at center: PixelPoint, size: Double) {
		self.center = center
		self.size = size
		layer.contents = icon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
		layer.opacity = 1
		layer.isHidden = false
		attach()
	}

	public func fadeOut() {
		isDismissed = true
		let layer = self.layer
		CATransaction.begin()
		CATransaction.setAnimationDuration(Self.fadeDuration)
		CATransaction.setCompletionBlock {
			layer.removeFromSuperlayer()
			layer.opacity = 1
		}
		layer.opacity = 0
		CATransaction.commit()
	}

	public func hide() {
		layer.isHidden = true
	}

	private func attach() {
		guard let target = host.ghostIconLayerTarget(at: center) else { return }
		if layer.superlayer !== target.parent {
			layer.removeFromSuperlayer()
			target.parent.addSublayer(layer)
		}
		layer.contentsScale = target.scale
		layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
		let local = OverlayPetGeometry.localTopLeft(center, in: target.displayFrame)
		layer.position = CGPoint(x: local.x, y: local.y)
	}
}
