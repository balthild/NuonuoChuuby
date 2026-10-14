import Foundation

public enum CheekSide: Sendable, Equatable {
	case left
	case right
}

/// Where a character's cheeks are, in 512-unit canvas space.
public struct CheekPinchGeometry: Sendable, Equatable {
	/// The rig comes from the upstream renderer, which is authored against the
	/// shipped sprite's own pixels (384 px) rather than the canvas, so its
	/// anchors are scaled up here.
	private static let spritePixelToCanvas =
		SpriteGeometry.canvasSize / SpriteGeometry.runtimeFrameSize

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
				leftX: 133 * spritePixelToCanvas,
				rightX: 244 * spritePixelToCanvas,
				cheekY: 239 * spritePixelToCanvas,
				hitRadiusX: 25 * spritePixelToCanvas,
				hitRadiusY: 18 * spritePixelToCanvas,
				mouthX: 191 * spritePixelToCanvas,
				mouthY: 241 * spritePixelToCanvas
			)
			: CheekPinchGeometry(
				leftX: 122 * spritePixelToCanvas,
				rightX: 239 * spritePixelToCanvas,
				cheekY: 232 * spritePixelToCanvas,
				hitRadiusX: 25 * spritePixelToCanvas,
				hitRadiusY: 18 * spritePixelToCanvas,
				mouthX: 178 * spritePixelToCanvas,
				mouthY: 227 * spritePixelToCanvas
			)
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

	/// The pull's outward component, in canvas units: never negative, and zero
	/// for any pull that crosses the face the other way.
	private var outward: Double {
		side == .left ? max(-x, 0) : max(x, 0)
	}

	/// How far outwards the cheek is pulled, 0…1.
	public var outwardTension: Double {
		(outward / Self.maximumHorizontal).clamp(lower: 0, upper: 1)
	}

	/// The horizontal offset the renderer draws with: outwards only, so an
	/// inward pull cannot drag the cheek across the face.
	public var outwardOffset: Double {
		side == .left ? -outward : outward
	}

	/// The overall stretch, 0…1. Only an outward pull counts: dragging inwards
	/// across the face contributes no tension at all.
	public var tension: Double {
		let horizontal = outward / Self.maximumHorizontal
		let vertical = y / Self.maximumVertical
		return (horizontal * horizontal + vertical * vertical).squareRoot().clamp(lower: 0, upper: 1)
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
