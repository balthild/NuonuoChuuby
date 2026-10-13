import AppKit

/// Owns the pet's panel and keeps it in step with the controller's foot
/// position. It also translates mouse events into drag gestures.
@MainActor
public final class PetWindowController: NSObject, PetControllerDelegate, PetPresenting {
	private let panel: PetPanel
	private let view: PetView
	private let controller: PetController
	private var displaySpace: DisplaySpace
	private var lastAppliedLevel: NSWindow.Level?

	/// Supplied by the menu bar layer; called on a right-click.
	public var menuProvider: ((NSEvent) -> NSMenu?)?
	/// Called after every move, so attached panels (the head bubble) can follow.
	public var onPlacementChanged: ((PixelRect) -> Void)?
	/// Called when the simulation suspends or resumes, so the panels that belong
	/// to her can be put away with her rather than left floating over the
	/// fullscreen app she is suspended for.
	public var onSuspensionChanged: ((Bool) -> Void)?

	public init(controller: PetController, displaySpace: DisplaySpace) {
		self.controller = controller
		self.displaySpace = displaySpace
		self.panel = PetPanel(
			contentRect: NSRect(x: 0, y: 0, width: controller.petSize, height: controller.petSize)
		)
		self.view = PetView(frame: panel.contentView?.bounds ?? .zero)

		super.init()

		view.autoresizingMask = [.width, .height]
		view.wantsLayer = true
		view.bodyEllipse = controller.bodyEllipseInView
		panel.contentView = view

		view.onMouseDown = { [weak self] event in
			guard let self else { return }
			// A press on a cheek pulls it; anywhere else on the body is a drag.
			let local = self.view.convert(event.locationInWindow, from: nil)
			if let side = self.controller.cheekHitTest(viewPoint: local) {
				self.controller.beginPinch(side: side, at: local)
			} else {
				self.controller.beginDrag(at: self.globalCursor)
			}
		}
		view.onMouseDragged = { [weak self] event in
			guard let self else { return }
			if self.controller.isPinching {
				self.controller.updatePinch(to: self.view.convert(event.locationInWindow, from: nil))
			} else {
				self.controller.updateDrag(to: self.globalCursor)
			}
		}
		view.onMouseUp = { [weak self] _ in
			guard let self else { return }
			if self.controller.isPinching {
				self.controller.endPinch()
			} else {
				self.controller.endDrag(at: self.globalCursor)
			}
		}
		view.onRightMouseDown = { [weak self] event in
			guard let self, let menu = self.menuProvider?(event) else { return }
			NSMenu.popUpContextMenu(menu, with: event, for: self.view)
		}

		controller.delegate = self
		applyPlacement()
	}

	public func show() {
		panel.orderFrontRegardless()
	}

	public func hide() {
		panel.orderOut(nil)
	}

	public var window: NSWindow { panel }

	public func updateDisplaySpace(_ space: DisplaySpace) {
		displaySpace = space
		applyPlacement()
	}

	/// The cursor in the simulation's global top-left coordinate space.
	private var globalCursor: PixelPoint {
		let location = NSEvent.mouseLocation
		return PixelPoint(x: Double(location.x), y: displaySpace.primaryHeight - Double(location.y))
	}

	private func applyPlacement() {
		let size = controller.petSize
		let topLeft = controller.windowTopLeft
		let frame = DisplaySpace.toAppKit(
			PixelRect(x: topLeft.x, y: topLeft.y, width: size, height: size),
			primaryHeight: displaySpace.primaryHeight
		)
		let current = panel.frame
		let sizeChanged = current.size != frame.size
		if current.origin != frame.origin || sizeChanged {
			panel.setFrame(frame, display: sizeChanged)
		}
		applyLevel(topLeft: topLeft, size: size)
		view.bodyEllipse = controller.bodyEllipseInView
		view.facing = controller.facing
		onPlacementChanged?(controller.petFrame)
	}

	/// Her foot stops at the ceiling but the sprite is drawn above it, so her head
	/// reaches into the menu bar whenever she stands or is thrown high. The menu
	/// bar is composited above every ordinary window level, so a panel left at
	/// `.floating` loses that part of the sprite.
	private func applyLevel(topLeft: PixelPoint, size: Double) {
		let center = PixelPoint(x: topLeft.x + size / 2, y: topLeft.y + size / 2)
		guard let workArea = displaySpace.display(containing: center)?.visibleFrame else { return }
		let level = PetPanelLevel.level(panelTop: topLeft.y, workArea: workArea)
		guard lastAppliedLevel != level else { return }
		panel.level = level
		lastAppliedLevel = level
	}

	// MARK: - PetControllerDelegate

	public func petController(_ controller: PetController, didProduceFrame image: CGImage) {
		view.image = image
		view.leanDegrees = controller.bodyLeanDegrees
	}

	public func petControllerDidChangePlacement(_ controller: PetController) {
		applyPlacement()
	}

	public func petControllerDidRequestMenu(_ controller: PetController) {
		// Right-click handling already has the event; nothing to do here.
	}
	public func petController(_ controller: PetController, didChangeSuspension suspended: Bool) {
		if suspended {
			hide()
		} else {
			// `orderFrontRegardless` rather than `makeKeyAndOrderFront`: she must
			// come back without taking focus from whatever the user is doing.
			show()
		}
		onSuspensionChanged?(suspended)
	}
}
