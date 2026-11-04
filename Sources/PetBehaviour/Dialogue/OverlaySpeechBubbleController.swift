import AppKit
import PetDesktop
import PetFoundation

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

	/// Whether the window this layer is in was moved in this same frame.
	///
	/// The bubble is drawn at an offset inside that window, so a window move shifts its
	/// local position by the opposite amount just to keep it still on screen. That shift
	/// has to land in the frame that made it: the window move is not animatable, and an
	/// interpolated compensation would be seen sliding a whole window's worth back. The
	/// overlay's window never moves, so it leaves this false and glides as usual.
	public let landsInstantly: Bool

	public init(
		layer: CALayer,
		displayFrame: PixelRect,
		scale: CGFloat,
		isDark: Bool,
		landsInstantly: Bool = false
	) {
		self.layer = layer
		self.displayFrame = displayFrame
		self.scale = scale
		self.isDark = isDark
		self.landsInstantly = landsInstantly
	}
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

	/// The room the showing bubble occupies, or `nil` when nothing is showing.
	///
	/// A renderer that draws the bubble **inside the pet's own window** has to know how
	/// much room to leave before it places that window: the bubble is as wide as its line
	/// and sits above her head or below her feet, so the window's size and her offset in
	/// it both depend on this.
	public private(set) var currentExtent: (size: NSSize, tail: SpeechBubbleTail)?

	/// Called when ``currentExtent`` changes — a line appearing, going away, or moving
	/// from above her head to below her feet.
	///
	/// The renderer that reserves room needs to reshape its window then, and it has to
	/// happen before the frame is drawn: sizing the window on the *next* tick would show
	/// the bubble clipped for one frame.
	public var onExtentChanged: (() -> Void)?

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
		displaySpace: DisplaySpace
	) {
		show(
			text,
			placement: placement,
			displaySpace: displaySpace,
			duration: SpeechBubbleTiming.defaultDuration
		)
	}

	public func show(
		_ text: String,
		placement: SpeechBubblePlacement,
		displaySpace: DisplaySpace,
		duration: Double
	) {
		guard !text.isEmpty else { return }
		visible = true
		// It arrives where it belongs. Gliding in from wherever it was last seen
		// would look like the bubble was thrown at her.
		guard let target = host.speechBubbleLayer(at: placement.topLeft) else { return }
		FrameInterpolation.withoutAnimation { apply(text: text, placement: placement, target: target) }

		hideWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.hide() }
		hideWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
	}

	public func reposition(to placement: SpeechBubblePlacement, displaySpace: DisplaySpace) {
		guard visible else { return }
		guard let target = host.speechBubbleLayer(at: placement.topLeft) else { return }
		// Following her, so it takes the same short glide she does — see
		// `FrameInterpolation` — unless the window it is drawn inside moved this frame,
		// in which case its own compensating shift has to land with it.
		let move = { self.apply(text: self.text, placement: placement, target: target) }
		if target.landsInstantly {
			FrameInterpolation.withoutAnimation(move)
		} else {
			FrameInterpolation.animate(move)
		}
	}

	public func hide() {
		hideWorkItem?.cancel()
		hideWorkItem = nil
		visible = false
		currentLayer?.isHidden = true
		setExtent(nil)
	}

	private func apply(
		text: String,
		placement: SpeechBubblePlacement,
		target: SpeechBubbleLayerTarget
	) {
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
		setExtent((size, placement.tail))
	}

	private func setExtent(_ extent: (size: NSSize, tail: SpeechBubbleTail)?) {
		let unchanged =
			currentExtent?.size == extent?.size && currentExtent?.tail == extent?.tail
		currentExtent = extent
		guard !unchanged else { return }
		onExtentChanged?()
	}
}
