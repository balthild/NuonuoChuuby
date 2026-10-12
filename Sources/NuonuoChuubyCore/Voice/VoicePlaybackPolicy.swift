import Foundation

/// Decides which recording may play next, so a cue rotates instead of repeating
/// and no file comes back too soon.
public enum VoicePlaybackPolicy {
	public static let minimumFileRepeatInterval: Double = 12

	public static func isCoolingDown(now: Date, lastStartedAt: Date, cooldown: Double) -> Bool {
		cooldown > 0 && now.timeIntervalSince(lastStartedAt) < cooldown
	}

	public static func freshFiles(
		available: [String],
		lastFileStarted: [String: Date],
		now: Date,
		minimumRepeatInterval: Double = VoicePlaybackPolicy.minimumFileRepeatInterval
	) -> [String] {
		available.filter { fileName in
			guard let lastStarted = lastFileStarted[fileName] else { return true }
			return !isCoolingDown(now: now, lastStartedAt: lastStarted, cooldown: minimumRepeatInterval)
		}
	}

	/// Prefers a file that is neither the cue's previous pick nor the overall
	/// previous pick, falling back when that would leave nothing.
	public static func rotationCandidates(
		freshFiles: [String],
		previousFileForCue: String?,
		previousFileOverall: String?
	) -> [String] {
		guard freshFiles.count > 1 else { return freshFiles }

		var candidates = freshFiles.filter { $0.caseInsensitiveCompare(previousFileForCue ?? "") != .orderedSame }
		if candidates.isEmpty { candidates = freshFiles }

		if candidates.count > 1 {
			let withoutImmediateRepeat = candidates.filter {
				$0.caseInsensitiveCompare(previousFileOverall ?? "") != .orderedSame
			}
			if !withoutImmediateRepeat.isEmpty { candidates = withoutImmediateRepeat }
		}
		return candidates
	}
}
