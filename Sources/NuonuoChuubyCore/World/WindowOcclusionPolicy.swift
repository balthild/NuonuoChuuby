import Foundation

/// Which window is hiding the pet from view.
///
/// A desktop pet is an always-on-top overlay, so it cannot be composited between
/// two ordinary windows — the window server only offers level-0 windows, and all
/// of them are at level 0. What the app does instead is treat a covered support
/// as no support, the same rule the pet already follows on a window edge (see
/// ``PetController/isPerchSpotVisible(_:)``). This type answers the question that
/// rule needs.
public enum WindowOcclusionPolicy {
	/// The frontmost window covering her, or nil when nothing in front of the
	/// window holding her covers it.
	///
	/// Asked of her **body's centre**, which matches the way a covered ledge is
	/// judged (a single point) and therefore catches a partial cover — enough to
	/// leave her looking unsupported.
	///
	/// **Frontmost is not arbitrary.** Whatever holds her next must not itself be
	/// covered, or she would be moved straight back out of it on the following
	/// grace period. The frontmost window covering her cannot be covered by
	/// anything that also covers her, because that window would be more frontmost
	/// still — so this is the one choice that cannot oscillate.
	///
	/// Returns nil when `owner` is not in the sample at all: a window that has
	/// stopped being a body is not one she is being hidden behind, and the
	/// capacity check is what drops her for that.
	public static func coveringWindow(
		of owner: UInt32,
		her body: PixelRect,
		among bodies: [UInt32: WindowBody]
	) -> UInt32? {
		guard let host = bodies[owner] else { return nil }
		let centre = PixelPoint(x: body.centerX, y: body.centerY)
		var frontmost: (id: UInt32, zIndex: Int)?
		for (id, candidate) in bodies {
			guard id != owner, candidate.zIndex < host.zIndex,
				candidate.bounds.contains(centre)
			else { continue }
			if frontmost == nil || candidate.zIndex < frontmost!.zIndex {
				frontmost = (id, candidate.zIndex)
			}
		}
		return frontmost?.id
	}
}
