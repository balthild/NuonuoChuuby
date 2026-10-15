import AppKit

/// What the app needs from whatever shows a fake icon in the place of a deleted
/// desktop item, so the pet visibly walks over and eats it.
///
/// Two implementations exist, one per pet renderer. `GhostIconWindow` moves a small
/// panel of its own (used by `--pet-panel`); `OverlayGhostIcon` draws the icon as a
/// layer of the pet's full-display overlay, so it costs no window server round trip.
@MainActor
public protocol GhostIconPresenting: AnyObject {
	/// Shows `icon` centred on `center` (global, top-left coordinates), `size`
	/// points across.
	///
	/// The real dimensions were resolved when the deletion was detected — the icon
	/// is gone by the time she sets off — so the ghost matches the icon it stands
	/// in for instead of being guessed from her own size.
	func show(icon: NSImage?, at center: PixelPoint, size: Double)
	/// Fades it out and takes it off screen for good.
	func fadeOut()
	/// Takes it off screen, keeping it for a later ``show(icon:at:size:)``.
	func hide()
}
