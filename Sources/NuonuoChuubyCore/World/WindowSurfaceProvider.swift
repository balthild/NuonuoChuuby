import CoreGraphics
import Foundation

/// Re-reads a single window's bounds, for the surface the pet is standing on.
///
/// The graph is only rebuilt every half second, which would make a dragged
/// window feel jerky. Asking the window server about the one window the pet is
/// standing on is cheap enough to do every frame, and is what the original called
/// its "live tracked surface". Everything else lives in ``SurfaceBuilder``.
enum WindowSurfaceProvider {
	/// The surface under a foot on a specific window, resolved by identity.
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
			displaySpace: displaySpace)
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
	///
	/// Reachability is deliberately not checked: the pet is already standing on
	/// the window, so it stays valid wherever it has been moved to.
	private static func segments(
		for window: PlatformWindow,
		displaySpace: DisplaySpace
	) -> [SupportSurface] {
		let minimumSegmentWidth = WindowTerrainEligibilityPolicy.minimumWidth
		var result: [SupportSurface] = []

		for display in displaySpace.displays {
			let left = max(window.bounds.left, display.frame.left)
			let right = min(window.bounds.right, display.frame.right)
			guard right - left >= minimumSegmentWidth else { continue }

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
