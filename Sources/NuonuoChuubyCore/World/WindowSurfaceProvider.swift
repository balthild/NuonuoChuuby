import CoreGraphics
import Foundation

/// Re-reads a single window's bounds, for the surface the pet is standing on.
///
/// The graph is only rebuilt every half second, which would make a dragged
/// window feel jerky. Asking the window server about the one window the pet is
/// standing on is cheap enough to do every frame, and is what the original called
/// its "live tracked surface". Everything else lives in ``SurfaceBuilder``.
enum WindowSurfaceProvider {
	/// The window's top edge as a surface, read fresh this frame.
	///
	/// Its occlusion is *not* recomputed — the graph is the authority for that, and
	/// the window she rides is in front of whatever it overlaps. Reachability **is**
	/// recomputed: a window dragged up under the menu bar is no longer somewhere she
	/// can stand, and she is dropped rather than carried out of reach.
	static func liveWindowSurface(windowID: UInt32, monitors: [Monitor]) -> Surface? {
		guard let bounds = liveBounds(of: windowID) else { return nil }
		let span = Span(start: bounds.left, end: bounds.right)
		let reachable = monitors.contains {
			bounds.top >= $0.visibleFrame.top && bounds.top < $0.visibleFrame.bottom
		}
		return Surface(
			key: SurfaceKey(owner: windowID, kind: .windowTop),
			span: span,
			visible: [span],
			offset: bounds.top,
			ownerBounds: bounds,
			isReachable: reachable
		)
	}

	/// The window's current bounds, queried directly.
	static func liveBounds(of windowID: UInt32) -> PixelRect? {
		// Asking about one window is far cheaper than enumerating the list, which
		// matters because this runs every frame for the window she stands on.
		//
		// `CGWindowListCreateDescriptionFromArray` is the documented way to do this,
		// but it returns an empty array on macOS 14 (verified on this machine: it is
		// empty for every window, on screen or not, while the full enumeration has
		// them all). Asking the list for just this window works and is still a
		// single-window query.
		guard
			let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
				as? [[String: AnyObject]],
			let entry = list.first,
			let boundsDict = entry[kCGWindowBounds as String] as? [String: AnyObject],
			let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
		else { return nil }

		return PixelRect(
			x: Double(rect.origin.x),
			y: Double(rect.origin.y),
			width: Double(rect.width),
			height: Double(rect.height)
		)
	}
}
