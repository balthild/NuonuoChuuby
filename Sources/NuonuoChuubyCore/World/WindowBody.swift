import Foundation

/// A window as the physics needs it: where it is, how far forward it sits, and
/// whether it could hold the pet.
///
/// The z-order is what makes occlusion a **relative** question — a window behind
/// the one holding the pet hides neither of them.
public struct WindowBody: Sendable, Equatable {
	public var bounds: PixelRect
	/// `CGWindowListCopyWindowInfo` order: 0 is frontmost.
	public var zIndex: Int
	/// Whether this window could be a container for her.
	///
	/// A body is sampled on three unrelated questions — does it hide her, could she
	/// be put inside it, is its edge sweeping at her — and only two of those care
	/// that it has room for her. A window filling the display has none (she would be
	/// sealed against the screen), but it very much hides her, so the answer travels
	/// with the window rather than being decided per question.
	public var isEnclosureCandidate: Bool

	public init(bounds: PixelRect, zIndex: Int, isEnclosureCandidate: Bool = false) {
		self.bounds = bounds
		self.zIndex = zIndex
		self.isEnclosureCandidate = isEnclosureCandidate
	}
}

extension Dictionary where Key == UInt32, Value == WindowBody {
	/// The bodies that could hold her: the ones a container or a side impact may use.
	///
	/// Occlusion deliberately reads the whole dictionary instead, since a window too
	/// large to hold her still stands in front of her.
	public var enclosureCandidates: [UInt32: WindowBody] {
		filter { $0.value.isEnclosureCandidate }
	}
}
