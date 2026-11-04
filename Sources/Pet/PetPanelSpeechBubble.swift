import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation

/// Draws the head bubble in a window of its own, for the panel renderer.
///
/// The overlay draws the bubble as a layer of the window that already covers the
/// display, so following her is free. A bubble has no fixed size — it is as wide as its
/// line — so this one has to be sized to it and put next to her head, and while a line
/// is showing, that is a second small rectangle on the screen and a window move per
/// frame she moves. It is ordered out as soon as the line is done, so the cost is only
/// ever paid while a bubble is up.
///
/// The window is moved through the private ``PetPanelMover``, like the pet's own panel:
/// AppKit's frame then goes stale, which is harmless here — the bubble takes no input
/// (``ignoresMouseEvents``) and its position is derived from the placement every time,
/// never read back.
///
/// The raster is rebuilt only when the line, the tail, the size or the appearance
/// changes, so following her is a move rather than a redraw.
@MainActor
final class PetPanelSpeechBubble: SpeechBubblePresenting {
	private let panel: PetChromePanel
	private let root: PetLayerHostView
	/// The bubble itself: `contents` is the raster, and its geometry is set in the root's
	/// flipped space, exactly as the overlay's bubble layer is.
	private let bubble = CALayer()
	private var hideWorkItem: DispatchWorkItem?

	private var visible = false
	private var text = ""

	/// The placement of the line on screen now, so a reposition that changes nothing can
	/// be dropped before it costs a window move.
	private var lastPlacement: SpeechBubblePlacement?

	/// What the cached bitmap was made from. Anything else that changes the picture has
	/// to be added here, or the bubble keeps a stale one.
	private var raster: Raster?

	private struct Raster: Equatable {
		let text: String
		let tail: SpeechBubbleTail
		let width: CGFloat
		let height: CGFloat
		let scale: CGFloat
		let isDark: Bool
	}

	init() {
		panel = PetChromePanel(contentRect: .zero, ignoresMouseEvents: true)
		panel.title = "pet panel bubble"
		root = PetLayerHostView(frame: .zero)
		root.wantsLayer = true
		root.layer?.isGeometryFlipped = true

		bubble.anchorPoint = .zero
		bubble.contentsGravity = .resize
		bubble.minificationFilter = .linear
		bubble.magnificationFilter = .linear
		bubble.isOpaque = false
		root.layer?.addSublayer(bubble)
		panel.contentView = root
	}

	public var isVisible: Bool { visible }

	public var currentText: String { text }

	public var tailHeight: Double { Double(SpeechBubbleDrawing.tailHeight) }

	public func bodySize(for text: String) -> (width: Double, height: Double) {
		let size = SpeechBubbleDrawing.bodySize(for: text)
		return (Double(size.width), Double(size.height))
	}

	public func show(_ text: String, placement: SpeechBubblePlacement, displaySpace: DisplaySpace) {
		guard !text.isEmpty else { return }
		visible = true
		apply(text: text, placement: placement, displaySpace: displaySpace)
		// Only here: a reposition has nothing to bring forward, and this is a window
		// server call.
		panel.orderFrontRegardless()

		hideWorkItem?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.hide() }
		hideWorkItem = work
		DispatchQueue.main.asyncAfter(
			deadline: .now() + SpeechBubbleTiming.defaultDuration,
			execute: work
		)
	}

	public func reposition(to placement: SpeechBubblePlacement, displaySpace: DisplaySpace) {
		guard visible else { return }
		// She is often still while she talks, and this is called on every placement
		// change: with nothing moved and nothing to redraw there is no work to do, and a
		// window move is the most expensive thing this class can do.
		guard placement != lastPlacement else { return }
		// A window move cannot be interpolated the way the overlay's layer move can, so
		// the bubble steps to the new position instead of gliding with her.
		apply(text: text, placement: placement, displaySpace: displaySpace)
	}

	public func hide() {
		hideWorkItem?.cancel()
		hideWorkItem = nil
		visible = false
		lastPlacement = nil
		panel.orderOut(nil)
	}

	private func apply(text: String, placement: SpeechBubblePlacement, displaySpace: DisplaySpace) {
		self.text = text

		let size = SpeechBubbleDrawing.preferredSize(for: text, tail: placement.tail)
		let scale = scale(at: placement.topLeft, displaySpace: displaySpace)
		let isDark = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
		let key = Raster(
			text: text,
			tail: placement.tail,
			width: size.width,
			height: size.height,
			scale: scale,
			isDark: isDark
		)

		// A layer that has never been drawn into has no contents whatever the key says.
		let sizeChanged = panel.frame.size != size
		if raster != key || sizeChanged {
			bubble.contents = SpeechBubbleDrawing.image(
				size: size,
				tail: placement.tail,
				text: text,
				scale: scale,
				isDark: isDark
			)
			bubble.contentsScale = scale
			bubble.bounds = CGRect(origin: .zero, size: size)
			bubble.position = .zero
			raster = key
		}

		// Reshaping is the one thing the private call cannot do — it moves a window, it
		// does not resize one — so a new line's width goes to AppKit, which also
		// reasserts the frame it believes in.
		if sizeChanged {
			panel.setFrame(
				NSRect(
					origin: appKitOrigin(of: placement.topLeft, size: size, displaySpace: displaySpace),
					size: size
				),
				display: false
			)
		} else {
			PetPanelMover.move(windowID: UInt32(panel.windowNumber), to: placement.topLeft)
		}
		lastPlacement = placement
	}

	/// The bubble's top-left in AppKit's bottom-left space.
	private func appKitOrigin(
		of topLeft: PixelPoint,
		size: NSSize,
		displaySpace: DisplaySpace
	) -> NSPoint {
		DisplaySpace.toAppKit(
			PixelRect(x: topLeft.x, y: topLeft.y, width: size.width, height: size.height),
			primaryHeight: displaySpace.primaryHeight
		).origin
	}

	private func scale(at point: PixelPoint, displaySpace: DisplaySpace) -> CGFloat {
		displaySpace.display(containing: point)?.scale ?? displaySpace.displays.first?.scale ?? 1
	}
}
