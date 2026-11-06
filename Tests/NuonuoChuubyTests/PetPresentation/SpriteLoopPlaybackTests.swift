import CoreGraphics
import QuartzCore
import Testing

@testable import PetFoundation
@testable import PetPresentation

/// What a handed-over loop does to a layer.
///
/// The frames themselves are the animator's business (`SpriteAnimatorTests`); this is the
/// animation built from them, and whether handing a layer over to another one keeps her
/// animating — the case that decides whether a drag freezes her.
@MainActor
@Suite("Looped clip playback")
struct SpriteLoopPlaybackTests {
	private func frames(_ count: Int) -> [CGImage] {
		(0..<count).compactMap { index in
			let context = CGContext(
				data: nil,
				width: 4,
				height: 4,
				bitsPerComponent: 8,
				bytesPerRow: 16,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
			context?.setFillColor(CGColor(gray: CGFloat(index) / CGFloat(max(count, 1)), alpha: 1))
			context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
			return context?.makeImage()
		}
	}

	private func loop(count: Int = 4, seconds: Double = 0.1) -> SpriteLoop {
		SpriteLoop(clip: "test", frames: frames(count), frameSeconds: seconds)
	}

	private let key = PetLayerConventions.loopAnimationKey

	@Test("Playing a loop hands the whole cycle to one discrete animation")
	func playingInstallsOneDiscreteAnimation() throws {
		let layer = CALayer()
		let cycle = loop(count: 4, seconds: 0.1)
		PetLayerConventions.play(cycle, on: layer)

		let animation = try #require(
			layer.animation(forKey: key) as? CAKeyframeAnimation,
			"no animation on the layer"
		)
		#expect(animation.keyPath == "contents")
		// Discrete, or CA interpolates — and interpolating `contents` cross-fades one frame
		// into the next, which is the smearing `petActions` forbids it for.
		#expect(animation.calculationMode == .discrete)
		// One more value than frame: `keyTimes` has to reach 1, and that last value is the
		// end of the cycle, which is the first frame again.
		#expect(animation.values?.count == 5)
		#expect(animation.keyTimes?.count == 5)
		#expect(animation.keyTimes?.first as? Double == 0)
		#expect(animation.keyTimes?.last as? Double == 1)
		#expect(animation.duration == 0.4)
		#expect(animation.repeatCount == .infinity)
		// The model value, so a layer that loses the animation still shows her.
		#expect((layer.contents as AnyObject?) === (cycle.frames[0] as AnyObject))
		#expect(PetLayerConventions.isPlayingLoop(on: layer))
	}

	@Test("Stopping takes the animation off and leaves the frame it was on")
	func stoppingRemovesOnlyTheLoop() throws {
		let layer = CALayer()
		let cycle = loop()
		PetLayerConventions.play(cycle, on: layer)
		// Something else's animation must survive: this one is removed by name.
		let other = CABasicAnimation(keyPath: "opacity")
		layer.add(other, forKey: "unrelated")

		PetLayerConventions.stopLoop(on: layer)

		#expect(!PetLayerConventions.isPlayingLoop(on: layer))
		#expect(layer.animation(forKey: "unrelated") != nil)
		#expect((layer.contents as AnyObject?) === (cycle.frames[0] as AnyObject))
	}

	@Test("A handover carries the loop, so a drag does not freeze")
	func handoverCarriesTheLoop() throws {
		let source = CALayer()
		let target = CALayer()
		let cycle = loop(count: 6, seconds: 0.05)
		PetLayerConventions.play(cycle, on: source)
		source.transform = CATransform3DMakeScale(-1, 1, 1)

		PetLayerConventions.handOver(from: source, to: target)

		let carried = try #require(
			target.animation(forKey: key) as? CAKeyframeAnimation,
			"the loop did not come across — she would stand still for the whole drag"
		)
		#expect(carried.values?.count == 7)
		#expect(abs(carried.duration - 0.3) < 0.0001)
		#expect(carried.calculationMode == .discrete)
		#expect(CATransform3DEqualToTransform(target.transform, source.transform))
	}

	@Test("A handover with no loop running leaves the target without one")
	func handoverWithoutALoopClearsTheTarget() throws {
		let source = CALayer()
		let target = CALayer()
		PetLayerConventions.play(loop(), on: target)
		source.contents = frames(1).first

		PetLayerConventions.handOver(from: source, to: target)

		#expect(
			!PetLayerConventions.isPlayingLoop(on: target),
			"a loop that is not playing must not be carried over"
		)
		#expect((target.contents as AnyObject?) === (source.contents as AnyObject?))
	}

	@Test("Asking a layer which frame is up is safe when it is not rendering")
	func presentedFrameIsSafeOffScreen() {
		// A layer in no window has no presentation, and the pinch asks on every pinch tick.
		// The positive case — that it names the frame really on screen — needs a window and
		// an eye, which is how it was checked.
		let layer = CALayer()
		let cycle = loop()
		PetLayerConventions.play(cycle, on: layer)
		#expect(PetLayerConventions.presentedFrame(of: layer, among: cycle.frames) == nil)
	}
}
