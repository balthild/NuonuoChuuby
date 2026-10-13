import AppKit

/// What the speech coordinator needs from whatever puts the head bubble on screen.
///
/// Two implementations exist. `SpeechBubbleWindowController` moves a small panel,
/// and is what `--pet-panel` uses along with the moving-panel pet.
/// `OverlaySpeechBubbleController` draws the bubble as a layer inside the pet's
/// full-display overlay, so following her costs no window server round trip.
@MainActor
public protocol SpeechBubblePresenting: AnyObject {
	var isVisible: Bool { get }
	var currentText: String { get }

	/// The body size the bubble needs for `text`, so the layout can pick a spot
	/// before the bubble exists.
	func bodySize(for text: String) -> (width: Double, height: Double)
	/// How far the tail sticks out of the body, which the layout also needs.
	var tailHeight: Double { get }

	/// Shows the bubble at `placement` (global top-left coordinates) and hides it
	/// after `duration`.
	func show(
		_ text: String,
		placement: SpeechBubblePlacement,
		displaySpace: DisplaySpace,
		duration: Double
	)

	func reposition(to placement: SpeechBubblePlacement, displaySpace: DisplaySpace)

	func hide()
}

extension SpeechBubblePresenting {
	public static var defaultDuration: Double { 3.2 }

	public func show(_ text: String, placement: SpeechBubblePlacement, displaySpace: DisplaySpace) {
		show(text, placement: placement, displaySpace: displaySpace, duration: Self.defaultDuration)
	}
}
