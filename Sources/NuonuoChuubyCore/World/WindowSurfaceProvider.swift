import CoreGraphics
import Foundation

/// Re-reads a single window's bounds, for the surface the pet is standing on, so a
/// dragged window does not lag the half-second graph rebuild.
@MainActor
enum WindowSurfaceProvider {
	/// The window's top edge as a surface, read fresh this frame.
	///
	/// Its occlusion is *not* recomputed — the graph is the authority for that, and
	/// the window she rides is in front of whatever it overlaps. Reachability **is**
	/// recomputed: a window dragged up under the menu bar is no longer somewhere she
	/// can stand, and she is dropped rather than carried out of reach.
	///
	/// `isOnThisDesktop` is what stops her standing on a window of a desk she has
	/// switched away from. That question cannot be answered from the rectangle: the
	/// switch moves the desktop, not the window, so the live read goes on reporting
	/// the same edges it reported before — verified with a probe. It is asked
	/// separately for that reason, and answered from the on-screen sample.
	static func liveWindowSurface(
		windowID: UInt32,
		monitors: [Monitor],
		isOnThisDesktop: Bool
	) -> Surface? {
		guard let bounds = liveBounds(of: windowID), isOnThisDesktop else { return nil }
		// A window on another desktop keeps its rectangle: switching Spaces moves the
		// desktop, not the window, and the window server goes on answering for it. It
		// is not somewhere she can be seen standing, so it is not somewhere she can
		// stand — otherwise a switch leaves her on the edge of a window that is not
		// on this screen, with nothing under her.
		guard monitors.shows(bounds) else { return nil }
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

	/// The window's rectangle right now, from whichever read the launch flag chose.
	///
	/// The private read is the same question answered without building a window
	/// description — see ``WindowServerBounds``. It falls back to the public read for
	/// a window it cannot answer for, so a window closing mid-frame behaves as it did.
	static func liveBounds(of windowID: UInt32) -> PixelRect? {
		switch WindowServerBounds.mode {
		case .publicAPI:
			let bounds = readPublicBounds(of: windowID)
			WindowServerBounds.noteRead(succeeded: bounds != nil)
			return bounds
		case .privateAPI:
			let privateBounds = WindowServerBounds.bounds(of: windowID)
			WindowServerBounds.noteRead(succeeded: privateBounds != nil)
			return privateBounds ?? readPublicBounds(of: windowID)
		case .verifying:
			let publicBounds = readPublicBounds(of: windowID)
			WindowServerBounds.noteRead(succeeded: publicBounds != nil)
			WindowServerBounds.compare(
				privateRead: WindowServerBounds.bounds(of: windowID),
				publicRead: publicBounds
			)
			return publicBounds
		}
	}

	private static func readPublicBounds(of windowID: UInt32) -> PixelRect? {
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
