import AppKit
import Foundation
import PetFoundation
import QuartzCore

/// What the app shell needs from a fake icon standing in for a file being eaten.
///
/// Two things implement it: ``OverlayGhostIcon``, a layer of the full-display window,
/// and the panel renderer's window ghost. The meal logic drives either the same way.
@MainActor
public protocol GhostIconPresenting: AnyObject {
	/// Set once the icon has been dismissed, so the presenter that owns it can drop it
	/// from its list.
	var isDismissed: Bool { get }

	/// Re-attaches after the window it was drawn into was rebuilt. A no-op for a
	/// renderer whose windows outlive a display change.
	func rebind()

	func show(icon: NSImage?, at center: PixelPoint, size: Double)
	func update(_ visual: MealConsumptionVisual)
	func fadeOut()
	func hide()
}

/// Timing and geometry the ghost icon's renderers share.
public enum GhostIconStyle {
	/// How long the fade-out takes. Only ``GhostIconPresenting/fadeOut()`` is animated;
	/// the shiver is applied frame by frame.
	public static let fadeDuration: CFTimeInterval = 0.25

	/// The original's own transform order: scale first, then turn.
	public static func animationTransform(_ visual: MealConsumptionVisual) -> CATransform3D {
		let scale = CATransform3DMakeScale(CGFloat(visual.scaleX), CGFloat(visual.scaleY), 1)
		guard visual.rotationDegrees != 0 else { return scale }
		let rotate = CATransform3DMakeRotation(
			CGFloat(visual.rotationDegrees) * .pi / 180,
			0,
			0,
			1
		)
		return CATransform3DConcat(rotate, scale)
	}
}
