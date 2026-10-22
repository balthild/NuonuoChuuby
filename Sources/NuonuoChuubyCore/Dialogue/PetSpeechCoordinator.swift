import AppKit

/// Speaks for the pet: picks a line, shows the head bubble, and plays a voice
/// clip. Either half can be turned off independently.
@MainActor
public final class PetSpeechCoordinator {
	private let voice: VoicePlaybackService
	private let bubble: OverlaySpeechBubbleController
	private var selector: PetDialogueSelector
	private let displaySpace: DisplaySpace

	public var showBubbles = true

	/// Event speech is frequent, so bubbles are throttled: important lines appear
	/// after a short gap, ambient chatter only occasionally.
	private var lastBubbleAt = Date.distantPast
	private static let minimumGap: Double = 2.5
	private static let ambientGap: Double = 20

	private var petFrame: PixelRect = .zero

	public init(
		voice: VoicePlaybackService,
		bubble: OverlaySpeechBubbleController,
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

	public func updatePetFrame(_ frame: PixelRect) {
		petFrame = frame
		guard bubble.isVisible, let placement = bubblePlacement(for: bubble.currentText) else { return }
		bubble.reposition(to: placement, displaySpace: displaySpace)
	}

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
		if showBubbles, canShowBubble(priority: priority) {
			let line = selector.choose(cue, itemName: itemName)
			if let placement = bubblePlacement(for: line) {
				bubble.show(line, placement: placement, displaySpace: displaySpace)
				lastBubbleAt = Date()
			}
		}
		return spoke
	}

	private func bubblePlacement(for text: String) -> SpeechBubblePlacement? {
		guard
			let display = displaySpace.display(
				containing: PixelPoint(x: petFrame.centerX, y: petFrame.centerY)
			)
		else { return nil }
		let body = bubble.bodySize(for: text)
		return SpeechBubbleLayout.place(
			petFrame: petFrame,
			contentWidth: body.width,
			contentHeight: body.height,
			tailHeight: bubble.tailHeight,
			area: SpeechBubbleLayout.area(for: display)
		)
	}

	private func canShowBubble(priority: VoicePriority) -> Bool {
		let gap = Date().timeIntervalSince(lastBubbleAt)
		return gap >= (priority >= .normal ? Self.minimumGap : Self.ambientGap)
	}

	public func hideBubble() {
		bubble.hide()
	}
}
