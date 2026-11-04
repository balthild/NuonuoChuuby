import Foundation
import PetFoundation

/// The four long-term needs that drive 糯糯's autonomy. All are 0…100.
///
/// Every field carries `@Fallback` for the reason ``PetSettings`` does: `PetLifeStateStore
/// .load()` answers a decode that throws with a wholly fresh state, so one unreadable key
/// would otherwise cost the entire save — how many meals she has eaten included. A new
/// field takes a wrapper and an entry in ``PetLifeStateDefault``, and nothing else changes.
public struct PetLifeState: Sendable, Equatable, Codable {
	public static let version = 1

	@Fallback<PetLifeStateDefault.Version> public var version: Int
	@Fallback<PetLifeStateDefault.Hunger> public var hunger: Double
	@Fallback<PetLifeStateDefault.Fullness> public var fullness: Double
	@Fallback<PetLifeStateDefault.Sleepiness> public var sleepiness: Double
	@Fallback<PetLifeStateDefault.Curiosity> public var curiosity: Double
	@Fallback<PetLifeStateDefault.TotalMeals> public var totalMeals: Int
	@Fallback<PetLifeStateDefault.FavoriteFoodType> public var favoriteFoodType: String
	/// Keys are lowercased so lookups behave case-insensitively.
	@Fallback<PetLifeStateDefault.FoodTypeCounts> public var foodTypeCounts: [String: Int]
	@Fallback<PetLifeStateDefault.LastUpdated> public var lastUpdatedUtc: Date

	public init() {}

	/// Offline time is clamped so a long absence cannot drain every need at once.
	public mutating func advance(elapsedSeconds: Double, sleeping: Bool) {
		let minutes = min(max(elapsedSeconds / 60, 0), 12 * 60)
		guard minutes > 0 else { return }

		if sleeping {
			hunger += 0.12 * minutes
			fullness -= 0.20 * minutes
			sleepiness -= 36 * minutes
			curiosity += 0.08 * minutes
		} else {
			hunger += 0.18 * minutes
			fullness -= 0.32 * minutes
			sleepiness += 0.13 * minutes
			curiosity += 0.22 * minutes
		}
		clampNeeds()
	}

	public mutating func registerMeal(path: String, nourishment: Double) {
		let value = min(max(nourishment, 2), 24)
		hunger -= value * 0.92
		fullness += value
		sleepiness += value * 0.055
		curiosity -= min(3, value * 0.12)
		totalMeals += 1

		let foodType = PetLifeState.foodType(forPath: path)
		let key = foodType.lowercased()
		foodTypeCounts[key, default: 0] += 1
		favoriteFoodType =
			foodTypeCounts
			.sorted { lhs, rhs in
				if lhs.value != rhs.value { return lhs.value > rhs.value }
				return lhs.key < rhs.key
			}
			.first?.key ?? ""
		clampNeeds()
	}

	public mutating func registerExploration(amount: Double = 18) {
		curiosity -= min(max(amount, 2), 30)
		hunger += 0.8
		clampNeeds()
	}

	public mutating func clampNeeds() {
		hunger = PetLifeState.clampNeed(hunger, fallback: 36)
		fullness = PetLifeState.clampNeed(fullness, fallback: 24)
		sleepiness = PetLifeState.clampNeed(sleepiness, fallback: 20)
		curiosity = PetLifeState.clampNeed(curiosity, fallback: 48)
	}

	private static func clampNeed(_ value: Double, fallback: Double) -> Double {
		value.isFinite ? min(max(value, 0), 100) : fallback
	}

	static func foodType(forPath path: String) -> String {
		if path.lowercased().hasSuffix(".snack") {
			return "点心"
		}
		let ext = (path as NSString).pathExtension.lowercased()
		return ext.isEmpty ? "文件夹" : ext
	}
}

/// The value each ``PetLifeState`` field takes when the saved file has no usable one.
///
/// They follow the field list above in the same order. The defaults for a fresh pet are the
/// ones the original shipped; they are repeated in ``PetLifeState/clampNeeds()``, which is
/// what a *stored* value out of range is pulled back to.
public enum PetLifeStateDefault {
	public enum Version: FallbackProvider {
		public static let fallbackValue = PetLifeState.version
	}

	public enum Hunger: FallbackProvider { public static let fallbackValue: Double = 36 }
	public enum Fullness: FallbackProvider { public static let fallbackValue: Double = 24 }
	public enum Sleepiness: FallbackProvider { public static let fallbackValue: Double = 20 }
	public enum Curiosity: FallbackProvider { public static let fallbackValue: Double = 48 }
	public enum TotalMeals: FallbackProvider { public static let fallbackValue = 0 }
	public enum FavoriteFoodType: FallbackProvider {
		public static let fallbackValue: String = ""
	}
	public enum FoodTypeCounts: FallbackProvider {
		public static let fallbackValue: [String: Int] = [:]
	}
	/// Now, rather than a fixed instant: `load()` reads this as the moment the pet was last
	/// seen, so a file that does not date itself must be taken as dated at startup. A fixed
	/// past instant would instead be read as an absence and drain every need by the maximum
	/// twelve hours.
	public enum LastUpdated: FallbackProvider {
		public static var fallbackValue: Date { Date() }
	}
}

/// Reads and writes the life state atomically, forgiving a corrupt file.
public struct PetLifeStateStore: Sendable {
	public let stateDirectory: URL
	public var statePath: URL { stateDirectory.appendingPathComponent("life-state.json") }

	private let now: @Sendable () -> Date

	public init(stateDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
		self.stateDirectory = stateDirectory
		self.now = now
	}

	public func load() -> PetLifeState {
		let timestamp = now()
		if let data = try? Data(contentsOf: statePath) {
			let decoder = JSONDecoder()
			decoder.dateDecodingStrategy = .iso8601
			if var state = try? decoder.decode(PetLifeState.self, from: data) {
				let offline = timestamp.timeIntervalSince(state.lastUpdatedUtc)
				state.advance(elapsedSeconds: offline, sleeping: false)
				state.lastUpdatedUtc = timestamp
				state.clampNeeds()
				return state
			}
		}
		var fresh = PetLifeState()
		fresh.lastUpdatedUtc = timestamp
		return fresh
	}

	/// Writes the state to disk atomically, clamping the needs first. Throws if the
	/// directory or file cannot be written.
	public func save(_ state: PetLifeState) throws {
		var snapshot = state
		snapshot.clampNeeds()
		let savedAt = now()

		try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
		let temporary = stateDirectory.appendingPathComponent(
			".life-state.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
		)

		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

		let previous = snapshot.lastUpdatedUtc
		snapshot.lastUpdatedUtc = savedAt
		let data = try encoder.encode(snapshot)
		snapshot.lastUpdatedUtc = previous

		try data.write(to: temporary)
		if FileManager.default.fileExists(atPath: statePath.path) {
			_ = try FileManager.default.replaceItemAt(statePath, withItemAt: temporary)
		} else {
			try FileManager.default.moveItem(at: temporary, to: statePath)
		}
	}
}
