import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation

/// Puts the pet on screen in a small panel that goes to where she is, instead of a
/// full-display window that never moves.
///
/// Selected with `--pet-panel`. It exists to price one question the overlay's own
/// numbers cannot answer: a full-display window has a window under the pointer
/// wherever the pointer is, so the window server goes on handing that connection the
/// mouse-move stream, whereas a window the size of the pet is under the pointer only
/// over her.
///
/// The window is moved with SkyLight's `CGSMoveWindow` (see ``PetPanelMover``), which
/// is the only reason this is worth measuring — AppKit's own move is the cost the
/// overlay was built to escape. The price is that AppKit never learns the window has
/// moved: ``appKitOrigin`` holds the truth, and every point AppKit hands over is
/// shifted back against the frame it still believes in.
///
/// She stays a **layer** inside the panel rather than a drawn view, so the sprite
/// reaches the compositor as `contents` and no CoreGraphics resampling happens per
/// frame — the same reason the overlay draws her that way.
///
/// The head bubble and the ghost icons each get a window of their own
/// (``PetPanelSpeechBubble``, ``PetPanelGhostIcon``): a bubble is as wide as its line
/// and a ghost stands where a file used to be, so neither fits inside her square. Both
/// are click-through and ordered out when idle, so a rectangle of theirs is under the
/// pointer only while one of them is actually on screen.
@MainActor
public final class PetPanelWindowController: NSObject, PetControllerDelegate, PetPresenting {
	private let controller: PetController
	private var displaySpace: DisplaySpace
	private let panel: PetChromePanel
	private let root: OverlayPetRootView
	private let pet: CALayer
	private let pinch: CheekPinchLayer
	/// The last sprite frame, kept so the cheek overlay can be drawn against it
	/// without the controller handing it over again.
	private var baseFrame: CGImage?

	/// Where the window really is, in AppKit's coordinate space.
	///
	/// Not `panel.frame`: once the private move is in use those two disagree and never
	/// meet again, and it is this one the window server is actually using.
	private var appKitOrigin: NSPoint = .zero

	/// Which call is putting the window where it belongs.
	///
	/// Starts on AppKit, because the private call cannot be trusted until the window has
	/// a device: a window that has never been ordered on screen takes `CGSMoveWindow`,
	/// returns success, and stays where it was made. That is not hypothetical — it left
	/// her drawn in the bottom-left corner of the display and impossible to click, since
	/// a move that did not happen still recorded a new origin and skewed the hit test.
	/// The switch happens once the private move has been **read back** and confirmed.
	private enum Placement {
		case appKit
		case privateMove
	}
	private var placement: Placement = .appKit

	public var menuProvider: ((NSEvent) -> NSMenu?)?
	public var onPlacementChanged: ((PixelRect) -> Void)?
	public var onSuspensionChanged: ((Bool) -> Void)?

	/// The bubble is a window here, not a layer of the overlay, so it has to be told
	/// where the display is — a window is placed in the window server's own space.
	public private(set) lazy var speechBubble: any SpeechBubblePresenting =
		PetPanelSpeechBubble()

	public init(controller: PetController, displaySpace: DisplaySpace) {
		self.controller = controller
		self.displaySpace = displaySpace

		let size = NSRect(x: 0, y: 0, width: controller.petSize, height: controller.petSize)
		panel = PetChromePanel(contentRect: size)
		root = OverlayPetRootView(frame: size)
		pet = CALayer()
		pinch = CheekPinchLayer()

		super.init()

		panel.title = "pet panel"

		root.autoresizingMask = [.width, .height]
		root.wantsLayer = true
		// The root draws nothing at all, so it must never be asked to redraw.
		root.layerContentsRedrawPolicy = .never
		// The view is flipped, so the pet's sublayer must share its top-left origin
		// for the two coordinate systems to agree.
		root.layer?.isGeometryFlipped = true
		// AppKit's frame is stale from the first private move on, so its idea of where
		// the pointer is inside the window has to be shifted back before it is used.
		root.pointCorrection = { [weak self] point in self?.corrected(point) ?? point }

		pet.anchorPoint = CGPoint(x: 0.5, y: 1)
		pet.contentsGravity = .resize
		pet.minificationFilter = .linear
		pet.magnificationFilter = .linear
		pet.isOpaque = false
		pet.actions = OverlayPetWindowController.petLayerActions
		root.layer?.addSublayer(pet)

		// The cheek overlay rides on the pet's own layer, above the sprite.
		pet.addSublayer(pinch.container)

		panel.contentView = root
		wireGestures()

		controller.delegate = self
		applyPlacement()
	}

	public func show() {
		panel.orderFrontRegardless()
		// Ordering a window in lets AppKit reassert the frame it believes in, which is
		// the stale one — so the real position has to be put back afterwards.
		applyPlacement()
	}

	public func hide() {
		panel.orderOut(nil)
	}

	public func updateDisplaySpace(_ space: DisplaySpace) {
		displaySpace = space
		applyPlacement()
	}

	public func makeGhostIcon() -> any GhostIconPresenting {
		PetPanelGhostIcon(displaySpace: displaySpace)
	}

	// MARK: - Placement

	/// The cursor in the simulation's global top-left coordinate space.
	private var globalCursor: PixelPoint {
		let location = NSEvent.mouseLocation
		return PixelPoint(x: Double(location.x), y: displaySpace.primaryHeight - Double(location.y))
	}

	/// The backing scale of the display she is on.
	private var hostingScale: CGFloat {
		let frame = controller.petFrame
		let centre = PixelPoint(x: frame.centerX, y: frame.centerY)
		guard let monitor = displaySpace.displays.first(where: { $0.frame.contains(centre) }) else {
			return displaySpace.displays.first?.scale ?? 1
		}
		return monitor.scale
	}

	/// Puts the window, and her inside it, where the controller says she is.
	///
	/// The overlay glides her between ticks with a layer animation; this renderer moves
	/// the *window*, and the window server places it once per commit, so there is
	/// nothing left to interpolate — her motion is a staircase at the tick rate.
	private func applyPlacement() {
		let petFrame = controller.petFrame
		let target = DisplaySpace.toAppKit(petFrame, primaryHeight: displaySpace.primaryHeight)

		if panel.frame.size != target.size {
			// She was resized (a menu action). A reshape cannot go through the private
			// call — it moves a window, it does not resize one — so this rare one goes
			// to AppKit, which also reasserts the frame it believes in. It is also the
			// one route that can place a window the private call is not moving yet.
			panel.setFrame(target, display: true)
			appKitOrigin = panel.frame.origin
		} else if move(to: petFrame) {
			appKitOrigin = target.origin
			// The move could not be made through the private call yet — the window has no
			// device, or the call is unavailable. AppKit is authoritative, so its own frame
			// stays the truth and the correction collapses to nothing.
		} else {
			panel.setFrameOrigin(target.origin)
			appKitOrigin = panel.frame.origin
		}

		updatePetLayer()
		onPlacementChanged?(petFrame)
	}

	/// Places the window through the private call, where it is the chosen route and the
	/// window is known to take it.
	///
	/// The first attempt is verified rather than trusted: it is the one made on a window
	/// that may have just been ordered on screen and has no device yet. Once it is
	/// confirmed the window is really moved, the steady state stops paying for the read —
	/// a window that is being composited and answers the call is not going to ignore it.
	private func move(to petFrame: PixelRect) -> Bool {
		switch placement {
		case .appKit:
			guard panel.isVisible else { return false }
			let windowID = UInt32(panel.windowNumber)
			guard
				PetPanelMover.move(
					windowID: windowID,
					to: PixelPoint(x: petFrame.x, y: petFrame.y)
				),
				let actual = PetPanelMover.bounds(of: windowID),
				// The read is already in the pet's space, so it compares directly.
				abs(actual.x - petFrame.x) <= 1,
				abs(actual.y - petFrame.y) <= 1
			else { return false }
			placement = .privateMove
			return true

		case .privateMove:
			let moved = PetPanelMover.move(
				windowID: UInt32(panel.windowNumber),
				to: PixelPoint(x: petFrame.x, y: petFrame.y)
			)
			if !moved {
				// The window was taken away under us. AppKit is authoritative again.
				placement = .appKit
			}
			return moved
		}
	}

	private func updatePetLayer() {
		let size = panel.frame.size
		pet.bounds = CGRect(origin: .zero, size: size)
		// The pivot is the pet's bottom centre, in the flipped root: the lean rotates
		// on the ground rather than sliding her sideways.
		pet.position = CGPoint(x: size.width / 2, y: size.height)
		pet.contentsScale = hostingScale
		pet.transform = PetLayerTransform.make(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)
		// The pet fills the whole panel, so the hit test's two rectangles are its bounds.
		root.petRect = CGRect(origin: .zero, size: size)
		root.bodyEllipse = controller.bodyEllipseInView
	}

	/// Shifts a point AppKit computed from the frame it believes in onto the frame the
	/// window actually has.
	///
	/// Zero whenever the two agree, which is what a run without the private call looks
	/// like — every move then went through AppKit and nothing needs correcting.
	private func corrected(_ point: NSPoint) -> NSPoint {
		let believed = panel.frame.origin
		let dx = appKitOrigin.x - believed.x
		let dy = appKitOrigin.y - believed.y
		guard dx != 0 || dy != 0 else { return point }
		return NSPoint(x: point.x - dx, y: point.y - dy)
	}

	// MARK: - Gestures

	/// The point arrives in the **pet's** own space, which is the space `cheekHitTest`
	/// and the pinch take.
	private func wireGestures() {
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
		root.onRightMouseDown = { [weak self] event in
			guard let self, let menu = self.menuProvider?(event) else { return }
			NSMenu.popUpContextMenu(menu, with: event, for: self.root)
		}
	}

	// MARK: - PetControllerDelegate

	public func petController(_ controller: PetController, didProduceFrame image: CGImage) {
		baseFrame = image
		pet.contents = image
		pet.transform = PetLayerTransform.make(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)
	}

	public func petController(
		_ controller: PetController,
		didUpdateCheekPinch pinchState: CheekPinchState?
	) {
		// The lean follows the pull, and a pinch can hold one sprite frame for many
		// ticks — so it has to be re-applied here, not only with a new frame.
		pet.transform = PetLayerTransform.make(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)
		guard let pinchState else {
			pinch.clear()
			return
		}
		pinch.setBounds(CGRect(origin: .zero, size: pet.bounds.size), contentsScale: hostingScale)
		pinch.update(state: pinchState, base: baseFrame)
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
			show()
		}
		onSuspensionChanged?(suspended)
	}
}
