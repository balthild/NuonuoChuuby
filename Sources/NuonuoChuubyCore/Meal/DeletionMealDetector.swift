import Foundation

/// Turns a filesystem observation into a meal: a name disappears from a watched
/// folder and stays gone for a short settling window.
///
/// There is deliberately no Trash corroboration. `rm`, and any other tool that
/// unlinks a file directly, never puts anything in the Trash — so "nothing
/// arrived in the Trash" cannot tell a deletion from a move and proves nothing.
public struct DeletionMealDetector: Sendable {
	public struct Pending: Sendable, Equatable {
		public var name: String
		public var path: String
		public var detectedAt: Date
		public var anchor: PixelPoint
		public var exactAnchor: Bool
		/// The icon's on-screen size in points, when the index knew it.
		public var iconSize: Double?
	}

	/// How long a removal must stand before it is accepted. It only has to
	/// outlast the transient notifications a single deletion can produce.
	public var settleDelay: Double = 0.5
	/// Removals of the same path closer together than this are one deletion. A
	/// single Finder deletion is sometimes reported twice — a rename, then a
	/// rename+create a fraction of a second later.
	public var duplicateWindow: Double = 2.0

	private var pending: [Pending] = []
	private var recentPaths: [String: Date] = [:]

	public init() {}

	public var pendingCount: Int { pending.count }

	public mutating func noteRemoval(_ item: Pending) {
		// Prune against this event, which is the newest one seen.
		recentPaths = recentPaths.filter {
			item.detectedAt.timeIntervalSince($0.value) <= duplicateWindow
		}
		guard recentPaths[item.path] == nil else { return }
		recentPaths[item.path] = item.detectedAt
		pending.append(item)
	}

	/// Removals that have settled.
	public mutating func collectReady(now: Date) -> [Pending] {
		var ready: [Pending] = []
		var remaining: [Pending] = []
		for item in pending {
			if now.timeIntervalSince(item.detectedAt) >= settleDelay {
				ready.append(item)
			} else {
				remaining.append(item)
			}
		}
		pending = remaining
		return ready
	}
}
