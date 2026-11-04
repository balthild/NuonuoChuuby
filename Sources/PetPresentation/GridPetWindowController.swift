import AppKit
import PetBehaviour
import PetDesktop
import PetFoundation
import PetSimulation

/// Puts the pet on screen in a small window that goes to where she is, instead of a
/// full-display window that never moves.
///
/// The window is **twice** her size and placed on a grid one pet wide, with her drawn at
/// the remainder. Between two grid crossings she moves by changing only her own layer's
/// position, which *is* interpolated, so her motion glides; the window itself is moved
/// once per pet of travel rather than once per tick. The larger window still costs
/// almost nothing in mouse-move delivery — the cost a full-display window cannot avoid
/// at any size, because it is under the pointer wherever the pointer is.
///
/// The window is moved with AppKit's own move, which is coalesced with the Core
/// Animation commit. That is required, not incidental: on a grid crossing the window
/// steps a whole pet and her layer steps back by the same amount, so the two have to
/// reach the compositor in the same frame. The private `CGSMoveWindow` is not coalesced,
/// and using it tore the two apart — she was seen a grid away for as long as the commit
/// lagged.
///
/// She stays a **layer** inside the window rather than a drawn view, so the sprite
/// reaches the compositor as `contents` and no CoreGraphics resampling happens per
/// frame — the same reason the overlay draws her that way.
///
/// The head bubble is a layer of this same window, in the slack it leaves. The ghost
/// icons get a window each (``GridGhostIcon``): a ghost stands where a file used to
/// be, which can be anywhere on the display and is rarely near her.
@MainActor
public final class GridPetWindowController: NSObject, PetControllerDelegate, PetPresenting {
	private let controller: PetController
	private var displaySpace: DisplaySpace
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

	/// The bubble, a layer of this window.
	///
	/// Lazy so it can host from `self` — a stored property has to be initialised before
	/// `super.init`, and the host is this object. Everything that touches it runs well
	/// after that.
	private lazy var bubble: OverlaySpeechBubbleController = {
		let bubble = OverlaySpeechBubbleController(host: self)
		bubble.onExtentChanged = { [weak self] in self?.bubbleExtentChanged() }
		return bubble
	}()

	/// The bubble layer drawn inside her window, above her sprite.
	private let bubbleLayer = CALayer()

	/// The window's rectangle the bubble converts its global position against.
	///
	/// Held rather than read from `panel.frame`, which is only reasserted by AppKit on a
	/// reshape.
	private var bubbleWindowFrame: PixelRect = .zero

	/// Whether the placement being applied right now moved the window.
	///
	/// The bubble is drawn at an offset inside this window, so a window move shifts its
	/// local position by the opposite amount to keep it still on screen; that shift has
	/// to land in the same frame, or she is seen with the bubble a whole pet away while it
	/// glides back.
	private var windowMovedThisFrame = false

	/// Whether a placement pass is running, so a reserve change it causes is folded into
	/// the same pass rather than recursing.
	private var isPlacing = false
	/// Set when the reserve changed during a pass, so the pass is repeated once with it.
	private var needsAnotherPass = false

	public var menuProvider: ((NSEvent) -> NSMenu?)?
	public var onPlacementChanged: ((PixelRect) -> Void)?
	public var onSuspensionChanged: ((Bool) -> Void)?

	/// The bubble is a layer of her window, in the slack the window leaves for it.
	public var speechBubble: any SpeechBubblePresenting { bubble }

	public init(controller: PetController, displaySpace: DisplaySpace) {
		self.controller = controller
		self.displaySpace = displaySpace

		let side = controller.petSize * 2
		let size = NSRect(x: 0, y: 0, width: side, height: side)
		panel = PetChromePanel(contentRect: size)
		root = OverlayPetRootView(frame: size)
		pet = CALayer()
		pinch = CheekPinchLayer()

		super.init()

		panel.title = "pet grid window"

		root.autoresizingMask = [.width, .height]
		root.wantsLayer = true
		// The root draws nothing at all, so it must never be asked to redraw.
		root.layerContentsRedrawPolicy = .never
		// The view is flipped, so the pet's sublayer must share its top-left origin
		// for the two coordinate systems to agree.
		root.layer?.isGeometryFlipped = true

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
		wireGestures(root)

		// Her window's bubble: a layer above her, in the slack the window leaves.
		bubbleLayer.anchorPoint = .zero
		bubbleLayer.contentsGravity = .resize
		bubbleLayer.minificationFilter = .linear
		bubbleLayer.magnificationFilter = .linear
		bubbleLayer.isOpaque = false
		bubbleLayer.isHidden = true
		root.layer?.addSublayer(bubbleLayer)
		// Touching the lazy bubble now wires its extent callback, before the first pass
		// reads the room it needs.
		_ = bubble

		controller.delegate = self
		applyPlacement()
	}

	public func show() {
		panel.orderFrontRegardless()
		// Ordering a window in lets AppKit reassert the frame it believes in, so the
		// real position has to be put back afterwards.
		applyPlacement()
	}

	public func hide() {
		// A suspension can land while she is in one of the states that use the overlay, and
		// the surface would otherwise outlive the window it belongs to.
		if usesOverlaySurface {
			usesOverlaySurface = false
			pet.isHidden = false
		}
		overlaySurface?.hide()
		panel.orderOut(nil)
	}

	public func updateDisplaySpace(_ space: DisplaySpace) {
		displaySpace = space
		// A state that spans the change would leave the surface sized for the old set of
		// displays, and nothing else re-sizes it while it is up.
		if usesOverlaySurface { overlaySurface?.show(covering: space) }
		applyPlacement()
	}

	public func makeGhostIcon() -> any GhostIconPresenting {
		GridGhostIcon(displaySpace: displaySpace)
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

	/// The room the showing bubble needs around her.
	///
	/// The bubble is centred on her, so both sides need the same; and it goes above her
	/// head or below her feet, so only one of those needs anything. Reserving the whole
	/// bubble height rather than the part that actually pokes out is deliberate: the
	/// layout tucks the bubble slightly into her square, and the difference is a couple
	/// of points.
	private struct Reserve {
		var horizontal: Double = 0
		var above: Double = 0
		var below: Double = 0
	}

	private func reserve(petSize: Double) -> Reserve {
		guard let extent = bubble.currentExtent else { return Reserve() }
		return Reserve(
			horizontal: max(0, (Double(extent.size.width) - petSize) / 2),
			above: extent.tail == .down ? Double(extent.size.height) : 0,
			below: extent.tail == .up ? Double(extent.size.height) : 0
		)
	}

	/// Where her window goes, and where she sits inside it.
	///
	/// The window is placed on a grid one pet wide and she is drawn at the remainder, so
	/// between two window moves she moves by changing only her own layer's position and
	/// the window's own rectangle never changes.
	///
	/// The grid is **shifted** by the reserve rather than widened: the window's origin is
	/// still a whole number of grid steps, which is what keeps the window still while she
	/// walks inside the slack. Widening the grid instead would put her offset anywhere in
	/// `[0, grid)` and let the bubble hang out of the window.
	///
	/// `floor` rather than a rounded division so the remainder is always in `[0, grid)`,
	/// which is what keeps her inside the slack; it also puts her window at a negative
	/// multiple of the grid when she hangs past the left or top edge, which is fine.
	private func placement(
		for petFrame: PixelRect
	) -> (
		window: PixelRect, size: NSSize, layer: CGPoint
	) {
		let petSize = controller.petSize
		let reserve = self.reserve(petSize: petSize)
		let grid = petSize
		let x = (petFrame.x / grid).rounded(.down) * grid
		let y = (petFrame.y / grid).rounded(.down) * grid
		return (
			PixelRect(
				x: x - reserve.horizontal,
				y: y - reserve.above,
				width: petSize * 2 + reserve.horizontal * 2,
				height: petSize * 2 + reserve.above + reserve.below
			),
			NSSize(
				width: petSize * 2 + reserve.horizontal * 2,
				height: petSize * 2 + reserve.above + reserve.below
			),
			CGPoint(
				x: petFrame.x - x + reserve.horizontal,
				y: petFrame.y - y + reserve.above
			)
		)
	}

	/// Puts the window, and her inside it, where the controller says she is.
	private func applyPlacement() {
		// First, because the rest of this decides which window she is drawn in.
		syncOverlaySurface()

		isPlacing = true
		defer {
			isPlacing = false
			// The bubble's own extent can change *during* a pass — the tail flips when
			// her head crosses the menu bar — and the window then has the wrong size for
			// the bubble it is about to draw. One more pass with the new reserve settles
			// it, and it cannot oscillate: the reserve is a function of where she is, not
			// of the window.
			if needsAnotherPass {
				needsAnotherPass = false
				applyPlacement()
			}
		}

		let petFrame = controller.petFrame

		if usesOverlaySurface, let surface = overlaySurface {
			// She is drawn in the overlay, at her global position. The small window stays
			// exactly where it is — all it is doing is holding the mouse capture, if it has
			// it — and is not even redrawn, so this frame costs one layer's position.
			//
			// Inside `FrameInterpolation`, deliberately: her layer has no implicit
			// `position` action, so outside a transaction that position would fall back to
			// Core Animation's default quarter-second easing and she would trail the
			// cursor by a fifth of a second for the whole drag.
			FrameInterpolation.animate {
				surface.place(
					petFrame: petFrame,
					size: controller.petSize,
					transform: Self.transform(for: controller),
					scale: hostingScale,
					bodyEllipse: controller.bodyEllipseInView
				)
			}
			onPlacementChanged?(petFrame)
			return
		}

		let (windowOrigin, windowSize, layerPosition) = placement(for: petFrame)
		let target = DisplaySpace.toAppKit(
			windowOrigin,
			primaryHeight: displaySpace.primaryHeight
		)
		// Whether this frame has to put the window somewhere else, as opposed to only
		// moving her inside it: true once per pet of travel.
		let origin = PixelPoint(x: windowOrigin.x, y: windowOrigin.y)
		let movedWindow = origin != lastWindowOrigin
		lastWindowOrigin = origin
		windowMovedThisFrame = movedWindow
		// Where the bubble's host converts a global point into window-local ones.
		bubbleWindowFrame = windowOrigin

		if panel.frame.size != windowSize {
			// She was resized (a menu action), or the bubble's reserve changed. A reshape
			// cannot go through a move — this changes the size, not the origin — so it
			// goes to AppKit, which also reasserts the frame it believes in.
			panel.setFrame(target, display: true)
			FrameInterpolation.withoutAnimation { updatePetLayer(layerPosition: layerPosition) }
			onPlacementChanged?(petFrame)
			return
		}

		// The window and her layer move **together**, in one transaction: on a grid
		// crossing the window steps a whole pet and her layer steps back by the same
		// amount, so the two must reach the compositor in the same frame or she is seen a
		// grid away for however long separates them. AppKit's move is coalesced with the
		// Core Animation commit; the private `CGSMoveWindow` is not, which is why this
		// renderer does not use it.
		if movedWindow {
			FrameInterpolation.withoutAnimation {
				panel.setFrameOrigin(target.origin)
				updatePetLayer(layerPosition: layerPosition)
			}
		} else {
			// Between crossings only her layer moves, and that is free to glide.
			FrameInterpolation.animate { updatePetLayer(layerPosition: layerPosition) }
		}
		onPlacementChanged?(petFrame)
	}

	/// Whether she is drawn in the overlay instead of her own window.
	///
	/// True in the two states where she moves fast enough that keeping a window next to her
	/// would mean moving that window every few frames — ``PetController/isBeingDragged``
	/// and ``PetController/isMovingInsideEnclosure``.
	///
	/// Never set directly: see ``syncOverlaySurface()``, which is the only writer. The two
	/// used to be driven by the up and down gestures separately, and the conditions did
	/// not match — a press could raise the surface through a path where the drag was
	/// refused, and the release could take the other branch and never lower it. What that
	/// left behind was her drawn in a surface that takes no clicks, over a small window
	/// that had stopped following her: visible, and impossible to click.
	private var usesOverlaySurface = false

	/// The full-display window she is drawn into while one of those states lasts, built on
	/// demand.
	private var overlaySurface: OverlayPetSurface?

	/// The bubble changed the room it needs, so the next pass has to size the window
	/// for it.
	private func bubbleExtentChanged() {
		if isPlacing {
			needsAnotherPass = true
		} else {
			applyPlacement()
		}
	}

	// MARK: - The overlay surface

	/// Whether she should be drawn in the overlay rather than in her own window.
	///
	/// The two states are the same situation: she is being moved fast. A drag puts her
	/// wherever the pointer goes at pointer speed, and a window's box throws her around at
	/// up to `maximumVelocityX`/`maximumVelocityY` — both far above her own walking pace.
	/// In either one the grid window would move every few frames, so it stops moving at all.
	private var wantsOverlaySurface: Bool {
		controller.isBeingDragged || controller.isMovingInsideEnclosure
	}

	/// Raises or lowers the full-display window she is drawn into, to match whether she is
	/// in one of the states that wants it.
	///
	/// The controller is the one truth here, and this is the only place that acts on it,
	/// so the surface cannot outlive the state or lag behind it — including a release the
	/// process never saw. It is called from ``applyPlacement()``, which runs every frame.
	///
	/// Why the surface exists at all: in both states she moves on every frame, far faster
	/// than she ever walks, so keeping the small window next to her would mean moving it
	/// every few frames. Moving a window is the most expensive thing this renderer does,
	/// and the grid only makes it rarer; a window that is never moved costs one layer
	/// position per frame, which is the cheapest thing there is.
	///
	/// The trade is the window's size: it is under the pointer everywhere, which is what
	/// the small window exists to avoid. It is worth taking because both states are
	/// short-lived — a drag ends when the button comes up, and a box stops throwing her
	/// around once she settles on its floor — so the exposure is bounded by them.
	///
	/// The small window stays up and keeps the mouse capture, if it has it. AppKit
	/// delivers the rest of a drag to the window that took the button down, wherever the
	/// pointer goes, so it does not have to follow her — and not following it is the point.
	private func syncOverlaySurface() {
		let wanted = wantsOverlaySurface
		guard wanted != usesOverlaySurface else { return }
		usesOverlaySurface = wanted

		guard wanted else {
			overlaySurface?.hide()
			pet.isHidden = false
			return
		}
		if overlaySurface == nil {
			let surface = OverlayPetSurface()
			wireGestures(surface.root)
			overlaySurface = surface
		}
		guard let surface = overlaySurface else { return }
		surface.show(covering: displaySpace)
		// She appears in the new window at the position she had in the old one, so the
		// handover is invisible.
		surface.pet.contents = pet.contents
		surface.pet.transform = pet.transform
		pet.isHidden = true
		bubbleLayer.isHidden = true
	}

	/// Her lean and mirror, the one place they are worked out.
	private static func transform(for controller: PetController) -> CATransform3D {
		PetLayerTransform.make(lean: controller.bodyLeanDegrees, facing: controller.facing)
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
		pet.transform = Self.transform(for: controller)
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

	// MARK: - Gestures

	/// The point arrives in the **pet's** own space, which is the space `cheekHitTest`
	/// and the pinch take.
	///
	/// Each handler ends by asking for a placement pass, because that is what reconciles
	/// the overlay surface with what the controller actually has. Nothing here decides that
	/// for itself, and deliberately so: deciding it from the gesture — a press starts a
	/// drag, a release ends one — is what let the two drift apart, since a press can be
	/// refused by the drag policy and a release can arrive while a pinch is still
	/// settling.
	///
	/// Wired for **both** the roots she can be drawn in, out of the same closure: whichever
	/// window she is in, a press on her is the same gesture. Wiring the overlay's root here
	/// rather than there is also what keeps her clickable in it, which matters because that
	/// window is up with the pointer free whenever a box is throwing her around.
	private func wireGestures(_ root: OverlayPetRootView) {
		root.onMouseDown = { [weak self] _, petLocal in
			guard let self else { return }
			if let side = self.controller.cheekHitTest(viewPoint: petLocal) {
				self.controller.beginPinch(side: side, at: petLocal)
			} else {
				self.controller.beginDrag(at: self.globalCursor)
			}
			// `beginDrag` may have been refused (she is pinching, climbing, rolling), and
			// she may not move for a frame or two, so nothing else would run this pass.
			self.applyPlacement()
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
			// Both, without choosing: a pinch and a drag are mutually exclusive, and
			// `endDrag` and the surface are no-ops when nothing is running.
			self.controller.endPinch()
			self.controller.endDrag(at: self.globalCursor)
			self.applyPlacement()
		}
		root.onRightMouseDown = { [weak self, weak root] event in
			guard let self, let root, let menu = self.menuProvider?(event) else { return }
			NSMenu.popUpContextMenu(menu, with: event, for: root)
		}
	}

	// MARK: - PetControllerDelegate

	public func petController(_ controller: PetController, didProduceFrame image: CGImage) {
		baseFrame = image
		let transform = Self.transform(for: controller)
		pet.contents = image
		pet.transform = transform
		// Both, so whichever window is showing has this frame without anything having to
		// copy it across at the handover.
		overlaySurface?.pet.contents = image
		overlaySurface?.pet.transform = transform
	}

	public func petController(
		_ controller: PetController,
		didUpdateCheekPinch pinchState: CheekPinchState?
	) {
		// The lean follows the pull, and a pinch can hold one sprite frame for many
		// ticks — so it has to be re-applied here, not only with a new frame.
		pet.transform = Self.transform(for: controller)
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

/// The grid renderer's bubble is a layer of her window, so this is where it is told which
/// layer to draw into and where that window currently is.
///
/// The frame handed over is the window's own rectangle, not a display's: the bubble's
/// global top-left is turned into window-local coordinates against it, which is what the
/// root layer's flipped space expects. It is the window the *last* placement put her in,
/// which is what the bubble is being positioned for.
@MainActor
extension GridPetWindowController: SpeechBubbleLayerHosting {
	public func speechBubbleLayer(at point: PixelPoint) -> SpeechBubbleLayerTarget? {
		// While she is in the overlay the bubble rides in it with her, in the same window, so
		// it follows for the same reason she does: one layer's position and no window move.
		// That window never moves, so nothing has to land instantly.
		if usesOverlaySurface, let surface = overlaySurface {
			return SpeechBubbleLayerTarget(
				layer: surface.bubble,
				displayFrame: surface.frame,
				scale: hostingScale,
				isDark: panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
			)
		}
		return SpeechBubbleLayerTarget(
			layer: bubbleLayer,
			displayFrame: bubbleWindowFrame,
			scale: hostingScale,
			isDark: panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
			landsInstantly: windowMovedThisFrame
		)
	}
}
