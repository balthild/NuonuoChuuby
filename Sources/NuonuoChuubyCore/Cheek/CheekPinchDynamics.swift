import Foundation

public enum CheekSide: Sendable, Equatable {
	case left
	case right
}

/// Where a character's cheeks are, in 512-unit canvas space.
public struct CheekPinchGeometry: Sendable, Equatable {
	public var leftX: Double
	public var rightX: Double
	public var cheekY: Double
	public var hitRadiusX: Double
	public var hitRadiusY: Double
	public var mouthX: Double
	public var mouthY: Double

	public static func geometry(for character: PetCharacterProfile) -> CheekPinchGeometry {
		character.usesMischief
			? CheekPinchGeometry(
				leftX: 133, rightX: 244, cheekY: 239, hitRadiusX: 25, hitRadiusY: 18,
				mouthX: 191, mouthY: 241)
			: CheekPinchGeometry(
				leftX: 122, rightX: 239, cheekY: 232, hitRadiusX: 25, hitRadiusY: 18,
				mouthX: 178, mouthY: 227)
	}

	/// The cheek under a canvas-space point, if any.
	public func hitTest(x: Double, y: Double) -> CheekSide? {
		guard x.isFinite, y.isFinite else { return nil }
		let left = pow((x - leftX) / hitRadiusX, 2) + pow((y - cheekY) / hitRadiusY, 2)
		let right = pow((x - rightX) / hitRadiusX, 2) + pow((y - cheekY) / hitRadiusY, 2)
		if left > 1 && right > 1 { return nil }
		return left <= right ? .left : .right
	}

	public func x(for side: CheekSide) -> Double {
		side == .left ? leftX : rightX
	}
}

/// The spring that lets a cheek be pulled out and snaps back.
public struct CheekPinchDynamics: Sendable {
	public static let maximumHorizontal: Double = 105
	public static let maximumVertical: Double = 42

	private var velocityX: Double = 0
	private var velocityY: Double = 0
	private var nibbleSeconds: Double = 0
	private var nibbleValue: Double = 0

	public private(set) var isActive = false
	public private(set) var isHeld = false
	public private(set) var side: CheekSide = .left
	/// The cheek's current offset from its rest position, in canvas units.
	public private(set) var x: Double = 0
	public private(set) var y: Double = 0
	public private(set) var targetX: Double = 0
	public private(set) var targetY: Double = 0

	public init() {}

	/// How far outwards the cheek is pulled, 0…1.
	public var outwardTension: Double {
		min(max((side == .left ? -x : x) / Self.maximumHorizontal, 0), 1)
	}

	/// The overall stretch, 0…1 across both axes.
	public var tension: Double {
		min(
			max(
				((x * x) / (Self.maximumHorizontal * Self.maximumHorizontal)
					+ (y * y) / (Self.maximumVertical * Self.maximumVertical)).squareRoot(),
				0), 1)
	}

	/// The chewing wobble when a cheek is pulled out hard.
	public var nibble: Double { nibbleValue }

	public mutating func begin(side: CheekSide) {
		isActive = true
		isHeld = true
		self.side = side
		x = 0
		y = 0
		targetX = 0
		targetY = 0
		velocityX = 0
		velocityY = 0
		nibbleSeconds = 0
		nibbleValue = 0
	}

	/// Called with the drag's offset from where the pinch started.
	public mutating func drag(x: Double, y: Double) {
		guard isHeld, x.isFinite, y.isFinite else { return }
		targetX = min(max(x, -Self.maximumHorizontal), Self.maximumHorizontal)
		targetY = min(max(y, -Self.maximumVertical), Self.maximumVertical)
	}

	public mutating func release() {
		guard isHeld else { return }
		isHeld = false
		targetX = 0
		targetY = 0
	}

	public mutating func reset() {
		isActive = false
		isHeld = false
		x = 0
		y = 0
		targetX = 0
		targetY = 0
		velocityX = 0
		velocityY = 0
		nibbleSeconds = 0
		nibbleValue = 0
	}

	public mutating func tick(_ delta: Double) {
		guard isActive, delta.isFinite else { return }
		let delta = min(max(delta, 0), 0.05)
		let omega = isHeld ? 20.0 : 17.0
		let damping = isHeld ? 1.0 : 0.70

		// Substeps keep the rebound stable even after a missed render frame.
		let steps = max(1, Int((delta / 0.012).rounded(.up)))
		let step = delta / Double(steps)
		for _ in 0..<steps {
			velocityX += (omega * omega * (targetX - x) - 2 * damping * omega * velocityX) * step
			velocityY += (omega * omega * (targetY - y) - 2 * damping * omega * velocityY) * step
			x += velocityX * step
			y += velocityY * step
		}

		nibbleSeconds = isHeld && outwardTension > 0.85 ? nibbleSeconds + delta : 0
		let nibbleTarget =
			nibbleSeconds > 0.28
			? 0.55 + 0.45 * sin((nibbleSeconds - 0.28) * .pi * 7)
			: 0
		nibbleValue += (nibbleTarget - nibbleValue) * (1 - exp(-22 * delta))

		if !isHeld, abs(x) < 0.2, abs(y) < 0.2, abs(velocityX) < 1, abs(velocityY) < 1 {
			reset()
		}
	}
}
