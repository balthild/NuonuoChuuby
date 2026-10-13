import Foundation
import Testing

@testable import NuonuoChuubyCore

/// Whether the window holding the pet has been covered by one in front of it.
///
/// Only windows **in front** count, which is what makes this relative: a window
/// behind the one holding her hides neither of them.
@Suite("Window occlusion")
struct WindowOcclusionTests {
	/// The pet's body, and the window holding her: a 600×400 window at 600,600
	/// with her body inside it.
	private let herBody = PixelRect(x: 800, y: 750, width: 120, height: 140)
	private let host = PixelRect(x: 600, y: 600, width: 600, height: 400)
	private let hostID: UInt32 = 100

	private func body(_ bounds: PixelRect, z: Int) -> WindowBody {
		WindowBody(bounds: bounds, zIndex: z)
	}

	private func isHidden(_ bodies: [UInt32: WindowBody]) -> Bool {
		WindowOcclusionPolicy.isHidden(herBody, attachedTo: hostID, among: bodies)
	}

	@Test("With nothing in front of it, she is not hidden")
	func nothingInFront() {
		#expect(!isHidden([hostID: body(host, z: 0)]))
	}

	@Test("A window in front that covers her hides her")
	func frontWindowCoversHer() {
		#expect(
			isHidden([
				hostID: body(host, z: 1),
				200: body(PixelRect(x: 0, y: 0, width: 1440, height: 900), z: 0),
			])
		)
	}

	@Test("A window in front that misses her does not hide her")
	func frontWindowMissesHer() {
		// Alongside her, not over her: this is the common case of a window opened
		// next to the one holding her.
		#expect(
			!isHidden([
				hostID: body(host, z: 1),
				200: body(PixelRect(x: 0, y: 0, width: 700, height: 900), z: 0),
			])
		)
	}

	@Test("A window BEHIND the one holding her hides neither of them")
	func windowBehindDoesNotHide() {
		// The whole point of the z-order travelling with the sample: a window
		// behind is not covering her, however much of the screen it takes up.
		#expect(
			!isHidden([
				hostID: body(host, z: 0),
				200: body(PixelRect(x: 0, y: 0, width: 1440, height: 900), z: 1),
			])
		)
	}

	@Test("A partial cover counts")
	func partialCoverCounts() {
		// The front window reaches only her upper half, and still the floor under
		// her is gone from view — which is what makes her look unsupported.
		let upperHalf = PixelRect(x: 600, y: 600, width: 600, height: 200)
		#expect(
			!upperHalf.contains(herBody),
			"the cover really is only partial"
		)
		// Her centre is at (860, 820), which the cover above does not reach.
		#expect(!isHidden([hostID: body(host, z: 1), 200: body(upperHalf, z: 0)]))

		// The same window 200 pt lower does reach her centre.
		let waist = PixelRect(x: 600, y: 800, width: 600, height: 200)
		#expect(isHidden([hostID: body(host, z: 1), 200: body(waist, z: 0)]))
	}

	@Test("A window that has stopped being a body hides nothing")
	func missingHostIsNotHidden() {
		// The window holding her has left the sample: the capacity check is what
		// deals with that, not this one.
		#expect(!isHidden([200: body(PixelRect(x: 0, y: 0, width: 1440, height: 900), z: 0)]))
	}
}
