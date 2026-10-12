import AVFoundation

/// Plays the character's recordings with the original's rotation rules: a cue
/// cannot retrigger immediately, no file returns within twelve seconds, and a
/// higher-priority line may interrupt a lower one.
@MainActor
public final class VoicePlaybackService: NSObject, AVAudioPlayerDelegate {
	private static let defaultCueCooldown: Double = 1.8

	private let locator: AssetLocator
	private let character: PetCharacterProfile
	private let loudness: VoiceLoudness

	private var player: AVAudioPlayer?
	private var lastCueStarted: [String: Date] = [:]
	private var lastFileByCue: [String: String] = [:]
	private var lastFileStarted: [String: Date] = [:]
	private var lastStartedAt = Date.distantPast
	private var currentPriority: VoicePriority = .ambient
	private var lastFileName: String?
	private var currentFileName: String?

	public var isEnabled: Bool
	public var volume: Double

	public init(
		locator: AssetLocator,
		character: PetCharacterProfile,
		loudness: VoiceLoudness,
		enabled: Bool = true,
		volume: Double = 0.72
	) {
		self.locator = locator
		self.character = character
		self.loudness = loudness
		self.isEnabled = enabled && character.hasVoice
		self.volume = min(max(volume, 0), 1)
		super.init()
	}

	public var isPlaying: Bool { player?.isPlaying ?? false }

	@discardableResult
	public func play(
		_ cue: VoiceCue,
		priority: VoicePriority = .normal,
		cueCooldown: Double? = nil,
		minimumIntervalSinceAnyVoice: Double? = nil
	) -> Bool {
		playFiles(
			cue: cue.rawValue,
			requestedFiles: VoiceCueCatalog.fileNames(for: cue, character: character),
			priority: priority,
			cueCooldown: cueCooldown,
			minimumIntervalSinceAnyVoice: minimumIntervalSinceAnyVoice
		)
	}

	private func playFiles(
		cue: String,
		requestedFiles: [String],
		priority: VoicePriority,
		cueCooldown: Double?,
		minimumIntervalSinceAnyVoice: Double?
	) -> Bool {
		guard isEnabled, !requestedFiles.isEmpty else { return false }

		let now = Date()
		let cooldown = cueCooldown ?? Self.defaultCueCooldown

		if let interval = minimumIntervalSinceAnyVoice,
			VoicePlaybackPolicy.isCoolingDown(now: now, lastStartedAt: lastStartedAt, cooldown: interval)
		{
			return false
		}
		if let lastCue = lastCueStarted[cue],
			VoicePlaybackPolicy.isCoolingDown(now: now, lastStartedAt: lastCue, cooldown: cooldown)
		{
			return false
		}
		if let player, player.isPlaying {
			let canInterrupt =
				priority == .critical || priority > currentPriority
				|| (priority == currentPriority && priority >= .important)
			guard canInterrupt else { return false }
			player.stop()
		}

		let fresh = VoicePlaybackPolicy.freshFiles(
			available: requestedFiles,
			lastFileStarted: lastFileStarted,
			now: now
		)
		let pool = fresh.isEmpty ? requestedFiles.filter { $0 != currentFileName } : fresh
		let playable = pool.isEmpty ? requestedFiles : pool
		guard
			let chosen = VoicePlaybackPolicy.rotationCandidates(
				freshFiles: playable,
				previousFileForCue: lastFileByCue[cue],
				previousFileOverall: lastFileName
			).randomElement() ?? playable.first
		else { return false }

		return start(fileName: chosen, cue: cue, priority: priority, now: now)
	}

	private func start(fileName: String, cue: String, priority: VoicePriority, now: Date) -> Bool {
		let url = locator.voiceURL(character: character, fileName: fileName)
		guard let created = try? AVAudioPlayer(contentsOf: url) else {
			DiagnosticsLog.shared.write("voice file unavailable")
			return false
		}

		created.delegate = self
		created.volume = Float(
			loudness.volume(character: character.id, file: fileName, requested: volume)
		)
		guard created.prepareToPlay(), created.play() else { return false }

		player = created
		currentFileName = fileName
		lastFileName = fileName
		currentPriority = priority
		lastStartedAt = now
		lastCueStarted[cue] = now
		lastFileByCue[cue] = fileName
		lastFileStarted[fileName] = now
		return true
	}

	public func stop() {
		player?.stop()
		player = nil
	}

	public func setEnabled(_ enabled: Bool) {
		isEnabled = enabled && character.hasVoice
		if !isEnabled { stop() }
	}

	public func setVolume(_ newVolume: Double) {
		volume = min(max(newVolume, 0), 1)
		if let currentFileName {
			player?.volume = Float(
				loudness.volume(character: character.id, file: currentFileName, requested: volume)
			)
		}
	}

	nonisolated public func audioPlayerDidFinishPlaying(
		_ player: AVAudioPlayer,
		successfully flag: Bool
	) {
		// AVAudioPlayer is not Sendable, so pass only its identity across the
		// isolation boundary and re-check against the current player there.
		let identifier = ObjectIdentifier(player)
		MainActor.assumeIsolated {
			if let current = self.player, ObjectIdentifier(current) == identifier {
				self.player = nil
			}
		}
	}
}
