import AppKit

/// Owns the pet's panel and keeps it in step with the controller's foot
/// position. It also translates mouse events into drag gestures.
@MainActor
public final class PetWindowController: NSObject, PetControllerDelegate {
	private let panel: PetPanel
	private let view: PetView
	private let controller: PetController
	private var displaySpace: DisplaySpace

	/// Supplied by the menu bar layer; called on a right-click.
	public var menuProvider: ((NSEvent) -> NSMenu?)?
	/// Called after every move, so attached panels (the head bubble) can follow.
	public var onPlacementChanged: ((PixelRect) -> Void)?

	public init(controller: PetController, displaySpace: DisplaySpace) {
		self.controller = controller
		self.displaySpace = displaySpace
		self.panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: controller.petSize, height: controller.petSize))
		self.view = PetView(frame: panel.contentView?.bounds ?? .zero)

		super.init()

		view.autoresizingMask = [.width, .height]
		view.wantsLayer = true
		view.bodyEllipse = controller.bodyEllipseInView
		panel.contentView = view

		view.onMouseDown = { [weak self] _ in
			guard let self else { return }
			self.controller.beginDrag(at: self.globalCursor)
		}
		view.onMouseDragged = { [weak self] _ in
			guard let self else { return }
			self.controller.updateDrag(to: self.globalCursor)
		}
		view.onMouseUp = { [weak self] _ in
			guard let self else { return }
			self.controller.endDrag(at: self.globalCursor)
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
			primaryHeight: displaySpace.primaryHeight)
		panel.setFrame(frame, display: true)
		view.bodyEllipse = controller.bodyEllipseInView
		view.facing = controller.facing
		onPlacementChanged?(controller.petFrame)
	}

	// MARK: - PetControllerDelegate

	public func petController(_ controller: PetController, didProduceFrame image: CGImage) {
		view.image = image
	}

	public func petControllerDidChangePlacement(_ controller: PetController) {
		applyPlacement()
	}

	public func petControllerDidRequestMenu(_ controller: PetController) {
		// Right-click handling already has the event; nothing to do here.
	}
}
