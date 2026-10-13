import Foundation

/// A window as the physics needs it: where it is, and how far forward it sits.
///
/// The z-order is what makes occlusion a **relative** question — a window behind
/// the one holding the pet hides neither of them.
public struct WindowBody: Sendable, Equatable {
	public var bounds: PixelRect
	/// `CGWindowListCopyWindowInfo` order: 0 is frontmost.
	public var zIndex: Int

	public init(bounds: PixelRect, zIndex: Int) {
		self.bounds = bounds
		self.zIndex = zIndex
	}
}
