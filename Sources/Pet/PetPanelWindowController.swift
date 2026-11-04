import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation

/// Puts the pet on screen in a small window that goes to where she is, instead of a
/// full-display window that never moves. Two modes, differing only in how much slack
/// the window gives her:
///
/// - ``Mode/panel`` (`--pet-panel`): a window exactly her size, put where she is every
///   tick. Her motion is a staircase — the window server places a window once per
///   commit, so there is nothing to interpolate.
/// - ``Mode/hybrid`` (`--pet-panel-hybrid`): a window **twice** her size, placed on a
///   grid one pet wide, with her drawn at the remainder. She moves by changing only
///   her own layer's position, which *is* interpolated, and the window is moved only
///   when she reaches the edge of the slack it gave her.
///
/// The hybrid is the answer to the one thing the panel pays for: a window move per
/// frame while she is moving. It buys that with a window of four times her area, which
/// still costs almost nothing in mouse-move delivery (the cost the overlay cannot
/// avoid) and makes her motion smooth at the same time.
///
/// The two modes move their window differently, because they need different things
/// from it:
///
/// - The panel moves it **every frame she moves**, which is why it borrows SkyLight's
///   `CGSMoveWindow` (see ``PetPanelMover``) — AppKit's own move is the transaction the
///   overlay was built to escape. The price is that AppKit never learns the window has
///   moved: ``appKitOrigin`` holds the truth, and every point AppKit hands over is
///   shifted back against the frame it still believes in.
/// - The hybrid moves it **once per grid**, and must move her layer in the very same
///   frame — so it uses AppKit's move, which is coalesced with the Core Animation
///   commit. The private call is not, and using it here tore the two apart: the window
///   stepped a whole pet while her layer was still a commit behind, and she was seen a
///   grid away for as long as that lasted.
///
/// She stays a **layer** inside the window rather than a drawn view, so the sprite
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
	/// How much slack the window gives her, and so how often it has to be moved.
	public enum Mode {
		/// A window exactly her size, moved to her every tick.
		case panel
		/// A window twice her size, so she has a full pet's width and height to move
		/// inside it before the window itself has to go somewhere else.
		case hybrid

		/// The window side, as a multiple of the slack she is given.
		///
		/// It is `pet + grid` in both cases: the panel's grid is zero, which is exactly
		/// its old behaviour rather than a special case.
		func windowSide(petSize: Double) -> Double {
			petSize + (self == .hybrid ? petSize : 0)
		}

		var title: String {
			switch self {
			case .panel: "pet panel"
			case .hybrid: "pet hybrid panel"
			}
		}
	}

	private let controller: PetController
	private var displaySpace: DisplaySpace
	private let mode: Mode
	private let panel: PetChromePanel
	private let root: OverlayPetRootView
	private let pet: CALayer
	private let pinch: CheekPinchLayer
	/// The last sprite frame, kept so the cheek overlay can be drawn against it
	/// without the controller handing it over again.
	private var baseFrame: CGImage?

	/// The dots that hold the window's **shape** at its full size.
	///
	/// A Space transition freezes each window's shape — the region its opaque pixels
	/// cover — at the moment it begins, and goes on updating the contents, so anything
	/// that moves out of that region is cut off. She is a layer that moves **inside**
	/// this window, so without something holding the shape at the window's bounds her own
	/// silhouette would be the region, and she would be sliced the moment she walked. The
	/// overlay needs the same thing for the same reason; the dots are the same 1/255
	/// points, placed at the window's extremes instead of the display's.
	///
	/// One 8-bit step of alpha is part of the shape and far too little to be seen, and a
	/// click is still routed per pixel, so the window's empty half stays click-through.
	private var shapeDots: [CALayer] = []

	/// The size the dots were last laid out for, so they are rebuilt only on a reshape.
	private var shapeDotsSize: CGSize = .zero

	/// The window's origin the last time she was placed, to tell a frame that moved the
	/// window from one that only moved her inside it.
	private var lastWindowOrigin: PixelPoint?

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

	public init(controller: PetController, displaySpace: DisplaySpace, mode: Mode = .panel) {
		self.controller = controller
		self.displaySpace = displaySpace
		self.mode = mode

		let side = mode.windowSide(petSize: controller.petSize)
		let size = NSRect(x: 0, y: 0, width: side, height: side)
		panel = PetChromePanel(contentRect: size)
		root = OverlayPetRootView(frame: size)
		pet = CALayer()
		pinch = CheekPinchLayer()

		super.init()

		panel.title = mode.title

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

	/// How far she may move inside the window before the window itself has to go
	/// somewhere else. Zero for the panel, whose window is exactly her size and so gives
	/// her no slack at all.
	private var grid: Double {
		mode == .hybrid ? controller.petSize : 0
	}

	/// Where her window goes, and where she sits inside it.
	///
	/// The hybrid places the window on a grid one pet wide and draws her at the
	/// remainder, so between two window moves she moves by changing only her own layer's
	/// position and the window's own rectangle never changes. The grid is zero for the
	/// panel, which degenerates to "the window is exactly where she is".
	///
	/// `floor` rather than a rounded division so the remainder is always in `[0, grid)`,
	/// which is what keeps her inside the slack; it also puts her window at a negative
	/// multiple of the grid when she hangs past the left or top edge, which is fine.
	private func placement(for petFrame: PixelRect) -> (window: PixelRect, layer: CGPoint) {
		let side = mode.windowSide(petSize: controller.petSize)
		let grid = self.grid
		guard grid > 0 else {
			return (
				PixelRect(x: petFrame.x, y: petFrame.y, width: side, height: side),
				.zero
			)
		}
		let x = (petFrame.x / grid).rounded(.down) * grid
		let y = (petFrame.y / grid).rounded(.down) * grid
		return (
			PixelRect(x: x, y: y, width: side, height: side),
			CGPoint(x: petFrame.x - x, y: petFrame.y - y)
		)
	}

	/// Puts the window, and her inside it, where the controller says she is.
	private func applyPlacement() {
		let petFrame = controller.petFrame
		let (windowOrigin, layerPosition) = placement(for: petFrame)
		let target = DisplaySpace.toAppKit(
			windowOrigin,
			primaryHeight: displaySpace.primaryHeight
		)
		// Whether this frame has to put the window somewhere else, as opposed to only
		// moving her inside it. True on the panel's every frame she moves, which is what
		// keeps that mode's geometry — and its measurements — exactly what they were.
		let origin = PixelPoint(x: windowOrigin.x, y: windowOrigin.y)
		let movedWindow = origin != lastWindowOrigin
		lastWindowOrigin = origin

		if panel.frame.size != target.size {
			// She was resized (a menu action), or the window does not have this mode's size
			// yet. A reshape cannot go through the private call — it moves a window, it does
			// not resize one — so this rare one goes to AppKit, which also reasserts the
			// frame it believes in. It is also the one route that can place a window the
			// private call is not moving yet.
			panel.setFrame(target, display: true)
			appKitOrigin = panel.frame.origin
			FrameInterpolation.withoutAnimation { updatePetLayer(layerPosition: layerPosition) }
			onPlacementChanged?(petFrame)
			return
		}

		if mode == .hybrid {
			// The window and her layer move **together**, in one transaction: on a grid
			// crossing the window steps a whole pet and her layer steps back by the same
			// amount, so the two must reach the compositor in the same frame or she is
			// seen a grid away for however long separates them. AppKit's move is
			// coalesced with the Core Animation commit and the private call is not — that
			// is the whole reason this mode does not use it.
			if movedWindow {
				FrameInterpolation.withoutAnimation {
					panel.setFrameOrigin(target.origin)
					updatePetLayer(layerPosition: layerPosition)
				}
			} else {
				// Between crossings only her layer moves, and that is free to glide.
				FrameInterpolation.animate { updatePetLayer(layerPosition: layerPosition) }
			}
			appKitOrigin = panel.frame.origin
			onPlacementChanged?(petFrame)
			return
		}

		if place(windowOrigin: windowOrigin) {
			appKitOrigin = target.origin
		} else {
			// The move could not be made through the private call yet — the window has no
			// device, or the call is unavailable. AppKit is authoritative, so its own frame
			// stays the truth and the correction collapses to nothing.
			panel.setFrameOrigin(target.origin)
			appKitOrigin = panel.frame.origin
		}

		// A frame that moved the window has to land in that frame: her layer position is
		// unchanged here (the panel gives her no slack), and animating a position that is
		// already where it belongs is only a way to be a frame late.
		let update = { self.updatePetLayer(layerPosition: layerPosition) }
		if movedWindow {
			FrameInterpolation.withoutAnimation(update)
		} else {
			FrameInterpolation.animate(update)
		}
		onPlacementChanged?(petFrame)
	}

	/// Places the window through the private call, where it is the chosen route and the
	/// window is known to take it.
	///
	/// The first attempt is verified rather than trusted: it is the one made on a window
	/// that may have just been ordered on screen and has no device yet. Once it is
	/// confirmed the window is really moved, the steady state stops paying for the read —
	/// a window that is being composited and answers the call is not going to ignore it.
	private func place(windowOrigin: PixelRect) -> Bool {
		switch placement {
		case .appKit:
			guard panel.isVisible else { return false }
			let windowID = UInt32(panel.windowNumber)
			guard
				PetPanelMover.move(
					windowID: windowID,
					to: PixelPoint(x: windowOrigin.x, y: windowOrigin.y)
				),
				let actual = PetPanelMover.bounds(of: windowID),
				// The read is already in the window server's space, so it compares directly.
				abs(actual.x - windowOrigin.x) <= 1,
				abs(actual.y - windowOrigin.y) <= 1
			else { return false }
			placement = .privateMove
			return true

		case .privateMove:
			let moved = PetPanelMover.move(
				windowID: UInt32(panel.windowNumber),
				to: PixelPoint(x: windowOrigin.x, y: windowOrigin.y)
			)
			if !moved {
				// The window was taken away under us. AppKit is authoritative again.
				placement = .appKit
			}
			return moved
		}
	}

	private func updatePetLayer(layerPosition: CGPoint) {
		let size = panel.frame.size
		if shapeDotsSize != size {
			shapeDotsSize = size
			layoutShapeDots(in: size)
		}

		let side = controller.petSize
		pet.bounds = CGRect(x: 0, y: 0, width: side, height: side)
		// The pivot is her bottom centre, in the flipped root: the lean rotates on the
		// ground rather than sliding her sideways.
		pet.position = CGPoint(x: layerPosition.x + side / 2, y: layerPosition.y + side)
		pet.contentsScale = hostingScale
		pet.transform = PetLayerTransform.make(
			lean: controller.bodyLeanDegrees,
			facing: controller.facing
		)
		// The hit test's two rectangles: her square inside the window, and her body
		// ellipse within that square.
		root.petRect = CGRect(x: layerPosition.x, y: layerPosition.y, width: side, height: side)
		root.bodyEllipse = controller.bodyEllipseInView
	}

	/// Puts the shape dots at the window's extremes, under her own layer.
	private func layoutShapeDots(in size: CGSize) {
		for dot in shapeDots { dot.removeFromSuperlayer() }
		shapeDots = OverlayPetWindowController.shapeCorners(in: size).map { corner in
			let dot = CALayer()
			dot.anchorPoint = .zero
			dot.bounds = CGRect(origin: .zero, size: corner.size)
			dot.position = corner.origin
			dot.backgroundColor = CGColor(
				red: 0,
				green: 0,
				blue: 0,
				alpha: OverlayPetWindowController.shapeCornerAlpha
			)
			dot.actions = OverlayPetWindowController.shapeCornerActions
			root.layer?.insertSublayer(dot, below: pet)
			return dot
		}
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
