import AppKit
import ApplicationServices

/// An icon on the desktop, as Finder reports it.
public struct DesktopIcon: Sendable, Equatable {
	public var name: String
	/// The icon's centre, top-left origin, Y down — the same space as
	/// ``DisplaySpace``, so no conversion is needed.
	public var position: PixelPoint
}

/// Reads Finder's **real** desktop icon positions through Accessibility.
///
/// The icon's accessibility element disappears the instant it is deleted, so this
/// has to be a periodic index (name → position) that a deletion event looks up.
///
/// Accessibility is a **soft** dependency: without it (or with Finder not running)
/// `icons` is empty and callers fall back to ``DesktopIconGrid``.
@MainActor
public final class DesktopIconIndex {
	/// Supplies the icons; returns nil when it cannot read at all.
	public typealias Reader = () -> [DesktopIcon]?

	private let reader: Reader
	private var timer: Timer?

	public private(set) var icons: [String: DesktopIcon] = [:]
	/// The last count written to the diagnostics log, so only a change is logged.
	private var lastLoggedCount = -1

	public init(reader: @escaping Reader = DesktopIconIndex.readFinderIcons) {
		self.reader = reader
	}

	public var isAvailable: Bool { !icons.isEmpty }

	/// The icons in a stable order, so a random pick is reproducible.
	public var positions: [PixelPoint] {
		icons.values
			.sorted { ($0.position.y, $0.position.x) < ($1.position.y, $1.position.x) }
			.map(\.position)
	}

	public func position(of name: String) -> PixelPoint? { icons[name]?.position }

	public func refresh() {
		if let read = reader() {
			icons = Dictionary(read.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
		} else {
			icons = [:]
		}
		// Logged only when the count changes; a count of 0 means Accessibility
		// was not granted.
		guard icons.count != lastLoggedCount else { return }
		lastLoggedCount = icons.count
		DiagnosticsLog.shared.writeEvent("DesktopIconIndex", [("Icons", "\(icons.count)")])
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

	/// The live reading. Nil when Accessibility is not available.
	public nonisolated static func readFinderIcons() -> [DesktopIcon]? {
		guard AXIsProcessTrusted() else { return nil }
		guard let pid = finderPID() else { return nil }

		let application = AXUIElementCreateApplication(pid)
		// Bounds the IPC: a Finder that stops responding must not freeze the pet,
		// since this runs on the main thread.
		AXUIElementSetMessagingTimeout(application, 1.0)
		guard let container = iconContainer(under: application) else { return nil }

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
					)
				)
			)
		}
		return icons
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
