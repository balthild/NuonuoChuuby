import Foundation

/// A file the pet saw disappear from a watched folder.
public struct DeletedItem: Sendable, Equatable, Identifiable {
	public var id: Int
	public var originalPath: String
	public var displayName: String
	public var detectedAt: Date
	/// Where the icon was on screen, in global top-left coordinates.
	public var anchor: PixelPoint
	/// Whether the anchor is the icon's real position (from a click) or a guess.
	public var exactAnchor: Bool
	/// The icon's on-screen size in points, when it is known; the ghost icon is
	/// drawn this big, so it matches the real desktop icon.
	public var iconSize: Double?

	public init(
		id: Int,
		originalPath: String,
		displayName: String,
		detectedAt: Date,
		anchor: PixelPoint,
		exactAnchor: Bool,
		iconSize: Double? = nil
	) {
		self.id = id
		self.originalPath = originalPath
		self.displayName = displayName
		self.detectedAt = detectedAt
		self.anchor = anchor
		self.exactAnchor = exactAnchor
		self.iconSize = iconSize
	}
}

public enum MealQueuePolicy {
	public static let maximumBufferedDeletions = 24

	public static func canAcceptDeletion(queuedCount: Int, hasActiveDeletionMeal: Bool) -> Bool {
		let buffered = max(0, queuedCount) + (hasActiveDeletionMeal ? 1 : 0)
		return buffered < maximumBufferedDeletions
	}
}

/// A bounded FIFO of pending meals.
public struct MealQueue: Sendable {
	private var items: [DeletedItem] = []

	public init() {}

	public var count: Int { items.count }
	public var isEmpty: Bool { items.isEmpty }
	public var first: DeletedItem? { items.first }

	public mutating func enqueue(_ item: DeletedItem) {
		guard items.count < MealQueuePolicy.maximumBufferedDeletions else { return }
		items.append(item)
	}

	public mutating func requeueAtFront(_ item: DeletedItem) {
		items.insert(item, at: 0)
	}

	public mutating func dequeue() -> DeletedItem? {
		items.isEmpty ? nil : items.removeFirst()
	}

	public mutating func removeAll() {
		items.removeAll()
	}
}

/// Chooses which desktop icon the pet walks over to lick.
public enum IconLickTargetSelector {
	public static func choose(
		candidates: [PixelPoint],
		origin: PixelPoint,
		randomUnit: Double,
		preferredMinimumDistance: Double = 72,
		nearestPoolSize: Int = 12
	) -> PixelPoint? {
		guard !candidates.isEmpty else { return nil }

		var seen = Set<PixelPoint>()
		let ordered =
			candidates
			.filter { seen.insert($0).inserted }
			.map { (point: $0, distanceSquared: $0.squaredDistance(to: origin)) }
			.sorted { $0.distanceSquared < $1.distanceSquared }

		let preferredThreshold = preferredMinimumDistance * preferredMinimumDistance
		let poolSize = max(1, nearestPoolSize)
		let preferred = ordered.filter { $0.distanceSquared >= preferredThreshold }.prefix(poolSize)
		let pool = preferred.isEmpty ? Array(ordered.prefix(poolSize)) : Array(preferred)
		guard !pool.isEmpty else { return nil }

		return pool[RandomSelection.index(in: pool.count, unit: randomUnit)].point
	}
}

/// Picks a free spot for the ghost icon when the real position is unknown.
public enum GhostAnchorLayout {
	static let offsets: [PixelPoint] = [
		PixelPoint(x: 0, y: 0), PixelPoint(x: 84, y: 0), PixelPoint(x: -84, y: 0),
		PixelPoint(x: 0, y: 94), PixelPoint(x: 0, y: -94),
		PixelPoint(x: 84, y: 94), PixelPoint(x: -84, y: 94),
		PixelPoint(x: 84, y: -94), PixelPoint(x: -84, y: -94),
		PixelPoint(x: 168, y: 0), PixelPoint(x: -168, y: 0),
		PixelPoint(x: 0, y: 188), PixelPoint(x: 0, y: -188),
	]

	public static func chooseDistinct(
		preferred: PixelPoint,
		occupied: [PixelPoint],
		minimumDistance: Double = 56
	) -> PixelPoint {
		let threshold = minimumDistance * minimumDistance
		for offset in offsets {
			let candidate = PixelPoint(x: preferred.x + offset.x, y: preferred.y + offset.y)
			if occupied.allSatisfy({ $0.squaredDistance(to: candidate) >= threshold }) {
				return candidate
			}
		}
		let index = Double(occupied.count + 1)
		return PixelPoint(x: preferred.x + index * 24, y: preferred.y + index * 18)
	}
}

/// Detects a burst of deletions.
public struct DeletionBurstTracker: Sendable {
	private var recent: [Date] = []

	public init() {}

	public var count: Int { recent.count }

	public mutating func register(detectedAt: Date, window: Double = 6) -> Bool {
		recent.removeAll { detectedAt.timeIntervalSince($0) > window }
		recent.append(detectedAt)
		return recent.count >= 2
	}
}
