import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation

/// A full-display, fully transparent panel.
final class OverlayPetPanel: PetChromePanel {
	init(displayFrame: NSRect) {
		super.init(contentRect: displayFrame)
	}
}

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

	/// A shift applied to an incoming point before it is used, or `nil` for the overlay,
	/// whose window never moves.
	///
	/// The panel renderer needs it: `CGSMoveWindow` moves the window server's copy of
	/// the window and leaves AppKit's cached frame at the position the window was
	/// created, so AppKit's idea of where the pointer is inside the window is off by
	/// however far the window has travelled. See ``PetPanelWindowController``.
	var pointCorrection: ((NSPoint) -> NSPoint)?

	override var isFlipped: Bool { true }

	override func draw(_ dirtyRect: NSRect) {}

	/// Only her body belongs to her. Everywhere else the overlay must not take the
	/// click, so the window server routes it to whatever is behind.
	override func hitTest(_ point: NSPoint) -> NSView? {
		let local = convert(pointCorrection?(point) ?? point, from: superview)
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
		let location = pointCorrection?(event.locationInWindow) ?? event.locationInWindow
		return petLocal(fromRoot: convert(location, from: nil))
	}

	override func mouseDown(with event: NSEvent) { onMouseDown?(event, petLocal(event)) }
	override func mouseDragged(with event: NSEvent) { onMouseDragged?(event, petLocal(event)) }
	override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
	override func rightMouseDown(with event: NSEvent) { onRightMouseDown?(event) }
}

/// Puts the pet on screen by drawing her into a full-display transparent window
/// that never moves, instead of moving a small panel to where she is.
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
	/// What the pet's layer must never animate.
	///
	/// `position` is deliberately absent: it rides `FrameInterpolation`, so the render
	/// server glides her between ticks instead of stepping once per tick. Everything
	/// listed here has to land in the frame it was set in — `contents` especially,
	/// because animating it cross-fades one sprite frame into the next, and `transform`
	/// because it carries the mirror flip, which interpolates through a zero scale and
	/// would flatten her every time she turned around.
	///
	/// A manually created sublayer does not get AppKit's implicit animations suppressed
	/// for it, so without these it eases every change over the default ~0.25 s.
	static let petLayerActions: [String: CAAction] = [
		"bounds": NSNull(),
		"transform": NSNull(),
		"contents": NSNull(),
		"hidden": NSNull(),
	]

	/// What the corner dots must never animate: they never move.
	static let shapeCornerActions: [String: CAAction] = [
		"bounds": NSNull(),
		"position": NSNull(),
		"backgroundColor": NSNull(),
		"hidden": NSNull(),
	]

	/// One 8-bit step of alpha: enough to be part of the window's shape, far too little to
	/// be seen.
	static let shapeCornerAlpha: CGFloat = 1.0 / 255.0

	/// How far each dot sits from the edge of the display.
	///
	/// A pointer reaches a screen edge easily — it stops there — so an anchor on the edge
	/// would be the one place these dots could take a click by accident. One point in from
	/// it is somewhere a hand practically never lands.
	///
	/// The cost is that the shape — their bounding box — loses this much on all four sides,
	/// so during a transition the outermost point of the display is cut. Her feet land
	/// exactly on the display's bottom edge, so one point of them goes; it has not been
	/// visible.
	static let shapeCornerInset: CGFloat = 1

	/// Where the anchors go: their **bounding box** is what holds the window's shape, so each
	/// has to sit at one of its extremes.
	///
	/// Two at the bottom, and one at the top centre. Deliberately **not** the top corners:
	/// both of those are live controls — the Apple menu on the left, Notification Centre on
	/// the right — and the menu bar's middle holds nothing, being the notch on a laptop.
	static func shapeCorners(in size: CGSize) -> [(origin: CGPoint, size: CGSize)] {
		let side: CGFloat = 2
		let inset = shapeCornerInset
		guard size.width > side + inset * 2, size.height > side + inset * 2 else { return [] }
		let square = CGSize(width: side, height: side)
		return [
			// Bottom left and bottom right, clear of the corners.
			(CGPoint(x: inset, y: size.height - inset - side), square),
			(CGPoint(x: size.width - inset - side, y: size.height - inset - side), square),
			// Top centre: the one stretch of the menu bar with nothing in it.
			(CGPoint(x: (size.width - side) / 2, y: inset), square),
		]
	}

	/// What the bubble's layer must never animate.
	///
	/// `position` is absent here too, and for the opposite reason to the pet's: the
	/// bubble sits on her head, so it has to take the same glide she does. Landing
	/// instantly while she interpolated would pull its tail off her every frame she
	/// moved.
	static let bubbleLayerActions: [String: CAAction] = [
		"bounds": NSNull(),
		"contents": NSNull(),
		"contentsScale": NSNull(),
		"hidden": NSNull(),
	]

	private struct Overlay {
		let monitor: Monitor
		let panel: OverlayPetPanel
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
			let panel = OverlayPetPanel(displayFrame: frame)
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
			for corner in Self.shapeCorners(in: frame.size) {
				let dot = CALayer()
				dot.anchorPoint = .zero
				dot.bounds = CGRect(origin: .zero, size: corner.size)
				dot.position = corner.origin
				dot.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: Self.shapeCornerAlpha)
				dot.actions = Self.shapeCornerActions
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
			pet.actions = Self.petLayerActions
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
			bubble.actions = Self.bubbleLayerActions
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
		let transform = PetLayerTransform.make(
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
		baseFrame = image
		let overlay = overlays[hostingIndex]
		overlay.pet.contents = image
		overlay.pet.transform = PetLayerTransform.make(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)
	}

	public func petController(
		_ controller: PetController,
		didUpdateCheekPinch pinch: CheekPinchState?
	) {
		guard let hostingIndex, hostingIndex < overlays.count else { return }
		let overlay = overlays[hostingIndex]
		// The lean follows the pull, and a pinch can hold one sprite frame for many
		// ticks — so it has to be re-applied here, not only with a new frame.
		overlay.pet.transform = PetLayerTransform.make(
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
		overlay.pinch.update(state: pinch, base: baseFrame)
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
