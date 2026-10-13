import AppKit

/// Where an overlay-drawn bubble puts its raster.
public struct SpeechBubbleLayerTarget {
	/// The layer inside one overlay window to draw the bubble into.
	public let layer: CALayer
	/// That overlay's display frame, to convert the placement's global top-left
	/// into the overlay's own coordinates.
	public let displayFrame: PixelRect
	/// The display's backing scale, to rasterise at.
	public let scale: CGFloat
	/// Whether the display is in dark mode. The bubble's colours are dynamic, so
	/// the cached raster is only valid for one appearance.
	public let isDark: Bool
}

/// Supplies the layer to draw an overlay bubble into.
@MainActor
public protocol SpeechBubbleLayerHosting: AnyObject {
	/// The overlay that holds `point` (global, Y-down), or `nil` when no display
	/// does.
	func speechBubbleLayer(at point: PixelPoint) -> SpeechBubbleLayerTarget?
}

/// Draws the head bubble as a `CALayer` inside the pet's full-display overlay.
///
/// The bubble used to be a panel moved to follow her, and that move was the
/// expensive part: `setFrame` was measured at 12–13% of main-thread CPU while she
/// was falling, all of it inside the same frame that also moved the pet. A sublayer
/// is composited instead, so following her changes only its `position`, and the
/// raster is rebuilt only when the line, the tail, the size or the appearance
/// really changes.
@MainActor
public final class OverlaySpeechBubbleController: SpeechBubblePresenting {
	private let host: any SpeechBubbleLayerHosting
	private var hideWorkItem: DispatchWorkItem?

	private var visible = false
	private var text = ""
	/// Held weakly: the layer belongs to its overlay window, and a display change
	/// takes the whole overlay away with it.
	private weak var currentLayer: CALayer?
	private var raster: Raster?

	/// What the cached bitmap was made from. Anything else that changes the picture
	/// has to be added here, or the bubble keeps a stale one.
	private struct Raster: Equatable {
		let text: String
		let tail: SpeechBubbleTail
		let width: CGFloat
		let height: CGFloat
		let scale: CGFloat
		let isDark: Bool
	}

	public init(host: any SpeechBubbleLayerHosting) {
		self.host = host
	}

	public var isVisible: Bool { visible }

	public var currentText: String { text }

	public var tailHeight: Double { Double(SpeechBubbleDrawing.tailHeight) }

	public func bodySize(for text: String) -> (width: Double, height: Double) {
		let size = SpeechBubbleDrawing.bodySize(for: text)
		return (Double(size.width), Double(size.height))
	}

	public func show(
		_ text: String,
		placement: SpeechBubblePlacement,
		displaySpace: DisplaySpace,
		duration: Double
	) {
		guard !text.isEmpty else { return }
		visible = true
		apply(text: text, placement: placement)

		hideWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.hide() }
		hideWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
	}

	public func reposition(to placement: SpeechBubblePlacement, displaySpace: DisplaySpace) {
		guard visible else { return }
		apply(text: text, placement: placement)
	}

	public func hide() {
		hideWorkItem?.cancel()
		hideWorkItem = nil
		visible = false
		currentLayer?.isHidden = true
	}

	private func apply(text: String, placement: SpeechBubblePlacement) {
		guard let target = host.speechBubbleLayer(at: placement.topLeft) else { return }
		let previousLayer = currentLayer
		let layer = target.layer

		// Moving between displays hands the bubble to a different overlay, and the
		// one it left must not keep its copy on screen.
		if let previousLayer, previousLayer !== layer { previousLayer.isHidden = true }
		currentLayer = layer
		self.text = text
		layer.isHidden = false

		let size = SpeechBubbleDrawing.preferredSize(for: text, tail: placement.tail)
		let key = Raster(
			text: text,
			tail: placement.tail,
			width: size.width,
			height: size.height,
			scale: target.scale,
			isDark: target.isDark
		)
		// A layer that has never been drawn into has no contents whatever the key
		// says, which is what a display change looks like.
		if raster != key || previousLayer !== layer {
			layer.contents = SpeechBubbleDrawing.image(
				size: size,
				tail: placement.tail,
				text: text,
				scale: target.scale,
				isDark: target.isDark
			)
			layer.contentsScale = target.scale
			raster = key
		}

		layer.bounds = CGRect(origin: .zero, size: size)
		let local = OverlayPetGeometry.localTopLeft(placement.topLeft, in: target.displayFrame)
		layer.position = CGPoint(x: local.x, y: local.y)
	}
}
