import AppKit

/// Geometry for drawing the pet inside a full-display overlay.
public enum OverlayPetGeometry {
	/// The pet's rectangle, expressed in the overlay's own coordinate space.
	///
	/// Both inputs are top-left origin, Y-down (`DisplaySpace` convention), so this
	/// is a translation by the negative of the display's origin. The result can have
	/// a negative origin while she straddles the left or top edge of her display.
	public static func localPetFrame(petFrame: PixelRect, displayFrame: PixelRect) -> PixelRect {
		let origin = localTopLeft(PixelPoint(x: petFrame.x, y: petFrame.y), in: displayFrame)
		return PixelRect(
			x: origin.x,
			y: origin.y,
			width: petFrame.width,
			height: petFrame.height
		)
	}

	/// A global point, expressed in the overlay's own coordinate space.
	public static func localTopLeft(_ point: PixelPoint, in displayFrame: PixelRect) -> PixelPoint {
		PixelPoint(x: point.x - displayFrame.x, y: point.y - displayFrame.y)
	}

	/// The overlay that holds `point`.
	///
	/// Falls back to the first display, so something momentarily past every screen
	/// edge is still drawn somewhere rather than disappearing. `nil` only when there
	/// are no displays at all, which the simulation already treats as a suspension.
	public static func hostingDisplayIndex(for point: PixelPoint, displays: [Monitor]) -> Int? {
		guard !displays.isEmpty else { return nil }
		return displays.firstIndex { $0.frame.contains(point) } ?? 0
	}

	/// The overlay she is drawn into: the display whose full bounds hold her centre.
	public static func hostingDisplayIndex(for petFrame: PixelRect, displays: [Monitor]) -> Int? {
		hostingDisplayIndex(
			for: PixelPoint(x: petFrame.centerX, y: petFrame.centerY),
			displays: displays
		)
	}
}

/// A full-display, fully transparent panel.
final class OverlayPetPanel: NSPanel {
	init(displayFrame: NSRect) {
		super.init(
			contentRect: displayFrame,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		isFloatingPanel = true
		becomesKeyOnlyIfNeeded = true
		level = PetPanelLevel.belowFloating
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		isMovable = false
		isMovableByWindowBackground = false
		hidesOnDeactivate = false
		animationBehavior = .none
		isReleasedWhenClosed = false
	}

	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { false }

	/// The overlay covers the whole display, menu bar strip included, so AppKit's
	/// default constraint must not pull it back into the visible frame.
	override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
		frameRect
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

	override var isFlipped: Bool { true }

	override func draw(_ dirtyRect: NSRect) {}

	/// Only her body belongs to her. Everywhere else the overlay must not take the
	/// click, so the window server routes it to whatever is behind.
	override func hitTest(_ point: NSPoint) -> NSView? {
		let local = convert(point, from: superview)
		guard bounds.contains(local), petRect.contains(local) else { return nil }
		return PetView.ellipseContains(bodyEllipse, petLocal(fromRoot: local)) ? self : nil
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
/// that never moves, instead of moving a small panel to where she is. This is the
/// default renderer; `--pet-panel` selects `PetWindowController` instead.
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
	private var lastAppliedLevel: NSWindow.Level?
	private var isVisible = false

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

			let pet = CALayer()
			// Pivot at the pet's bottom centre, matching the lean in `PetView`.
			pet.anchorPoint = CGPoint(x: 0.5, y: 1)
			pet.contentsGravity = .resize
			pet.minificationFilter = .linear
			pet.magnificationFilter = .linear
			pet.isOpaque = false
			pet.contentsScale = monitor.scale
			pet.actions = Self.petLayerActions
			root.layer?.addSublayer(pet)

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
				bubble: bubble
			)
		}
		hostingIndex = nil
		lastAppliedLevel = nil
		if isVisible {
			for overlay in overlays {
				overlay.panel.orderFrontRegardless()
			}
		}
	}

	/// Mouse handling is the same as the moving-panel controller's, but the point
	/// is taken in the **pet's** space so `cheekHitTest` and the pinch keep working
	/// in the coordinates they already expect.
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

	/// Mirroring is applied after the lean, matching the order `PetView` uses.
	private func petTransform(lean: Double, facing: Double) -> CATransform3D {
		let rotate = CATransform3DMakeRotation(CGFloat(lean) * .pi / 180, 0, 0, 1)
		guard facing < 0 else { return rotate }
		return CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), rotate)
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
		let transform = petTransform(lean: controller.bodyLeanDegrees, facing: controller.facing)

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

		applyLevel(petFrame: petFrame)
	}

	/// Every overlay shares one level, decided from where the pet is — the same
	/// rule the moving panel used. The transparent parts of an overlay cover
	/// nothing, so raising the window while she reaches into the menu bar changes
	/// nothing else on screen.
	private func applyLevel(petFrame: PixelRect) {
		let centre = PixelPoint(x: petFrame.centerX, y: petFrame.centerY)
		guard let workArea = displaySpace.display(containing: centre)?.visibleFrame else { return }
		let level = PetPanelLevel.level(
			panelTop: petFrame.top,
			workArea: workArea,
			below: PetPanelLevel.belowFloating
		)
		guard lastAppliedLevel != level else { return }
		lastAppliedLevel = level
		for overlay in overlays {
			overlay.panel.level = level
		}
	}

	// MARK: - PetControllerDelegate

	public func petController(_ controller: PetController, didProduceFrame image: CGImage) {
		guard let hostingIndex, hostingIndex < overlays.count else { return }
		let overlay = overlays[hostingIndex]
		overlay.pet.contents = image
		overlay.pet.transform = petTransform(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)
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
