import AppKit
import PetFoundation
import QuartzCore

/// The conventions every layer she is drawn in follows: how she is placed in one, what
/// each kind of layer must never animate, and the dots that hold a window's shape.
///
/// These are here rather than on a renderer because **both** renderers — and the
/// full-display surface they share — need the same answers, and a renderer holding them
/// would make the others reach into it for its constants. What the layers must agree on
/// is the point: a key missing from an actions dictionary means that property starts
/// easing over the default ~0.25 s, which is invisible in one renderer and a visible
/// glitch in the other.
///
/// Main-actor isolated because the actions dictionaries hold `NSNull`, which is not
/// `Sendable` — and because every one of these belongs to AppKit's main thread anyway.
@MainActor
enum PetLayerConventions {
	// MARK: - Placing her

	/// How the pet is placed inside her layer: the lean, and the mirror.
	///
	/// Mirroring is applied **after** the lean: the lean is a rotation about her foot,
	/// and mirroring that afterwards is what puts a pulled cheek's lean on the same
	/// side of the screen as the pointer.
	static func transform(lean: Double, facing: Double) -> CATransform3D {
		let rotate = CATransform3DMakeRotation(CGFloat(lean) * .pi / 180, 0, 0, 1)
		guard facing < 0 else { return rotate }
		return CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), rotate)
	}

	// MARK: - Playing a looping clip

	/// The key a handed-over loop is stored under, so it can be replaced and removed by
	/// name rather than by clearing whatever else the layer happens to be animating.
	static let loopAnimationKey = "clipLoop"

	/// Puts a looping clip on the layer, for the render server to play.
	///
	/// The frames are discrete values, not a curve: without `calculationMode = .discrete` CA
	/// interpolates, and `contents` interpolating means cross-fading one frame into the
	/// next — the same reason `petActions` forbids an implicit animation on it.
	///
	/// The model value is set to the cycle's first frame as well, so that a layer which
	/// loses the animation (one just built, say) shows her rather than nothing.
	static func play(_ loop: SpriteLoop, on layer: CALayer) {
		guard !loop.frames.isEmpty else { return }
		let animation = CAKeyframeAnimation(keyPath: "contents")
		animation.calculationMode = .discrete
		// One more time than frame: `keyTimes` has to run 0 → 1, and that last entry is the
		// value at the end of the cycle, which is the first frame again.
		animation.values = loop.frames + [loop.frames[0]]
		animation.keyTimes = (0...loop.frames.count).map {
			NSNumber(value: Double($0) / Double(loop.frames.count))
		}
		animation.duration = loop.cycleSeconds
		animation.repeatCount = .infinity
		layer.contents = loop.frames[0]
		layer.add(animation, forKey: loopAnimationKey)
	}

	static func stopLoop(on layer: CALayer) {
		layer.removeAnimation(forKey: loopAnimationKey)
	}

	/// Whether the render server is the one advancing this layer's frames.
	static func isPlayingLoop(on layer: CALayer) -> Bool {
		layer.animation(forKey: loopAnimationKey) != nil
	}

	/// Which of `frames` the render server has up on this layer.
	///
	/// Read from `presentation()`, not from the model value, because the animation is what
	/// decides the frame actually on screen. The pinch samples her skin colour from this.
	static func presentedFrame(of layer: CALayer, among frames: [CGImage]) -> CGImage? {
		guard let presented = layer.presentation()?.contents as AnyObject? else { return nil }
		return frames.first { ($0 as AnyObject) === presented }
	}

	/// Copies what one pet layer is showing onto another, for the handover to the
	/// full-display surface.
	///
	/// The surface is built on demand, so it has never been sent anything: without this it
	/// comes up empty, and — since a drag is one of the states that raises it, and dragging
	/// is a looping clip — it would come up **standing perfectly still** for the whole drag.
	///
	/// A loop that was running is started again from the top rather than at the phase it had
	/// reached. Every handover so far coincides with a clip change (a drag starting or
	/// ending), and a clip change restarts the clip anyway, so there is nothing to preserve;
	/// if that stops being true, the phase is where to look.
	static func handOver(from source: CALayer, to target: CALayer) {
		target.contents = source.contents
		target.transform = source.transform
		guard let animation = source.animation(forKey: loopAnimationKey) as? CAKeyframeAnimation,
			let values = animation.values as? [CGImage], values.count > 1
		else {
			stopLoop(on: target)
			return
		}
		let cycle = Array(values.dropLast())
		play(
			SpriteLoop(
				clip: loopAnimationKey,
				frames: cycle,
				frameSeconds: animation.duration / Double(max(cycle.count, 1))
			),
			on: target
		)
	}

	// MARK: - What may never animate

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
	static let petActions: [String: CAAction] = [
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
	static let bubbleActions: [String: CAAction] = [
		"bounds": NSNull(),
		"contents": NSNull(),
		"contentsScale": NSNull(),
		"hidden": NSNull(),
	]

	/// What the corner dots must never animate: they never move.
	static let shapeCornerActions: [String: CAAction] = [
		"bounds": NSNull(),
		"position": NSNull(),
		"backgroundColor": NSNull(),
		"hidden": NSNull(),
	]

	// MARK: - Holding a window's shape

	/// One 8-bit step of alpha: enough to be part of the window's shape, far too little to
	/// be seen.
	static let shapeCornerAlpha: CGFloat = 1.0 / 255.0

	/// How far each dot sits from the edge of the window.
	///
	/// A pointer reaches a screen edge easily — it stops there — so an anchor on the edge
	/// would be the one place these dots could take a click by accident. One point in from
	/// it is somewhere a hand practically never lands.
	///
	/// The cost is that the shape — their bounding box — loses this much on all four sides,
	/// so during a transition the outermost point of the window is cut. For the overlay
	/// that is her feet, which land exactly on the display's bottom edge: one point of them
	/// goes, and it has not been visible.
	static let shapeCornerInset: CGFloat = 1

	/// Where the anchors go: their **bounding box** is what holds the window's shape, so
	/// between them they have to reach all four of its extremes.
	///
	/// **Three** dots suffice, and the third can go anywhere along the opposite edge: the
	/// two at the bottom set the left, right and bottom, and one more sets the top. It is
	/// put at the **top centre** rather than at a second corner because the overlay covers
	/// the display, where both top corners are live controls — the Apple menu on the left,
	/// Notification Centre on the right — and the middle of the menu bar holds nothing on a
	/// laptop but the notch. The grid window reuses the same geometry; there the top corners
	/// are free, but one set of dots for both is worth more than saving a dot.
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
}
