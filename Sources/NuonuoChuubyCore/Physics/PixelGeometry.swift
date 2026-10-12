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

	public var left: Double { x }
	public var top: Double { y }
	public var right: Double { x + width }
	public var bottom: Double { y + height }
	public var centerX: Double { x + width / 2 }
	public var centerY: Double { y + height / 2 }
}
