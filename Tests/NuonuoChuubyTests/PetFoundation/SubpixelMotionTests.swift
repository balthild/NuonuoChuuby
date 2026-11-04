import Testing

@testable import PetFoundation

@Suite("Subpixel motion")
struct SubpixelMotionTests {
	@Test("Fractional movement accumulates until it crosses a pixel")
	func carriesRemainder() {
		var remainder = 0.0
		#expect(SubpixelMotion.takeWholePixels(0.4, remainder: &remainder) == 0)
		#expect(SubpixelMotion.takeWholePixels(0.4, remainder: &remainder) == 0)
		#expect(SubpixelMotion.takeWholePixels(0.4, remainder: &remainder) == 1)
		#expect(abs(remainder - 0.2) < 0.0001)
	}

	@Test("Negative movement truncates toward zero")
	func negativeMovement() {
		var remainder = 0.0
		#expect(SubpixelMotion.takeWholePixels(-2.7, remainder: &remainder) == -2)
		#expect(abs(remainder + 0.7) < 0.0001)
	}
}
