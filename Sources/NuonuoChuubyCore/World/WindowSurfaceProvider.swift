import CoreGraphics
import Foundation

/// Enumerates the on-screen windows the pet may stand on.
///
/// Bounds are available from `CGWindowListCopyWindowInfo` without any
/// permission — only window *titles* and *contents* require screen recording, so
/// this stays permission-free. The dictionary's bounds already use the
/// top-left, Y-down origin that the simulation works in.
enum WindowSurfaceProvider {
	static func enumerateEligibleWindows(ownPID: Int32, displaySpace: DisplaySpace) -> [TerrainWindow] {
		let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
		guard
			let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]]
		else { return [] }

		return raw.compactMap { entry in
			guard let number = entry[kCGWindowNumber as String] as? UInt32,
				let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
				let layer = entry[kCGWindowLayer as String] as? Int,
				let boundsDict = entry[kCGWindowBounds as String] as? [String: AnyObject]
			else { return nil }

			let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
			let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1
			guard let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }

			let window = TerrainWindow(
				number: number,
				ownerPID: ownerPID,
				ownerName: ownerName,
				title: entry[kCGWindowName as String] as? String,
				bounds: PixelRect(
					x: Double(rect.origin.x), y: Double(rect.origin.y),
					width: Double(rect.width), height: Double(rect.height)),
				layer: layer,
				alpha: alpha
			)

			// Each display judges the windows overlapping it, so a window is kept
			// if it is reachable on any display.
			let eligible = displaySpace.displays.contains { display in
				WindowTerrainEligibilityPolicy.isEligiblePlatform(
					window, ownPID: ownPID, workArea: display.visibleFrame)
			}
			return eligible ? window : nil
		}
	}

	/// Turns windows into standable top edges, split per display so a window
	/// spanning two screens provides a platform on each.
	static func surfaces(from windows: [TerrainWindow], displaySpace: DisplaySpace) -> [SupportSurface] {
		let minimumSegmentWidth = WindowTerrainEligibilityPolicy.minimumWidth
		var result: [SupportSurface] = []

		for window in windows {
			for display in displaySpace.displays {
				let left = max(window.bounds.left, display.frame.left)
				let right = min(window.bounds.right, display.frame.right)
				guard right - left >= minimumSegmentWidth else { continue }

				// Standing under the menu bar or on the Dock is not reachable.
				guard window.bounds.top >= display.visibleFrame.top,
					window.bounds.top < display.visibleFrame.bottom
				else { continue }

				result.append(
					SupportSurface(
						top: window.bounds.top,
						left: left,
						right: right,
						bottom: window.bounds.bottom,
						isDesktopFloor: false,
						sourceID: window.number
					))
			}
		}
		return result
	}
}
