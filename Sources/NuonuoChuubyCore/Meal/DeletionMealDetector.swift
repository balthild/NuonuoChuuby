import Foundation

/// Turns raw filesystem observations into confirmed meals: a name disappears from
/// a watched folder, and a matching arrival in `~/.Trash` corroborates it.
public struct DeletionMealDetector: Sendable {
	public struct Pending: Sendable, Equatable {
		public var name: String
		public var path: String
		public var detectedAt: Date
		public var anchor: PixelPoint
		public var exactAnchor: Bool
	}

	/// How long to wait for a Trash arrival before accepting the deletion anyway.
	public var confirmTimeout: Double = 2.5
	/// How long a Trash arrival stays available to corroborate a removal.
	public var corroborationWindow: Double = 8

	private var pending: [Pending] = []
	private var trashArrivals: [String: Date] = [:]

	public init() {}

	public var pendingCount: Int { pending.count }

	public mutating func noteRemoval(_ item: Pending) {
		pending.append(item)
	}

	public mutating func noteTrashArrival(name: String, at: Date) {
		trashArrivals[DeletionMealDetector.normalizedTrashName(name)] = at
	}

	/// Removals that are either corroborated or have waited long enough.
	public mutating func collectReady(now: Date) -> [(item: Pending, cameFromTrash: Bool)] {
		trashArrivals = trashArrivals.filter { now.timeIntervalSince($0.value) <= corroborationWindow }

		var ready: [(item: Pending, cameFromTrash: Bool)] = []
		var remaining: [Pending] = []

		for item in pending {
			let key = DeletionMealDetector.normalizedTrashName(item.name)
			if let arrival = trashArrivals[key] {
				// The Trash entry can lag the removal slightly, but never lead it
				// by much — a same-named file trashed earlier is not this deletion.
				if arrival >= item.detectedAt.addingTimeInterval(-corroborationWindow) {
					ready.append((item, true))
					continue
				}
			}
			if now.timeIntervalSince(item.detectedAt) >= confirmTimeout {
				ready.append((item, false))
				continue
			}
			remaining.append(item)
		}

		pending = remaining
		return ready
	}

	/// macOS appends " N" before a duplicate's extension, so `a.txt` trashed twice
	/// becomes `a.txt` then `a 2.txt`. Both normalise to `a.txt`.
	static func normalizedTrashName(_ name: String) -> String {
		let url = URL(fileURLWithPath: name)
		let ext = url.pathExtension
		var base = url.deletingPathExtension().lastPathComponent
		if ext.isEmpty {
			base = name
		}
		let parts = base.split(separator: " ")
		if parts.count >= 2, let suffix = parts.last, Int(suffix) != nil, parts.count > 1 {
			base = parts.dropLast().joined(separator: " ")
		}
		return ext.isEmpty ? base : "\(base).\(ext)"
	}
}
