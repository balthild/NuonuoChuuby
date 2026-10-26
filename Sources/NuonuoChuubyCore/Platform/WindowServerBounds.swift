import CoreGraphics
import Darwin
import Foundation

/// `CGSGetWindowBounds`, resolved from SkyLight at run time.
///
/// It answers the one question the per-frame path asks about a window — where its
/// rectangle is — in **46 µs**, against the **293 µs** the public single-window query
/// (`CGWindowListCopyWindowInfo([.optionIncludingWindow])`) costs inside the app. That
/// query builds a whole window description to return four numbers, and it is what
/// ``WindowSurfaceProvider`` pays every frame while she stands on a window or inside
/// one. Replacing it measured **2.87 → 2.19 %** of one core with her resting inside a
/// window, i.e. −24 % of that idle.
///
/// Both figures are in-app numbers from traces, not tight-loop ones: a loop reports
/// 25–27 µs for calls that cost 230–300 µs when they run between run-loop turns. The
/// tight-loop figure for this call was 2.5 µs, which made the saving look 12× when the
/// real ratio is about 6×.
///
/// The price is that it is private API, so it is looked up by name and never linked:
/// a missing symbol leaves ``isAvailable`` false and every caller on the public read.
@MainActor
enum WindowServerBounds {
	/// Which read the live bounds come from.
	///
	/// The private read is the default; the flag exists to get back to the public one for
	/// a regression check without a rebuild, and to compare the two on identical
	/// scenarios, so it is an argument rather than a menu item.
	enum Mode: String {
		/// `CGSGetWindowBounds`, falling back to the public read for the reads it fails —
		/// a window that closed since the graph was last rebuilt.
		case privateAPI = "cgs"
		/// `CGWindowListCopyWindowInfo` — the public read, for comparison.
		case publicAPI = "cg"
		/// Reads both and reports how far apart they are, returning the public one, so
		/// a verification run behaves exactly like a baseline run.
		case verifying = "cgs-verify"
	}

	static let mode: Mode = {
		let arguments = CommandLine.arguments
		// The verifying flag implies the private read: passing only `--cgs-bounds-verify`
		// and getting the public read would look like a verification of nothing.
		guard isAvailable else { return .publicAPI }
		if arguments.contains(verifyFlag) { return .verifying }
		if arguments.contains(publicFlag) { return .publicAPI }
		return .privateAPI
	}()

	private static let publicFlag = "--cgs-bounds-public"
	private static let verifyFlag = "--cgs-bounds-verify"

	private typealias MainConnectionID = @convention(c) () -> Int32
	private typealias GetWindowBounds =
		@convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32

	/// Held for the life of the process: the handle exists only for these two symbols,
	/// so it is never closed.
	private static let functions:
		(mainConnectionID: MainConnectionID, getWindowBounds: GetWindowBounds)? = {
			let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
			guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
			guard
				let connection = dlsym(handle, "CGSMainConnectionID"),
				let bounds = dlsym(handle, "CGSGetWindowBounds")
			else { return nil }
			return (
				unsafeBitCast(connection, to: MainConnectionID.self),
				unsafeBitCast(bounds, to: GetWindowBounds.self)
			)
		}()

	static var isAvailable: Bool { functions != nil }

	private static let connectionID: Int32 = functions.map { $0.mainConnectionID() } ?? 0

	/// One window's rectangle, in the same global top-left space as `kCGWindowBounds`.
	///
	/// `nil` when the lookup is unavailable, or when the window is no longer there:
	/// the call reports `kCGErrorFailure` rather than returning a stale rectangle.
	static func bounds(of windowID: UInt32) -> PixelRect? {
		guard let functions else { return nil }
		var rect = CGRect.zero
		guard functions.getWindowBounds(connectionID, windowID, &rect) == 0 else { return nil }
		return PixelRect(
			x: Double(rect.origin.x),
			y: Double(rect.origin.y),
			width: Double(rect.width),
			height: Double(rect.height)
		)
	}

	// MARK: - Verification

	/// What a verification run has seen so far, reported a batch at a time.
	private struct Comparison {
		var reads = 0
		var unreadable = 0
		var mismatches = 0
		/// Reads where the private rectangle had a fractional field. The enclosure's
		/// resting throttle compares whole rectangles for equality, so a source that
		/// returns fractional values where the public one returns integers would never
		/// read as still — the box would look like it moved every frame.
		var fractional = 0
		var maxDelta: Double = 0
	}

	private static var comparison = Comparison()
	/// 600 reads is ten seconds at 60 Hz and twenty at the enclosure's resting 30 Hz.
	private static let comparisonBatch = 600

	// MARK: - Usage

	/// How often the live read ran, and how often the private one answered.
	///
	/// It exists because a measured run with a silent fallback would look like the
	/// private read and be the public one, and because two runs can only be compared
	/// if they read at the same rate: the startup line says which read was chosen,
	/// not how often it ran.
	private struct Usage {
		var reads = 0
		var fallbacks = 0
	}

	private static var usage = Usage()

	static func noteRead(succeeded: Bool) {
		usage.reads += 1
		if !succeeded { usage.fallbacks += 1 }
		guard usage.reads % comparisonBatch == 0 else { return }
		DiagnosticsLog.shared.writeEvent(
			"WindowBoundsReads",
			[
				("Kind", mode.rawValue),
				("Reads", "\(usage.reads)"),
				("Fallbacks", "\(usage.fallbacks)"),
			]
		)
	}

	/// Compares one private read against the public read of the same window.
	static func compare(privateRead: PixelRect?, publicRead: PixelRect?) {
		comparison.reads += 1
		guard let privateRead, let publicRead else {
			comparison.unreadable += 1
			return reportComparisonIfFull()
		}
		let difference = largestDifference(privateRead, publicRead)
		comparison.maxDelta = max(comparison.maxDelta, difference)
		if difference > 0.001 { comparison.mismatches += 1 }
		if !isIntegral(privateRead) { comparison.fractional += 1 }
		reportComparisonIfFull()
	}

	private static func largestDifference(_ first: PixelRect, _ second: PixelRect) -> Double {
		max(
			abs(first.x - second.x),
			abs(first.y - second.y),
			abs(first.width - second.width),
			abs(first.height - second.height)
		)
	}

	private static func isIntegral(_ rect: PixelRect) -> Bool {
		for value in [rect.x, rect.y, rect.width, rect.height] where value != value.rounded() {
			return false
		}
		return true
	}

	private static func reportComparisonIfFull() {
		guard comparison.reads >= comparisonBatch else { return }
		DiagnosticsLog.shared.writeEvent(
			"WindowBoundsCompare",
			[
				("Reads", "\(comparison.reads)"),
				("Unreadable", "\(comparison.unreadable)"),
				("Mismatches", "\(comparison.mismatches)"),
				("MaxDelta", String(format: "%.3f", comparison.maxDelta)),
				("Fractional", "\(comparison.fractional)"),
			]
		)
		comparison = Comparison()
	}
}
