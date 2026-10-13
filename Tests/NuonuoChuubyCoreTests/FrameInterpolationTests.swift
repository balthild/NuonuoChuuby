import AppKit
import QuartzCore
import Testing

@testable import NuonuoChuubyCore

@Suite("Frame interpolation")
@MainActor
struct FrameInterpolationTests {
	/// One tick: the interpolation has to span exactly the gap between two positions,
	/// since a shorter one finishes early and stalls and a longer one just adds lag.
	@Test("The glide lasts exactly one simulation tick")
	func durationIsOneTick() {
		#expect(FrameInterpolation.duration == 1.0 / 60)
	}

	@Test("The follow animation sets a linear duration on the transaction")
	func animateSetsTheTransaction() {
		FrameInterpolation.animate {
			#expect(CATransaction.animationDuration() == FrameInterpolation.duration)
			// Linear, so the glide has no ease-in or ease-out of its own: the position
			// already comes from the simulation, which is where any easing belongs.
			#expect(CATransaction.animationTimingFunction() == CAMediaTimingFunction(name: .linear))
			#expect(CATransaction.disableActions() == false)
		}
	}

	@Test("The no-animation path suppresses implicit animations")
	func withoutAnimationDisablesActions() {
		FrameInterpolation.withoutAnimation {
			#expect(CATransaction.disableActions() == true)
		}
	}

	@Test("Both wrappers leave the transaction as they found it")
	func wrappersRestoreTheOuterTransaction() {
		CATransaction.begin()
		CATransaction.setAnimationDuration(2.5)
		FrameInterpolation.animate {}
		FrameInterpolation.withoutAnimation {}
		#expect(CATransaction.animationDuration() == 2.5)
		#expect(CATransaction.disableActions() == false)
		CATransaction.commit()
	}

	/// The pet's own position must stay out of this dictionary, or it would go back to
	/// being a 60 Hz staircase; every key that is in it must stay in it, or that
	/// property starts animating (a cross-fading sprite, or a mirror flip that
	/// flattens her as it passes through a zero scale).
	@Test("The pet animates its position and nothing else")
	func petLayerAnimatesOnlyPosition() {
		let actions = OverlayPetWindowController.petLayerActions
		#expect(actions["position"] == nil)
		for key in ["contents", "transform", "bounds", "hidden"] {
			#expect(actions[key] is NSNull)
		}
	}

	/// The bubble has to glide with her, or its tail leaves her head as she moves.
	@Test("The bubble animates its position too, but never its picture")
	func bubbleLayerAnimatesOnlyPosition() {
		let actions = OverlayPetWindowController.bubbleLayerActions
		#expect(actions["position"] == nil)
		for key in ["contents", "contentsScale", "bounds", "hidden"] {
			#expect(actions[key] is NSNull)
		}
	}
}
