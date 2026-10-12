import AppKit
import CoreGraphics

/// The real ``Platform``: `CGWindowListCopyWindowInfo` for windows, `NSScreen`
/// for displays.
///
/// The dictionary's bounds already use the top-left, Y-down origin the simulation
/// works in.
@MainActor
public final class MacOSPlatform: Platform {
	public init() {}

	/// The primary display's height, which defines the Y flip for every display.
	public var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

	public func windows() -> [PlatformWindow] {
		let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
		guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]]
		else { return [] }

		return raw.enumerated().compactMap { index, entry in
			guard
				let number = entry[kCGWindowNumber as String] as? UInt32,
				let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
				let layer = entry[kCGWindowLayer as String] as? Int,
				let boundsDict = entry[kCGWindowBounds as String] as? [String: AnyObject],
				let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
			else { return nil }

			return PlatformWindow(
				id: number,
				ownerPID: ownerPID,
				ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
				bounds: PixelRect(
					x: Double(rect.origin.x),
					y: Double(rect.origin.y),
					width: Double(rect.width),
					height: Double(rect.height)
				),
				layer: layer,
				alpha: (entry[kCGWindowAlpha as String] as? Double) ?? 1,
				zIndex: index
			)
		}
	}

	public func monitors() -> [Monitor] {
		let primaryHeight = self.primaryHeight
		return NSScreen.screens.compactMap { screen in
			guard
				let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
					as? NSNumber
			else { return nil }
			return Monitor(
				id: number.uint32Value,
				frame: DisplaySpace.toTopLeft(screen.frame, primaryHeight: primaryHeight),
				visibleFrame: DisplaySpace.toTopLeft(screen.visibleFrame, primaryHeight: primaryHeight),
				scale: Double(screen.backingScaleFactor)
			)
		}
	}
}
