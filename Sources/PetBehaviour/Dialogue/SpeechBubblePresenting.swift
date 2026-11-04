import AppKit
import PetDesktop

/// How long a bubble stays up, and the tail's height — both part of the bubble's
/// contract rather than of any one way of drawing it, so the overlay and the panel
/// renderers cannot drift apart on them.
public enum SpeechBubbleTiming {
	/// How long a bubble stays up unless the caller says otherwise.
	public static let defaultDuration: Double = 3.2
}

/// What `PetSpeechCoordinator` needs from whatever draws the head bubble.
///
/// Two things implement it: ``OverlaySpeechBubbleController``, which puts the bubble in
/// a layer of the full-display window, and the panel renderer's window bubble. The
/// coordinator speaks the same either way, so a renderer swap changes nothing about
/// when or what she says.
@MainActor
public protocol SpeechBubblePresenting: AnyObject {
	var isVisible: Bool { get }
	var currentText: String { get }

	/// The tail's height, which the layout needs before it can place the bubble.
	var tailHeight: Double { get }

	/// The bubble's size **without** its tail, for the layout to place it by.
	func bodySize(for text: String) -> (width: Double, height: Double)

	func show(_ text: String, placement: SpeechBubblePlacement, displaySpace: DisplaySpace)
	func reposition(to placement: SpeechBubblePlacement, displaySpace: DisplaySpace)
	func hide()
}
