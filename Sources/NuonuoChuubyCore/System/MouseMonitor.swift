import AppKit

/// Records where the user last clicked.
@MainActor
public final class MouseMonitor {
	/// A click is only a useful anchor for a short while after it happens.
	private static let anchorLifetime: Double = 15

	private let displaySpace: DisplaySpace
	private var monitors: [Any] = []
	private var lastClick: (point: PixelPoint, at: Date)?

	public init(displaySpace: DisplaySpace) {
		self.displaySpace = displaySpace
	}

	public func start() {
		guard monitors.isEmpty else { return }
		let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
		if let monitor = NSEvent.addGlobalMonitorForEvents(
			matching: mask,
			handler: { [weak self] event in
				MainActor.assumeIsolated { self?.record(event) }
			}
		) {
			monitors.append(monitor)
		}
	}

	public func stop() {
		for monitor in monitors { NSEvent.removeMonitor(monitor) }
		monitors.removeAll()
	}

	/// The best guess at where the deleted icon was: the last click if it is
	/// recent, otherwise the cursor.
	public func anchor() -> (point: PixelPoint, isExact: Bool) {
		if let lastClick, Date().timeIntervalSince(lastClick.at) <= Self.anchorLifetime {
			return (lastClick.point, true)
		}
		return (cursor, false)
	}

	public var cursor: PixelPoint {
		let location = NSEvent.mouseLocation
		return PixelPoint(
			x: Double(location.x),
			y: displaySpace.primaryHeight - Double(location.y)
		)
	}

	private func record(_ event: NSEvent) {
		let location = NSEvent.mouseLocation
		lastClick = (
			PixelPoint(x: Double(location.x), y: displaySpace.primaryHeight - Double(location.y)),
			Date()
		)
	}
}
