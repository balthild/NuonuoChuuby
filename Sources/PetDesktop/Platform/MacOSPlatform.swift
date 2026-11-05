import AppKit
import CoreGraphics
import PetFoundation

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
		guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) else { return [] }

		return WindowDescriptionRead.windows(in: list)
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

/// Reads a `CGWindowListCopyWindowInfo` list in place, without bridging it into Swift
/// collections.
///
/// The list is already an array of dictionaries; consuming it the obvious way — `as?
/// [[String: AnyObject]]` and then an `as?` per field — copies every entry into Swift's
/// own collections first, which measured as about half the cost of the enumeration and
/// is gone (see `Docs/Internal/performance.md`). The types asked for here are the ones
/// the server stores — window number, owner PID and layer as `SInt64`, the bounds fields
/// and the alpha as `Float64` — so no read converts anything.
///
/// A field that is missing or of the wrong type drops the window. The
/// `CGRect(dictionaryRepresentation:)` this replaced raised instead when a bounds value
/// was of the wrong type.
@MainActor
private enum WindowDescriptionRead {
	/// Every window in the list, in the order the list gives them.
	///
	/// That order is the z-order, so a window's position in the list is its ``PlatformWindow/zIndex``.
	static func windows(in list: CFArray) -> [PlatformWindow] {
		let count = CFArrayGetCount(list)
		var windows: [PlatformWindow] = []
		windows.reserveCapacity(count)
		for index in 0..<count {
			guard
				let entry = CFArrayGetValueAtIndex(list, index),
				let window = window(from: entry, zIndex: index)
			else { continue }
			windows.append(window)
		}
		return windows
	}

	private static func window(from entry: UnsafeRawPointer, zIndex: Int) -> PlatformWindow? {
		guard let description = dictionary(entry) else { return nil }
		guard
			let number = integer(description, Keys.number),
			let owner = integer(description, Keys.ownerPID),
			let level = integer(description, Keys.layer),
			// `exactly:` where the read used to be an `as?`: a value that does not fit
			// is a window to skip, not one to truncate.
			let id = UInt32(exactly: number),
			let ownerPID = Int32(exactly: owner),
			let layer = Int(exactly: level),
			let bounds = rectangle(CFDictionaryGetValue(description, Keys.bounds))
		else { return nil }

		return PlatformWindow(
			id: id,
			ownerPID: ownerPID,
			bounds: bounds,
			layer: layer,
			alpha: double(description, Keys.alpha) ?? 1,
			zIndex: zIndex
		)
	}

	/// A rectangle out of the bounds dictionary, when all four fields are numbers.
	private static func rectangle(_ value: UnsafeRawPointer?) -> PixelRect? {
		guard let bounds = dictionary(value) else { return nil }
		guard
			let x = double(bounds, Keys.boundsX),
			let y = double(bounds, Keys.boundsY),
			let width = double(bounds, Keys.boundsWidth),
			let height = double(bounds, Keys.boundsHeight)
		else { return nil }
		return PixelRect(x: x, y: y, width: width, height: height)
	}

	private static func integer(_ dict: CFDictionary, _ key: UnsafeRawPointer) -> Int64? {
		guard let value = number(dict, key) else { return nil }
		var result: Int64 = 0
		guard CFNumberGetValue(value, .sInt64Type, &result) else { return nil }
		return result
	}

	private static func double(_ dict: CFDictionary, _ key: UnsafeRawPointer) -> Double? {
		guard let value = number(dict, key) else { return nil }
		var result = 0.0
		guard CFNumberGetValue(value, .doubleType, &result) else { return nil }
		return result
	}

	private static func number(_ dict: CFDictionary, _ key: UnsafeRawPointer) -> CFNumber? {
		guard let value = CFDictionaryGetValue(dict, key),
			CFGetTypeID(object(value)) == CFNumberGetTypeID()
		else { return nil }
		return unsafeBitCast(value, to: CFNumber.self)
	}

	private static func dictionary(_ pointer: UnsafeRawPointer?) -> CFDictionary? {
		guard let pointer, CFGetTypeID(object(pointer)) == CFDictionaryGetTypeID() else { return nil }
		return unsafeBitCast(pointer, to: CFDictionary.self)
	}

	/// A value out of a dictionary, as the object `CFGetTypeID` wants.
	///
	/// `CFDictionaryGetValue` gives back a raw pointer, and the object stays alive as
	/// long as the dictionary that holds it does.
	private static func object(_ pointer: UnsafeRawPointer) -> CFTypeRef {
		unsafeBitCast(pointer, to: CFTypeRef.self)
	}

	/// The keys, taken once: the constants are globals, and each lookup hashes one.
	///
	/// The isolation is what makes holding the bare pointers legal: a nested type does
	/// not inherit it from the enum around it.
	@MainActor
	private enum Keys {
		static let number = pointer(kCGWindowNumber)
		static let ownerPID = pointer(kCGWindowOwnerPID)
		static let layer = pointer(kCGWindowLayer)
		static let bounds = pointer(kCGWindowBounds)
		static let alpha = pointer(kCGWindowAlpha)

		/// `CGRect`'s dictionary-representation names, which is what the server uses.
		static let boundsX = pointer("X" as CFString)
		static let boundsY = pointer("Y" as CFString)
		static let boundsWidth = pointer("Width" as CFString)
		static let boundsHeight = pointer("Height" as CFString)

		private static func pointer(_ value: CFString) -> UnsafeRawPointer {
			UnsafeRawPointer(Unmanaged<CFString>.passUnretained(value).toOpaque())
		}
	}
}
