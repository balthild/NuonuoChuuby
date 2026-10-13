import Foundation

/// A point in physical desktop pixels (top-left origin, Y down).
public struct PixelPoint: Sendable, Equatable, Hashable {
	public var x: Double
	public var y: Double

	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}

	public static let zero = PixelPoint(x: 0, y: 0)

	public func distance(to other: PixelPoint) -> Double {
		let dx = other.x - x
		let dy = other.y - y
		return (dx * dx + dy * dy).squareRoot()
	}
}

public struct PixelRect: Sendable, Equatable {
	public var x: Double
	public var y: Double
	public var width: Double
	public var height: Double

	public init(x: Double, y: Double, width: Double, height: Double) {
		self.x = x
		self.y = y
		self.width = width
		self.height = height
	}

	public static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

	public var left: Double { x }
	public var top: Double { y }
	public var right: Double { x + width }
	public var bottom: Double { y + height }
	public var centerX: Double { x + width / 2 }
	public var centerY: Double { y + height / 2 }

	/// A rectangle shrunk by `amount` on every side. May come out inside-out, in
	/// which case ``contains(_:)`` is false for everything — which is the right
	/// answer for a container that is too small.
	public func insetBy(_ amount: Double) -> PixelRect {
		PixelRect(x: x + amount, y: y + amount, width: width - 2 * amount, height: height - 2 * amount)
	}

	public func contains(_ other: PixelRect) -> Bool {
		other.left >= left && other.right <= right && other.top >= top && other.bottom <= bottom
	}
}
