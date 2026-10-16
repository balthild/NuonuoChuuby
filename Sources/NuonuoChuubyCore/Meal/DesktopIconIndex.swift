import AppKit
import ApplicationServices

/// An icon on the desktop, as Finder reports it.
public struct DesktopIcon: Sendable, Equatable {
	public var name: String
	/// The icon's centre, top-left origin, Y down — the same space as
	/// ``DisplaySpace``, so no conversion is needed.
	public var position: PixelPoint
	/// The icon's on-screen size in points, as Finder draws it. It follows the
	/// user's desktop icon-size setting, so a ghost drawn over a deleted icon
	/// matches the real one rather than a fixed default.
	public var size: Double

	public init(name: String, position: PixelPoint, size: Double) {
		self.name = name
		self.position = position
		self.size = size
	}
}

/// What one attempt at reading Finder's desktop icons produced.
///
/// The failure cases are named rather than collapsed into an empty reading: from
/// the outside they all look like "she does not know where the icons are", and
/// telling them apart is the whole question when a ghost lands in the wrong
/// place.
public enum IconReading: Sendable, Equatable {
	case icons([DesktopIcon])
	case unavailable(Failure)

	public enum Failure: String, Sendable {
		/// Accessibility is not granted for this process.
		case accessibilityNotTrusted
		/// Finder itself is not running.
		case finderNotRunning
		/// Finder is there but no element in its tree has icon children — the walk
		/// gave up before its depth limit.
		case noIconContainer
	}

	public var icons: [DesktopIcon]? {
		if case .icons(let icons) = self { return icons }
		return nil
	}
}

/// Reads Finder's **real** desktop icon positions through Accessibility.
///
/// The icon's accessibility element disappears shortly after it is deleted, so
/// this is a periodic index (name → position) that a deletion event looks up —
/// plus one live read at the moment of detection, while the element is still
/// there.
///
/// Accessibility is a **soft** dependency: without it (or with Finder not running)
/// `icons` is empty and callers fall back to ``DesktopIconGrid``.
@MainActor
public final class DesktopIconIndex {
	/// Supplies the icons; reports why when it cannot read at all.
	public typealias Reader = () -> IconReading

	private let reader: Reader
	private var timer: Timer?

	public private(set) var icons: [String: DesktopIcon] = [:]
	/// The last outcome written to the diagnostics log, so only a change is logged.
	/// The whole outcome, not just the count: "no accessibility" and "an empty
	/// desktop" are both zero icons and must not read the same.
	private var lastLoggedReading: OutcomeKey?
	/// When the snapshot was last replaced by a reading that succeeded, so a
	/// fallback can say how stale it is.
	private var lastSnapshotAt: Date?

	public init(reader: @escaping Reader = DesktopIconIndex.readDesktopIcons) {
		self.reader = reader
	}

	public var isAvailable: Bool { !icons.isEmpty }

	/// The icons in a stable order, so a random pick is reproducible.
	public var positions: [PixelPoint] {
		icons.values
			.sorted { ($0.position.y, $0.position.x) < ($1.position.y, $1.position.x) }
			.map(\.position)
	}

	public func icon(of name: String) -> DesktopIcon? { icons[name] }

	/// The icons behind these names, at the moment deletions are detected.
	///
	/// Every name is resolved from one read, because one enumeration is real work
	/// (~11 ms measured) and a batch of deletions must not pay it per file. The
	/// read is of the tree rather than the periodic snapshot, because an icon
	/// created and deleted between two refreshes was never in the snapshot at all
	/// — and the deleted icons' own elements are still in Finder's tree at this
	/// instant (measured: they survive the unlink by about 0.7 s), so this is the
	/// last chance to ask where they really were. The reading becomes the new
	/// snapshot, and the names are dropped from it: icons known to be gone must not
	/// stay spots to walk over to and lick.
	///
	/// The pre-read snapshot is kept only as this call's fallback, so a failed read
	/// (or an element that has already gone) still answers with where an icon was
	/// instead of sending her to the cursor. The snapshot itself is not kept — the
	/// cache always says what the last read said, and a failed read says nothing,
	/// exactly as in ``refresh``.
	public func iconsForDeletion(of names: [String]) -> [String: DesktopIcon] {
		let cached = icons
		let cachedAge = snapshotAgeSeconds()
		let reading = readIcons()
		apply(reading)

		var found: [String: DesktopIcon] = [:]
		var live = 0
		for name in names {
			if let icon = icons.removeValue(forKey: name) {
				found[name] = icon
				live += 1
			} else if let icon = cached[name] {
				found[name] = icon
			}
		}
		logDeletionResolution(
			reading: reading,
			names: names,
			live: live,
			resolved: found.count,
			cachedAge: cachedAge
		)
		return found
	}

	public func refresh() {
		apply(readIcons())
	}

	private func readIcons() -> IconReading {
		reader()
	}

	/// Replaces the snapshot, and says why when it could not be read.
	private func apply(_ reading: IconReading) {
		icons = Dictionary(
			(reading.icons ?? []).map { ($0.name, $0) },
			uniquingKeysWith: { _, last in last }
		)
		if reading.icons != nil { lastSnapshotAt = Date() }

		let key = Self.outcomeKey(reading)
		guard key != lastLoggedReading else { return }
		lastLoggedReading = key
		DiagnosticsLog.shared.writeEvent(
			"DesktopIconIndex",
			[("Outcome", Self.describe(reading)), ("Icons", "\(icons.count)")]
		)
	}

	/// How old the snapshot a fallback would be answered from is. The periodic
	/// refresh is two seconds, so this is the window a position can be out of date
	/// by — and the answer for a ghost that is in the right place to within a file
	/// move rather than wildly wrong.
	private func snapshotAgeSeconds() -> Double {
		guard let lastSnapshotAt else { return -1 }
		return Date().timeIntervalSince(lastSnapshotAt)
	}

	/// The outcome without the positions, so a file moving about does not log.
	private struct OutcomeKey: Equatable {
		var readable: Bool
		var count: Int
		var failure: IconReading.Failure?
	}

	private static func outcomeKey(_ reading: IconReading) -> OutcomeKey {
		switch reading {
		case .icons(let icons):
			return OutcomeKey(readable: true, count: icons.count, failure: nil)
		case .unavailable(let failure):
			return OutcomeKey(readable: false, count: 0, failure: failure)
		}
	}

	/// How a batch of deletions was resolved, which is the one place the answer to
	/// "why is this ghost in the wrong place" lives: a name that was not in the
	/// reading at all is answered from the cache, which can be two seconds stale.
	///
	/// `Prefix` counts the requested names that another icon's name starts with.
	/// Finder can report an icon under a different name from the file's — the
	/// extension is hidden on the desktop but usually present in the accessibility
	/// description — and that mismatch is invisible in every other field here.
	private func logDeletionResolution(
		reading: IconReading,
		names: [String],
		live: Int,
		resolved: Int,
		cachedAge: Double
	) {
		let readNames = reading.icons?.map(\.name) ?? []
		let prefix = names.filter { name in
			!readNames.contains(name) && readNames.contains { $0.hasPrefix(name + ".") }
		}.count
		DiagnosticsLog.shared.writeEvent(
			"DeletionIcons",
			[
				("Read", Self.describe(reading)),
				("Asked", "\(names.count)"),
				("Live", "\(live)"),
				("Resolved", "\(resolved)"),
				("Prefix", "\(prefix)"),
				("SnapshotAge", String(format: "%.1f", cachedAge)),
			]
		)
	}

	private static func describe(_ reading: IconReading) -> String {
		switch reading {
		case .icons(let icons): return "ok(\(icons.count))"
		case .unavailable(let failure): return "unavailable:\(failure.rawValue)"
		}
	}

	public func start(interval: Double = 2) {
		guard timer == nil else { return }
		refresh()
		let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.refresh() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	public func stop() {
		timer?.invalidate()
		timer = nil
		appearanceTimer?.invalidate()
		appearanceTimer = nil
	}

	// MARK: - Waiting for a new icon

	/// How often the tree is read while waiting for a new icon, and how long the
	/// wait lasts.
	///
	/// Finder does not draw a new file's icon at once: measured on this machine, the
	/// element appears **0.20–1.19 s** after the file does. A two-second poll can
	/// therefore miss an icon for its whole life, and an icon no reading ever saw is
	/// one whose deletion has no position to draw at — it falls back to the cursor
	/// and to a made-up size.
	static let appearancePollInterval: Double = 0.25
	static let appearanceWait: Double = 3

	/// Both as instance values, so a test can drive the wait by hand. Left at their
	/// defaults they are the two constants above; a test sets the interval out of
	/// reach so the timer it can never see does not race its own calls.
	var appearancePollInterval = DesktopIconIndex.appearancePollInterval
	var appearanceWait = DesktopIconIndex.appearanceWait

	private var appearanceTimer: Timer?
	/// Names waiting to be seen, and when each wait began and gives up.
	private var awaiting: [String: (startedAt: Date, deadline: Date)] = [:]

	/// Waits for these names to show up in a reading.
	///
	/// Called when files appear in a watched folder. Reading once at that moment
	/// usually catches nothing, because Finder has not drawn them yet; reading until
	/// they appear is what puts their positions — and their sizes — in the snapshot
	/// before they are deleted.
	public func awaitAppearance(of names: [String]) {
		guard isStarted else { return }
		let now = Date()
		let deadline = now.addingTimeInterval(appearanceWait)
		for name in names where icons[name] == nil && awaiting[name] == nil {
			awaiting[name] = (startedAt: now, deadline: deadline)
		}
		guard !awaiting.isEmpty else { return }
		guard appearanceTimer == nil else { return }
		let timer = Timer(timeInterval: appearancePollInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.pollForAppearance() }
		}
		RunLoop.main.add(timer, forMode: .common)
		appearanceTimer = timer
	}

	private var isStarted: Bool { timer != nil }

	/// The names the appearance wait is still looking for. Internal so a test can
	/// assert that it gave up rather than timing three real seconds.
	var debugAwaitingAppearances: [String] { awaiting.keys.sorted() }

	/// One poll of the appearance wait. Also the test seam: the timer is what drives
	/// this in the app, and a test cannot run a run loop.
	func pollForAppearance() {
		refresh()
		let now = Date()
		var stillWaiting: [String: (startedAt: Date, deadline: Date)] = [:]
		for (name, wait) in awaiting {
			// How long the wait took is the interesting number: it is the gap between
			// the file appearing and its icon existing, and a read before that gap ends
			// cannot see the icon at all.
			if icons[name] != nil {
				logAppearance(name: name, wait: wait, found: true, at: now)
			} else if now < wait.deadline {
				stillWaiting[name] = wait
			} else {
				logAppearance(name: name, wait: wait, found: false, at: now)
			}
		}
		awaiting = stillWaiting
		guard awaiting.isEmpty else { return }
		appearanceTimer?.invalidate()
		appearanceTimer = nil
	}

	/// Whether the wait found the icon, and how long it took.
	///
	/// Zero means it was already in the snapshot when the file appeared, which is the
	/// common case: a file copied in from another folder was readable at once.
	private func logAppearance(
		name: String,
		wait: (startedAt: Date, deadline: Date),
		found: Bool,
		at now: Date
	) {
		DiagnosticsLog.shared.writeEvent(
			found ? "IconAppeared" : "IconNeverAppeared",
			[
				("Name", name),
				("Waited", String(format: "%.2f", now.timeIntervalSince(wait.startedAt))),
			]
		)
	}

	/// Whether the process may use Accessibility, asking once if not.
	@discardableResult
	public nonisolated static func requestTrustIfNeeded(prompt: Bool) -> Bool {
		// The literal rather than `kAXTrustedCheckOptionPrompt`: the global is a
		// mutable var, which Swift 6 concurrency rejects.
		let options = ["AXTrustedCheckOptionPrompt": prompt]
		return AXIsProcessTrustedWithOptions(options as CFDictionary)
	}

	// MARK: - The real read

	/// The live reading, with the reason when it cannot be made.
	public nonisolated static func readDesktopIcons() -> IconReading {
		guard AXIsProcessTrusted() else { return .unavailable(.accessibilityNotTrusted) }
		guard let pid = finderPID() else { return .unavailable(.finderNotRunning) }

		let application = AXUIElementCreateApplication(pid)
		// Bounds the IPC: a Finder that stops responding must not freeze the pet,
		// since this runs on the main thread.
		AXUIElementSetMessagingTimeout(application, 1.0)
		guard let container = iconContainer(under: application) else {
			return .unavailable(.noIconContainer)
		}

		var icons: [DesktopIcon] = []
		for child in children(of: container) {
			guard role(of: child) == kAXImageRole as String,
				let name = string(of: child, kAXDescriptionAttribute as String),
				let origin = point(of: child, kAXPositionAttribute as String),
				let size = size(of: child, kAXSizeAttribute as String)
			else { continue }
			icons.append(
				DesktopIcon(
					name: name,
					position: PixelPoint(
						x: Double(origin.x + size.width / 2),
						y: Double(origin.y + size.height / 2)
					),
					size: Double(size.width)
				)
			)
		}
		return .icons(icons)
	}

	private nonisolated static func finderPID() -> pid_t? {
		NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
			.first?.processIdentifier
	}

	/// The shallowest element that has icon children.
	///
	/// Walking to it rather than screen-scraping the whole tree keeps the read to
	/// a few dozen IPC round trips, and avoiding a role/description name match
	/// keeps it working regardless of the system language.
	private nonisolated static func iconContainer(
		under root: AXUIElement,
		maxDepth: Int = 5
	) -> AXUIElement? {
		var frontier = [root]
		for _ in 0..<maxDepth {
			var next: [AXUIElement] = []
			for element in frontier {
				let kids = children(of: element)
				if kids.contains(where: { role(of: $0) == kAXImageRole as String }) { return element }
				next.append(contentsOf: kids)
			}
			frontier = next
			if frontier.isEmpty { break }
		}
		return nil
	}

	private nonisolated static func children(of element: AXUIElement) -> [AXUIElement] {
		attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
	}

	private nonisolated static func role(of element: AXUIElement) -> String? {
		attribute(element, kAXRoleAttribute as String) as? String
	}

	private nonisolated static func string(of element: AXUIElement, _ key: String) -> String? {
		attribute(element, key) as? String
	}

	private nonisolated static func point(of element: AXUIElement, _ key: String) -> CGPoint? {
		guard let value = attribute(element, key), CFGetTypeID(value) == AXValueGetTypeID() else {
			return nil
		}
		var result = CGPoint.zero
		guard AXValueGetValue(value as! AXValue, .cgPoint, &result) else { return nil }
		return result
	}

	private nonisolated static func size(of element: AXUIElement, _ key: String) -> CGSize? {
		guard let value = attribute(element, key), CFGetTypeID(value) == AXValueGetTypeID() else {
			return nil
		}
		var result = CGSize.zero
		guard AXValueGetValue(value as! AXValue, .cgSize, &result) else { return nil }
		return result
	}

	private nonisolated static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
		var value: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
			return nil
		}
		return value
	}
}
