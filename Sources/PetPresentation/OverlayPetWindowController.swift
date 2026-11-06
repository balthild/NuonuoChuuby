import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation
import PetSimulation

/// The overlay's content view. It draws nothing: the pet is a sublayer, so moving
/// her changes only that layer's geometry and never re-runs any drawing. The view
/// exists for hit testing, which is the one job a layer cannot do.
final class OverlayPetRootView: NSView {
	/// The pet's rectangle, in this view's coordinates.
	var petRect: CGRect = .zero
	/// The interactive body ellipse, in the pet's own (flipped, Y-down) space.
	var bodyEllipse: CGRect = .zero

	var onMouseDown: ((NSEvent, CGPoint) -> Void)?
	var onMouseDragged: ((NSEvent, CGPoint) -> Void)?
	var onMouseUp: ((NSEvent) -> Void)?
	var onRightMouseDown: ((NSEvent) -> Void)?

	override var isFlipped: Bool { true }

	override func draw(_ dirtyRect: NSRect) {}

	/// Only her body belongs to her. Everywhere else the overlay must not take the
	/// click, so the window server routes it to whatever is behind.
	override func hitTest(_ point: NSPoint) -> NSView? {
		let local = convert(point, from: superview)
		guard bounds.contains(local), petRect.contains(local) else { return nil }
		return Self.ellipseContains(bodyEllipse, petLocal(fromRoot: local)) ? self : nil
	}

	/// Whether `point` falls inside the pet's body ellipse, in the pet's own space.
	static func ellipseContains(_ ellipse: CGRect, _ point: CGPoint) -> Bool {
		guard ellipse.width > 0, ellipse.height > 0 else { return false }
		let normalizedX = (point.x - ellipse.midX) / (ellipse.width / 2)
		let normalizedY = (point.y - ellipse.midY) / (ellipse.height / 2)
		return normalizedX * normalizedX + normalizedY * normalizedY <= 1
	}

	/// A point in the pet's own coordinate space, the space `cheekHitTest` and the
	/// pinch take.
	func petLocal(fromRoot point: CGPoint) -> CGPoint {
		CGPoint(x: point.x - petRect.minX, y: point.y - petRect.minY)
	}

	private func petLocal(_ event: NSEvent) -> CGPoint {
		petLocal(fromRoot: convert(event.locationInWindow, from: nil))
	}

	override func mouseDown(with event: NSEvent) { onMouseDown?(event, petLocal(event)) }
	override func mouseDragged(with event: NSEvent) { onMouseDragged?(event, petLocal(event)) }
	override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
	override func rightMouseDown(with event: NSEvent) { onRightMouseDown?(event) }
}

/// Puts the pet on screen by drawing her into a full-display transparent window
/// that never moves, instead of moving a small window to where she is.
///
/// The cost being attacked is the window-move transaction — `NSWindow._setFrameCommon:`
/// plus the Core Animation commit — that a per-frame `setFrame` pays.
///
/// The pet is a **sublayer**, not a view. A layer-backed subview is redrawn by
/// AppKit whenever its frame changes, and on a full-display window that puts the
/// sprite back through CoreGraphics' CPU resampling every frame — measured at
/// ~28% of main-thread CPU, more than the window move this overlay removes. A
/// sublayer with `contents` set is only composited, so moving her is free.
@MainActor
public final class OverlayPetWindowController: NSObject, PetControllerDelegate, PetPresenting {
	private struct Overlay {
		let monitor: Monitor
		let panel: PetChromePanel
		let root: OverlayPetRootView
		let pet: CALayer
		let bubble: CALayer
		/// The pulled cheek, drawn on top of her own layer so it takes the lean and
		/// the mirror with her.
		let pinch: CheekPinchLayer

		/// The bubble's colours are dynamic, so its cached raster only holds for one
		/// appearance.
		@MainActor
		var isDarkAppearance: Bool {
			panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
		}
	}

	private let controller: PetController
	private var displaySpace: DisplaySpace
	private var overlays: [Overlay] = []
	/// The overlay she is drawn into; the others are kept empty.
	private var hostingIndex: Int?
	private var isVisible = false
	/// The last sprite frame, kept so the cheek overlay can be drawn against it
	/// without the controller having to hand it over again.
	private var baseFrame: CGImage?
	/// The cycle the render server is playing, when it is the one advancing the frames.
	private var playingLoop: SpriteLoop?
	/// The live ghost icons, so a display change that rebuilds the overlays can put
	/// theirs back on screen.
	private var ghostIcons: [OverlayGhostIcon] = []

	public var menuProvider: ((NSEvent) -> NSMenu?)?
	/// The bubble is a layer of these overlays, above her, rather than a window of
	/// its own — which is what makes following her free for the bubble too.
	public lazy var speechBubble: any SpeechBubblePresenting = OverlaySpeechBubbleController(
		host: self
	)
	public var onPlacementChanged: ((PixelRect) -> Void)?
	public var onSuspensionChanged: ((Bool) -> Void)?

	public init(controller: PetController, displaySpace: DisplaySpace) {
		self.controller = controller
		self.displaySpace = displaySpace
		super.init()
		rebuildOverlays()
		controller.delegate = self
		applyPlacement(animated: false)
	}

	public func show() {
		isVisible = true
		for overlay in overlays {
			overlay.panel.orderFrontRegardless()
		}
	}

	public func hide() {
		isVisible = false
		for overlay in overlays {
			overlay.panel.orderOut(nil)
		}
	}

	public func updateDisplaySpace(_ space: DisplaySpace) {
		displaySpace = space
		rebuildOverlays()
		applyPlacement(animated: false)
	}

	public func makeGhostIcon() -> any GhostIconPresenting {
		ghostIcons.removeAll { $0.isDismissed }
		let ghost = OverlayGhostIcon(host: self)
		ghostIcons.append(ghost)
		return ghost
	}

	// MARK: - Construction

	/// One overlay per display, each covering its full bounds.
	private func rebuildOverlays() {
		for overlay in overlays {
			overlay.panel.close()
		}
		overlays = displaySpace.displays.map { monitor in
			let frame = DisplaySpace.toAppKit(monitor.frame, primaryHeight: displaySpace.primaryHeight)
			let panel = PetChromePanel(contentRect: frame)
			let root = OverlayPetRootView(frame: NSRect(origin: .zero, size: frame.size))
			root.autoresizingMask = [.width, .height]
			root.wantsLayer = true
			// The root draws nothing at all, so it must never be asked to redraw.
			root.layerContentsRedrawPolicy = .never
			// The view is flipped, so the pet's sublayer must share its top-left
			// origin for the two coordinate systems to agree.
			root.layer?.isGeometryFlipped = true

			// Three invisible dots near the edges of the window, which hold its **shape** at
			// full size without taking any clicks where a hand goes.
			//
			// A Space transition freezes the window's shape — the region its opaque pixels
			// cover — at the moment it begins, and goes on updating the contents. Whatever
			// moves out of that frozen region is cut off, which is why she was seen sliced
			// across: she fell, and everything below where she had been was dropped.
			//
			// The region is the **bounding box** of the opaque pixels, not the pixels: measured
			// with a probe, four 2×2 pt dots at alpha 1/255 in the corners of a window stopped
			// the clipping exactly as a full-display cover did. And unlike the cover, it does
			// not cost the click-through — a click is still routed per pixel, so the display
			// outside these dots belongs to whatever is behind her. That combination is what
			// makes this possible at all: a cover layer fixes the clipping and takes the whole
			// screen's clicks, because the shape is the same thing that decides both.
			for corner in PetLayerConventions.shapeCorners(in: frame.size) {
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
			}

			let pet = CALayer()
			// Pivot at the pet's bottom centre, so the lean rotates on the ground
			// rather than sliding her sideways.
			pet.anchorPoint = CGPoint(x: 0.5, y: 1)
			pet.contentsGravity = .resize
			pet.minificationFilter = .linear
			pet.magnificationFilter = .linear
			pet.isOpaque = false
			pet.contentsScale = monitor.scale
			pet.actions = PetLayerConventions.petActions
			root.layer?.addSublayer(pet)

			// The cheek overlay rides on the pet's own layer, above the sprite.
			let pinch = CheekPinchLayer()
			pet.addSublayer(pinch.container)

			// The bubble rides above her, in the same never-moving window.
			let bubble = CALayer()
			bubble.anchorPoint = CGPoint(x: 0, y: 0)
			bubble.contentsGravity = .resize
			bubble.minificationFilter = .linear
			bubble.magnificationFilter = .linear
			bubble.isOpaque = false
			bubble.contentsScale = monitor.scale
			bubble.isHidden = true
			bubble.actions = PetLayerConventions.bubbleActions
			root.layer?.addSublayer(bubble)

			panel.contentView = root
			wireGestures(root: root)
			return Overlay(
				monitor: monitor,
				panel: panel,
				root: root,
				pet: pet,
				bubble: bubble,
				pinch: pinch
			)
		}
		hostingIndex = nil
		if isVisible {
			for overlay in overlays {
				overlay.panel.orderFrontRegardless()
			}
		}
		ghostIcons.removeAll { $0.isDismissed }
		for ghost in ghostIcons { ghost.rebind() }
	}

	/// The point is taken in the **pet's** space, so `cheekHitTest` and the pinch keep
	/// working in the coordinates they already expect.
	private func wireGestures(root: OverlayPetRootView) {
		root.onMouseDown = { [weak self] _, petLocal in
			guard let self else { return }
			if let side = self.controller.cheekHitTest(viewPoint: petLocal) {
				self.controller.beginPinch(side: side, at: petLocal)
			} else {
				self.controller.beginDrag(at: self.globalCursor)
			}
		}
		root.onMouseDragged = { [weak self] _, petLocal in
			guard let self else { return }
			if self.controller.isPinching {
				self.controller.updatePinch(to: petLocal)
			} else {
				self.controller.updateDrag(to: self.globalCursor)
			}
		}
		root.onMouseUp = { [weak self] _ in
			guard let self else { return }
			if self.controller.isPinching {
				self.controller.endPinch()
			} else {
				self.controller.endDrag(at: self.globalCursor)
			}
		}
		root.onRightMouseDown = { [weak self, weak root] event in
			guard let self, let root, let menu = self.menuProvider?(event) else { return }
			NSMenu.popUpContextMenu(menu, with: event, for: root)
		}
	}

	// MARK: - Placement

	/// The cursor in the simulation's global top-left coordinate space.
	private var globalCursor: PixelPoint {
		let location = NSEvent.mouseLocation
		return PixelPoint(x: Double(location.x), y: displaySpace.primaryHeight - Double(location.y))
	}

	/// - Parameter animated: whether her position should glide to the new one rather
	///   than land in this frame. False for the first placement on a layer, which has
	///   never been anywhere yet and would otherwise fly in from the origin.
	private func applyPlacement(animated: Bool) {
		let petFrame = controller.petFrame
		guard
			let index = OverlayPetGeometry.hostingDisplayIndex(
				for: petFrame,
				displays: overlays.map(\.monitor)
			)
		else { return }
		hostingIndex = index
		let transform = PetLayerConventions.transform(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)

		// The bubble is moved by the callback at the end, and has to be in the same
		// transaction: it sits on her head, so anything that delayed one and not the
		// other would pull its tail off her.
		let move = {
			for (position, overlay) in self.overlays.enumerated() {
				guard position == index else {
					overlay.pet.isHidden = true
					continue
				}
				let local = OverlayPetGeometry.localPetFrame(
					petFrame: petFrame,
					displayFrame: overlay.monitor.frame
				)
				overlay.pet.isHidden = false
				overlay.pet.bounds = CGRect(x: 0, y: 0, width: local.width, height: local.height)
				overlay.pet.position = CGPoint(x: local.centerX, y: local.bottom)
				overlay.pet.transform = transform
				overlay.root.petRect = CGRect(
					x: local.x,
					y: local.y,
					width: local.width,
					height: local.height
				)
				overlay.root.bodyEllipse = self.controller.bodyEllipseInView
			}
			// The bubble follows the pet's own square, never the overlay's rectangle.
			self.onPlacementChanged?(petFrame)
		}
		if animated {
			FrameInterpolation.animate(move)
		} else {
			FrameInterpolation.withoutAnimation(move)
		}
	}

	// MARK: - PetControllerDelegate

	public func petController(_ controller: PetController, didProduceFrame image: CGImage) {
		guard let hostingIndex, hostingIndex < overlays.count else { return }
		// A stepped frame means the render server is not the one advancing the frames now.
		playingLoop = nil
		baseFrame = image
		let overlay = overlays[hostingIndex]
		PetLayerConventions.stopLoop(on: overlay.pet)
		overlay.pet.contents = image
		overlay.pet.transform = PetLayerConventions.transform(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)
	}

	public func petController(_ controller: PetController, didBeginLoop loop: SpriteLoop) {
		guard let hostingIndex, hostingIndex < overlays.count else { return }
		playingLoop = loop
		baseFrame = loop.frames.first
		let overlay = overlays[hostingIndex]
		PetLayerConventions.play(loop, on: overlay.pet)
		overlay.pet.transform = PetLayerConventions.transform(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)
	}

	/// The cel on screen right now.
	///
	/// While the render server is playing a loop it is the authority on which frame that is
	/// — the model value stays at the cycle's first frame — so the pinch has to read the
	/// layer's presentation rather than anything this object stored.
	private var celOnScreen: CGImage? {
		guard let loop = playingLoop, let hostingIndex, hostingIndex < overlays.count else {
			return baseFrame
		}
		return PetLayerConventions.presentedFrame(
			of: overlays[hostingIndex].pet,
			among: loop.frames
		) ?? baseFrame
	}

	public func petController(
		_ controller: PetController,
		didUpdateCheekPinch pinch: CheekPinchState?
	) {
		guard let hostingIndex, hostingIndex < overlays.count else { return }
		let overlay = overlays[hostingIndex]
		// The lean follows the pull, and a pinch can hold one sprite frame for many
		// ticks — so it has to be re-applied here, not only with a new frame.
		overlay.pet.transform = PetLayerConventions.transform(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)
		guard let pinch else {
			overlay.pinch.clear()
			return
		}
		overlay.pinch.setBounds(
			CGRect(origin: .zero, size: overlay.pet.bounds.size),
			contentsScale: overlay.monitor.scale
		)
		overlay.pinch.update(state: pinch, base: celOnScreen)
	}

	public func petControllerDidChangePlacement(_ controller: PetController) {
		applyPlacement(animated: true)
	}

	public func petControllerDidRequestMenu(_ controller: PetController) {
		// Right-click handling already has the event; nothing to do here.
	}

	public func petController(_ controller: PetController, didChangeSuspension suspended: Bool) {
		if suspended {
			hide()
		} else {
			show()
		}
		onSuspensionChanged?(suspended)
	}
}

@MainActor
extension OverlayPetWindowController: SpeechBubbleLayerHosting {
	public func speechBubbleLayer(at point: PixelPoint) -> SpeechBubbleLayerTarget? {
		guard
			let index = OverlayPetGeometry.hostingDisplayIndex(
				for: point,
				displays: overlays.map(\.monitor)
			)
		else { return nil }
		let overlay = overlays[index]
		return SpeechBubbleLayerTarget(
			layer: overlay.bubble,
			displayFrame: overlay.monitor.frame,
			scale: CGFloat(overlay.monitor.scale),
			isDark: overlay.isDarkAppearance
		)
	}
}

@MainActor
extension OverlayPetWindowController: GhostIconLayerHosting {
	public func ghostIconLayerTarget(at point: PixelPoint) -> GhostIconLayerTarget? {
		guard
			let index = OverlayPetGeometry.hostingDisplayIndex(
				for: point,
				displays: overlays.map(\.monitor)
			),
			let parent = overlays[index].root.layer
		else { return nil }
		let overlay = overlays[index]
		return GhostIconLayerTarget(
			parent: parent,
			displayFrame: overlay.monitor.frame,
			scale: CGFloat(overlay.monitor.scale)
		)
	}
}
