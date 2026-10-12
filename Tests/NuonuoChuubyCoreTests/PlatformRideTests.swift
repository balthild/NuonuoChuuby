import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The only ride physics left: the grace that keeps her attached while a dragged
/// window briefly vanishes from the window server's list.
@Suite("Transient platform support")
struct TransientPlatformSupportTests {
	@Test("Support is held briefly while a window is being dragged")
	func graceWindow() {
		#expect(PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 0))
		#expect(PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 0.3))
		#expect(PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 0.35))
		#expect(!PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 0.36))
	}

	@Test("Nonsense input does not hold her up forever")
	func invalidInput() {
		#expect(!PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: .nan))
		#expect(!PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: -1))
		#expect(!PlatformRidePhysics.shouldPreserveTransientSupport(unavailableSeconds: 10))
	}
}
