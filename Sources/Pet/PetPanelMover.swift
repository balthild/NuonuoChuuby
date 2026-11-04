import CoreGraphics
import Darwin
import Foundation
import PetFoundation

/// Moves one of our own windows by hand, through SkyLight's `CGSMoveWindow`.
///
/// `setFrameOrigin` is the cost the overlay was built to avoid: it is a full
/// application-to-server transaction per call, measured in the probe at **+6.3 pt** of
/// one core at 60 Hz with no pointer input at all, against **+1.4 pt** for this call.
///
/// What it costs instead is AppKit's agreement. The private call moves the window
/// server's copy of the window and AppKit is never told, so `NSWindow.frame` keeps
/// whatever position the window was created at and every point AppKit converts from a
/// pointer position is off by the distance the window has travelled. The caller has to
/// hold the real position itself; see ``PetPanelWindowController/appKitOrigin``.
///
/// It is private API, so it is looked up by name and never linked: a missing symbol
/// leaves ``isAvailable`` false and the caller on AppKit's own move.
enum PetPanelMover {
	private typealias MainConnectionID = @convention(c) () -> Int32
	private typealias MoveWindow = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> Int32
	private typealias GetWindowBounds =
		@convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32

	/// Held for the life of the process: the handle exists only for these symbols,
	/// so it is never closed.
	private static let functions: (connection: Int32, move: MoveWindow, bounds: GetWindowBounds)? = {
		let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
		guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
		guard
			let connection = dlsym(handle, "CGSMainConnectionID"),
			let move = dlsym(handle, "CGSMoveWindow"),
			let bounds = dlsym(handle, "CGSGetWindowBounds")
		else { return nil }
		let mainConnectionID = unsafeBitCast(connection, to: MainConnectionID.self)
		return (
			mainConnectionID(),
			unsafeBitCast(move, to: MoveWindow.self),
			unsafeBitCast(bounds, to: GetWindowBounds.self)
		)
	}()

	static var isAvailable: Bool { functions != nil }

	/// Puts the window's top-left corner at `topLeft`, in the window server's global
	/// top-left space, and reports whether the call was accepted.
	///
	/// An accepted call is **not** evidence that the window moved: a window that has no
	/// device yet — one that has never been ordered on screen — takes the call, returns
	/// `kCGErrorSuccess`, and does not move. Callers that need to know have to read the
	/// position back with ``bounds(of:)``.
	@discardableResult
	static func move(windowID: UInt32, to topLeft: PixelPoint) -> Bool {
		guard let functions, windowID != 0 else { return false }
		var point = CGPoint(x: topLeft.x, y: topLeft.y)
		return functions.move(functions.connection, windowID, &point) == 0
	}

	/// Where the window server thinks the window is, in its global top-left space.
	///
	/// This is the read that makes a move verifiable, and the coordinate space the
	/// pet's own frame is already in, so a caller comparing the two needs no conversion.
	/// `nil` when the lookup is unavailable or the window is gone.
	static func bounds(of windowID: UInt32) -> PixelRect? {
		guard let functions, windowID != 0 else { return nil }
		var rect = CGRect.zero
		guard functions.bounds(functions.connection, windowID, &rect) == 0 else { return nil }
		return PixelRect(
			x: Double(rect.origin.x),
			y: Double(rect.origin.y),
			width: Double(rect.width),
			height: Double(rect.height)
		)
	}
}
