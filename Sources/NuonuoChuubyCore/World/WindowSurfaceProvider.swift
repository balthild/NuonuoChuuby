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
		var result: [SupportSurface] = []
		for window in windows {
			result.append(contentsOf: segments(for: window, displaySpace: displaySpace))
		}
		return result
	}

	/// Re-reads just one window's bounds.
	///
	/// The surface map is only rebuilt every half second, which would make a
	/// dragged window feel jerky. Asking the window server about the single
	/// window the pet is standing on is cheap enough to do every frame, and is
	/// what the original called its "live tracked surface".
	static func liveSurface(
		windowID: UInt32,
		displaySpace: DisplaySpace,
		footX: Double
	) -> SupportSurface? {
		guard let bounds = liveBounds(of: windowID) else { return nil }

		// Reuse the same splitting and reachability rules as the periodic map, so
		// a live read can never disagree with it.
		let window = TerrainWindow(
			number: windowID, ownerPID: 0, ownerName: "",
			bounds: bounds, layer: 0, alpha: 1)
		let candidates = segments(for: window, displaySpace: displaySpace)
			.filter { $0.sourceID == windowID }
		guard !candidates.isEmpty else { return nil }

		return candidates.first { $0.containsX(footX, inset: 0) } ?? candidates[0]
	}

	/// The window's current bounds, queried directly.
	static func liveBounds(of windowID: UInt32) -> PixelRect? {
		// Asking about one window is far cheaper than enumerating the list, which
		// matters because this runs every frame for the window she stands on.
		guard
			let list = CGWindowListCreateDescriptionFromArray(
				[NSNumber(value: windowID)] as CFArray) as? [[String: AnyObject]],
			let entry = list.first,
			let boundsDict = entry[kCGWindowBounds as String] as? [String: AnyObject],
			let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
		else { return nil }

		return PixelRect(
			x: Double(rect.origin.x), y: Double(rect.origin.y),
			width: Double(rect.width), height: Double(rect.height))
	}

	/// A window's standable segments, one per display it overlaps.
	private static func segments(for window: TerrainWindow, displaySpace: DisplaySpace) -> [SupportSurface] {
		let minimumSegmentWidth = WindowTerrainEligibilityPolicy.minimumWidth
		var result: [SupportSurface] = []

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
		return result
	}
}
