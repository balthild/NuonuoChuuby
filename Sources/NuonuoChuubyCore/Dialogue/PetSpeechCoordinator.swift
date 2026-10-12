import AppKit

/// Speaks for the pet: picks a line, shows the head bubble, and plays a voice
/// clip. Either half can be turned off independently.
@MainActor
public final class PetSpeechCoordinator {
	private let voice: VoicePlaybackService
	private let bubble: SpeechBubbleWindowController
	private var selector: PetDialogueSelector
	private let displaySpace: DisplaySpace

	/// The bubble is a separate toggle from the voice; both default to on.
	public var showBubbles = true

	/// Event speech is frequent, so bubbles are throttled: an important line may
	/// appear after a short gap, ambient chatter only occasionally — otherwise a
	/// hopping pet would paper the screen in captions.
	private var lastBubbleAt = Date.distantPast
	private static let minimumGap: Double = 2.5
	private static let ambientGap: Double = 20

	/// The pet's current frame, used to place and keep the bubble attached.
	private var petFrame: PixelRect = .zero

	public init(
		voice: VoicePlaybackService,
		bubble: SpeechBubbleWindowController,
		displaySpace: DisplaySpace,
		character: PetCharacterProfile = .nuonuo
	) {
		self.voice = voice
		self.bubble = bubble
		self.displaySpace = displaySpace
		self.selector = PetDialogueSelector(character: character)
	}

	public var isVoiceEnabled: Bool {
		get { voice.isEnabled }
		set { voice.setEnabled(newValue) }
	}

	public var voiceVolume: Double {
		get { voice.volume }
		set { voice.setVolume(newValue) }
	}

	/// Called whenever the pet moves, so a visible bubble travels with it.
	public func updatePetFrame(_ frame: PixelRect) {
		petFrame = frame
		guard bubble.isVisible, let topLeft = bubbleTopLeft() else { return }
		bubble.reposition(to: topLeft, displaySpace: displaySpace)
	}

	/// Reacts with a line and a matching recording.
	@discardableResult
	public func react(
		_ cue: DialogueCue,
		voice voiceCue: VoiceCue? = nil,
		priority: VoicePriority = .normal,
		itemName: String? = nil
	) -> Bool {
		var spoke = false
		if let voiceCue {
			spoke = voice.play(voiceCue, priority: priority)
		}
		if showBubbles, canShowBubble(priority: priority), let topLeft = bubbleTopLeft() {
			let line = selector.choose(cue, itemName: itemName)
			bubble.show(line, topLeft: topLeft, displaySpace: displaySpace)
			lastBubbleAt = Date()
		}
		return spoke
	}

	private func bubbleTopLeft() -> PixelPoint? {
		guard
			let workArea = displaySpace.display(
				containing: PixelPoint(x: petFrame.centerX, y: petFrame.centerY)
			)?.visibleFrame
		else { return nil }
		let size = bubble.bubbleSize
		return SpeechBubbleLayout.topLeft(
			petFrame: petFrame,
			bubbleWidth: size.width,
			bubbleHeight: size.height,
			workArea: workArea
		)
	}

	private func canShowBubble(priority: VoicePriority) -> Bool {
		let gap = Date().timeIntervalSince(lastBubbleAt)
		// Ambient chatter is the pet thinking aloud; it should read as occasional.
		return gap >= (priority >= .normal ? Self.minimumGap : Self.ambientGap)
	}

	public func hideBubble() {
		bubble.hide()
	}
}
