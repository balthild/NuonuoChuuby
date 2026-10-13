import Foundation

/// Whether the pet is hidden behind a window that is in front of the one holding
/// her.
///
/// A desktop pet is an always-on-top overlay, so it cannot be composited between
/// two ordinary windows — the window server only offers level-0 windows, and all
/// of them are at level 0. The trade the app makes instead is: **a support that
/// has been covered is not a support**, the same rule the pet already follows on
/// a window edge (see ``PetController/isPerchSpotVisible(_:)``). This type answers
/// the question that rule needs.
public enum WindowOcclusionPolicy {
	/// Whether any eligible window in front of `owner` covers `rect`.
	///
	/// Asked of her **body's centre**, which matches the way a covered ledge is
	/// judged (a single point) and therefore catches a partial cover, which is
	/// enough to leave her looking unsupported.
	///
	/// Returns false when `owner` itself is not in the sample: a window that has
	/// stopped being a body is not one she is being hidden behind, and the
	/// capacity check is what drops her for that.
	public static func isHidden(
		_ rect: PixelRect,
		attachedTo owner: UInt32,
		among bodies: [UInt32: WindowBody]
	) -> Bool {
		guard let host = bodies[owner] else { return false }
		let centre = PixelPoint(x: rect.centerX, y: rect.centerY)
		return bodies.contains { id, body in
			guard id != owner else { return false }
			return body.zIndex < host.zIndex && body.bounds.contains(centre)
		}
	}
}
