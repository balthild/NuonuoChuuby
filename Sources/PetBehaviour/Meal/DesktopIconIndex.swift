import AppKit
import ApplicationServices
import PetFoundation

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
/// Reads go through ``IconContainerCache``: the element whose children are the
/// icons is found once per Finder process, not once per read.
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

	/// - Parameter reader: A replacement for the real read, for tests. Left out, the
	///   read is the real one, through a container kept from an earlier read.
	public init(reader: Reader? = nil) {
		self.reader = reader ?? IconContainerCache().read
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
	/// Every name is resolved from one read, because one read is real work (10 ms
	/// measured) and a batch of deletions must not pay it per file. The read is of
	/// the tree rather than the periodic snapshot, because an icon created and
	/// deleted between two refreshes was never in the snapshot at all
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
	///
	/// Remembers nothing: this is the read without the kept container, which is what
	/// a test can call — the read itself is cross-process IPC to Finder and cannot be
	/// exercised without it. ``DesktopIconIndex`` reads through ``IconContainerCache``
	/// instead.
	public nonisolated static func readDesktopIcons() -> IconReading {
		IconContainerCache().read()
	}

	private nonisolated static func finderPID() -> pid_t? {
		NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
			.first?.processIdentifier
	}

	/// The shallowest element that has icon children.
	///
	/// Walking to it rather than screen-scraping the whole tree keeps the read to
	/// a few round trips, and avoiding a role/description name match keeps it
	/// working regardless of the system language.
	///
	/// The walk is bounded so that it cannot run away when there is no container to
	/// find. Measured on this machine 2026-11-05 with the probe in `_ignored/ax-walk`,
	/// with the desktop's icons hidden — the state that made the read cost 38–63 ms
	/// every two seconds:
	///
	///   * **The menu bar is never descended into.** It is not the desktop, and its
	///     open menus are the bulk of Finder's tree: 185 elements, 382 round trips
	///     without this, **1 element, 3 round trips** with it.
	///   * **Three levels, not five.** The application's children are its windows, its
	///     menu bar and the desktop's scroll area, and the container is that scroll
	///     area's child, so three levels reach it. Three also keeps the cost
	///     independent of how much Finder is showing: with the icons hidden and a
	///     window open, **8–15 elements and 46–89 round trips**, against 217–245
	///     elements and 479–565 round trips without the bound.
	///
	/// The desktop container was found at three levels in every state tried — icons
	/// shown, hidden, Stacks on and off, and windows open in list and icon view.
	private nonisolated static func iconContainer(
		under root: AXUIElement,
		maxDepth: Int = 3
	) -> AXUIElement? {
		var frontier = [root]
		for _ in 0..<maxDepth {
			var next: [AXUIElement] = []
			for element in frontier {
				let kids = children(of: element) ?? []
				// One role read per child: it both answers "is this the container" and
				// decides what is worth descending into. Batching would not help — this is
				// one value per child either way.
				var descendable: [AXUIElement] = []
				for kid in kids {
					let kidRole = role(of: kid)
					if kidRole == kAXImageRole as String { return element }
					if kidRole != kAXMenuBarRole as String { descendable.append(kid) }
				}
				next.append(contentsOf: descendable)
			}
			frontier = next
			if frontier.isEmpty { break }
		}
		return nil
	}

	/// The icons this container's children draw, or nil when the element is no longer
	/// usable.
	///
	/// The distinction is what ``IconContainerCache`` turns on: an element that
	/// answers with no children is an empty desktop, which is a reading, while an
	/// element that does not answer at all is one Finder has discarded and has to be
	/// found again. Measured on this machine with the desktop's icons hidden: the
	/// kept element answered "no children" in 0.45 ms where finding one again cost
	/// **400** round trips and 48 ms, so dropping it on an empty answer would be the
	/// expensive mistake.
	private nonisolated static func icons(of container: AXUIElement) -> [DesktopIcon]? {
		guard let kids = children(of: container) else { return nil }
		return kids.compactMap(icon(of:))
	}

	/// The desktop's icon container, kept between reads.
	///
	/// The element whose children are the icons is the same one for as long as Finder
	/// is: finding it means walking Finder's tree from its application element, and
	/// that walk costs 32 round trips with nothing else open in Finder, 58 in the
	/// common case, 132 with three windows open — against 23 for the icons themselves.
	/// So it is found once and the reference kept, and a read after that is the icons
	/// plus the one call that proves the element is still there.
	///
	/// Measured on this machine (probe in `_ignored/ax-container`; 175 s of reads
	/// across Space switches, a Stacks toggle, a Finder restart and the desktop's
	/// icons being hidden): the kept element always answered with the same icons as a
	/// fresh walk, followed the Stacks toggle, and survived the icons being hidden.
	/// A Finder restart made it answer `kAXErrorCannotComplete`, which the cached read
	/// discovers for free — that is the children call it makes anyway — and then it
	/// falls back to a walk.
	///
	/// Deliberately without a lock: every caller is the main thread —
	/// ``DesktopIconIndex`` is `@MainActor`, and its timer runs on the main run loop.
	private final class IconContainerCache {
		private var element: AXUIElement?
		private var pid: pid_t?

		func read() -> IconReading {
			guard AXIsProcessTrusted() else { return .unavailable(.accessibilityNotTrusted) }
			guard let finder = DesktopIconIndex.finderPID() else {
				forget()
				return .unavailable(.finderNotRunning)
			}

			// The element is only worth keeping for the pid it came from: another Finder
			// is another tree, and the pid is what says so.
			if pid == finder, let kept = element, let icons = DesktopIconIndex.icons(of: kept) {
				return .icons(icons)
			}
			forget()

			let application = AXUIElementCreateApplication(finder)
			AXUIElementSetMessagingTimeout(application, 1.0)
			guard let container = DesktopIconIndex.iconContainer(under: application),
				let icons = DesktopIconIndex.icons(of: container)
			else { return .unavailable(.noIconContainer) }

			// The element outlives the application element it was found through, so it
			// needs a timeout of its own: a Finder that stops responding must not block
			// this read, which runs on the main thread.
			AXUIElementSetMessagingTimeout(container, 1.0)
			element = container
			pid = finder
			return .icons(icons)
		}

		private func forget() {
			element = nil
			pid = nil
		}
	}

	/// The element's children, or nil when the call failed.
	///
	/// Nil rather than an empty list, because the two mean opposite things to a
	/// caller holding the element: "this Finder has no access to its tree" against
	/// "there is nothing there".
	private nonisolated static func children(of element: AXUIElement) -> [AXUIElement]? {
		var value: CFTypeRef?
		guard
			AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
				== .success
		else { return nil }
		return value as? [AXUIElement] ?? []
	}

	private nonisolated static func role(of element: AXUIElement) -> String? {
		attribute(element, kAXRoleAttribute as String) as? String
	}

	/// The attributes an icon is described by, in the order the values come back, and
	/// in one call: an attribute the element does not have comes back as `kCFNull`, or
	/// as an `AXValue` carrying the error, rather than failing the whole read.
	///
	/// Nested rather than a member of the index: the index is `@MainActor`, so a stored
	/// `static let` in it is isolated to the main actor, while the read that asks for
	/// these is `nonisolated`.
	private enum IconAttribute {
		static let names = [
			kAXRoleAttribute as String,
			kAXDescriptionAttribute as String,
			kAXPositionAttribute as String,
			kAXSizeAttribute as String,
		]
	}

	/// The icon this element draws, or nil when it is not one: a child of the
	/// container that is not an image, or an icon Finder will not describe in full,
	/// is skipped rather than guessed at.
	///
	/// Its four attributes are asked for in **one** call rather than four. Each is a
	/// synchronous round trip to Finder, and for the 23 icons of a full desktop that
	/// is 23 round trips instead of 92: measured in the app with `getrusage` wrapped
	/// round the read, this cost 11.1–13.5 ms of blocked main thread and 2.8 ms of CPU
	/// before, 8.6–10.3 ms and 2.1 ms after.
	///
	/// Asking for all four everywhere the walk passes gives the saving back — the
	/// search descends through several dozen elements that want only a role — so the
	/// batching is confined to the elements whose four attributes are all wanted.
	private nonisolated static func icon(of element: AXUIElement) -> DesktopIcon? {
		var values: CFArray?
		guard
			AXUIElementCopyMultipleAttributeValues(
				element,
				IconAttribute.names as CFArray,
				[],
				&values
			) == .success,
			let values = values as? [Any],
			values.count == IconAttribute.names.count,
			values[0] as? String == kAXImageRole as String,
			let name = values[1] as? String,
			let origin = point(values[2]),
			let size = size(values[3])
		else { return nil }
		return DesktopIcon(
			name: name,
			position: PixelPoint(
				x: Double(origin.x + size.width / 2),
				y: Double(origin.y + size.height / 2)
			),
			size: Double(size.width)
		)
	}

	private nonisolated static func point(_ value: Any?) -> CGPoint? {
		guard let value = value as? CFTypeRef, CFGetTypeID(value) == AXValueGetTypeID() else {
			return nil
		}
		var result = CGPoint.zero
		guard AXValueGetValue(value as! AXValue, .cgPoint, &result) else { return nil }
		return result
	}

	private nonisolated static func size(_ value: Any?) -> CGSize? {
		guard let value = value as? CFTypeRef, CFGetTypeID(value) == AXValueGetTypeID() else {
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
