import CoreGraphics
import Foundation

/// Turns platform windows into the top edges the pet may stand on.
enum WindowSurfaceProvider {
	/// Keeps only the windows that may be terrain.
	///
	/// Each display judges the windows overlapping it, so a window is kept if it
	/// is reachable on any display.
	static func eligibleWindows(
		from windows: [PlatformWindow], ownPID: Int32, displaySpace: DisplaySpace
	) -> [PlatformWindow] {
		windows.filter { window in
			displaySpace.displays.contains { display in
				WindowTerrainEligibilityPolicy.isEligiblePlatform(
					window, ownPID: ownPID, workArea: display.visibleFrame)
			}
		}
	}

	/// Turns windows into standable top edges, split per display so a window
	/// spanning two screens provides a platform on each.
	static func surfaces(from windows: [PlatformWindow], displaySpace: DisplaySpace) -> [SupportSurface] {
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
	///
	/// Unlike discovery, this does **not** re-apply the reachability rules: the
	/// window is already her support, so if the user drags it up under the menu
	/// bar or off the edge of the screen she should keep riding it rather than
	/// being dropped.
	static func liveSurface(
		windowID: UInt32,
		displaySpace: DisplaySpace,
		footX: Double
	) -> SupportSurface? {
		guard let bounds = liveBounds(of: windowID) else { return nil }

		let candidates = segments(
			for: PlatformWindow(
				id: windowID, ownerPID: 0, ownerName: "", bounds: bounds, layer: 0, alpha: 1),
			displaySpace: displaySpace,
			requireReachable: false)
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
	private static func segments(
		for window: PlatformWindow,
		displaySpace: DisplaySpace,
		requireReachable: Bool = true
	) -> [SupportSurface] {
		let minimumSegmentWidth = WindowTerrainEligibilityPolicy.minimumWidth
		var result: [SupportSurface] = []

		for display in displaySpace.displays {
			let left = max(window.bounds.left, display.frame.left)
			let right = min(window.bounds.right, display.frame.right)
			guard right - left >= minimumSegmentWidth else { continue }

			// Standing under the menu bar or on the Dock is not reachable, but a
			// window she is already standing on stays valid wherever it is moved.
			if requireReachable {
				guard window.bounds.top >= display.visibleFrame.top,
					window.bounds.top < display.visibleFrame.bottom
				else { continue }
			}

			result.append(
				SupportSurface(
					top: window.bounds.top,
					left: left,
					right: right,
					bottom: window.bounds.bottom,
					isDesktopFloor: false,
					sourceID: window.id
				))
		}
		return result
	}
}
