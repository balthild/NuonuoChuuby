import AppKit
import QuartzCore

/// The pulled cheek drawn as vector sublayers of the pet's layer, instead of
/// being composited into a copy of the sprite's bitmap.
///
/// Compositing repainted a 384×384 image every frame the spring moved, which is a
/// full CPU allocation and resample per frame — the cost the full-display overlay
/// exists to avoid. The overlay is three to six small ellipses and a rectangle, so
/// the render server can rasterise them instead.
///
/// It is a sublayer of the pet's own layer, so it inherits the lean and the
/// mirror flip for free.
@MainActor
final class CheekPinchLayer {
	/// Everything the overlay never animates: every shape lands in the frame it
	/// was set in.
	private static let noActions: [String: CAAction] = [
		"bounds": NSNull(),
		"position": NSNull(),
		"path": NSNull(),
		"fillColor": NSNull(),
		"strokeColor": NSNull(),
		"lineWidth": NSNull(),
		"hidden": NSNull(),
		"contentsScale": NSNull(),
	]

	let container = CALayer()

	private let cheek = CheekPinchLayer.makeShape()
	private let blush = CheekPinchLayer.makeShape()
	private let mouthCover = CheekPinchLayer.makeShape()
	private let mouth = CheekPinchLayer.makeShape()
	private let tongue = CheekPinchLayer.makeShape()
	private let teeth = CheekPinchLayer.makeShape()

	private var allShapes: [CAShapeLayer] { [cheek, blush, mouthCover, mouth, tongue, teeth] }

	init() {
		container.actions = Self.noActions
		container.masksToBounds = false
		for shape in allShapes {
			shape.actions = Self.noActions
			container.addSublayer(shape)
		}
		clear()
	}

	/// Sizes the overlay to the pet's square, so the shape coordinates are the
	/// pet's own points.
	func setBounds(_ bounds: CGRect, contentsScale: CGFloat) {
		container.frame = CGRect(origin: .zero, size: bounds.size)
		container.contentsScale = contentsScale
		let shapeFrame = CGRect(origin: .zero, size: bounds.size)
		for shape in allShapes {
			shape.frame = shapeFrame
			shape.contentsScale = contentsScale
		}
	}

	func clear() {
		for shape in allShapes {
			shape.isHidden = true
			shape.path = nil
		}
	}

	/// - Parameter base: the sprite frame the skin colour is sampled from, so the
	///   drawn cheek matches the cel under it.
	func update(state: CheekPinchState, base: CGImage?) {
		let scale = SpriteGeometry.canvasToRuntime
		let restPoint = CGPoint(
			x: state.geometry.x(for: state.dynamics.side) * scale,
			y: state.geometry.cheekY * scale
		)
		let skin =
			base.flatMap { Self.sampleColor($0, at: restPoint) }
			?? CGColor(red: 0.98, green: 0.90, blue: 0.89, alpha: 1)

		let width = Double(container.bounds.width)
		guard width > 0 else { return }
		let pointsPerPixel = width / SpriteGeometry.runtimeFrameSize
		let shapes = CheekPinchShapes.shapes(state: state, pointsPerPixel: pointsPerPixel)

		apply(cheek, shapes.cheek, skin: skin)
		apply(blush, shapes.blush, skin: skin)
		apply(mouthCover, shapes.mouthCover, skin: skin)
		apply(mouth, shapes.mouth, skin: skin)
		apply(tongue, shapes.tongue, skin: skin)
		apply(teeth, shapes.teeth, skin: skin)
	}

	private func apply(_ layer: CAShapeLayer, _ shape: CheekPinchShapes.Shape?, skin: CGColor) {
		guard let shape else {
			layer.isHidden = true
			layer.path = nil
			return
		}
		layer.isHidden = false
		layer.path = shape.path
		layer.fillColor = Self.colour(shape.fill, skin: skin)
		layer.strokeColor = shape.stroke.map { Self.colour($0, skin: skin) }
		layer.lineWidth = CGFloat(shape.lineWidth)
	}

	private static func colour(_ paint: CheekPinchShapes.Paint, skin: CGColor) -> CGColor {
		switch paint {
		case .skin:
			return skin
		case .ink:
			return Self.inkColor(from: skin)
		case .blush(let alpha):
			return CGColor(red: 0.96, green: 0.55, blue: 0.58, alpha: alpha)
		case .mouth:
			return CGColor(red: 0.35, green: 0.14, blue: 0.18, alpha: 1)
		case .tongue:
			return CGColor(red: 0.94, green: 0.55, blue: 0.60, alpha: 1)
		case .teeth:
			return CGColor(red: 1, green: 0.98, blue: 0.93, alpha: 1)
		}
	}

	private static func makeShape() -> CAShapeLayer {
		let layer = CAShapeLayer()
		layer.isHidden = true
		layer.masksToBounds = false
		return layer
	}

	/// The pixel colour of the sprite frame at a point, or nil if it is transparent
	/// there — the cheek anchor can sit outside the silhouette mid-pull.
	private static func sampleColor(_ image: CGImage, at point: CGPoint) -> CGColor? {
		let x = Int(point.x.rounded())
		let y = Int(point.y.rounded())
		guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }

		var pixel = [UInt8](repeating: 0, count: 4)
		guard
			let context = CGContext(
				data: &pixel,
				width: 1,
				height: 1,
				bitsPerComponent: 8,
				bytesPerRow: 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else { return nil }
		context.draw(
			image,
			in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height)
		)

		let alpha = Double(pixel[3]) / 255
		guard alpha > 0.2 else { return nil }
		return CGColor(
			red: Double(pixel[0]) / 255 / alpha,
			green: Double(pixel[1]) / 255 / alpha,
			blue: Double(pixel[2]) / 255 / alpha,
			alpha: 1
		)
	}

	/// The darker outline colour the cheek is stroked with, derived from the skin
	/// it is filled with.
	private static func inkColor(from color: CGColor) -> CGColor {
		let components = color.components ?? [0.5, 0.4, 0.4, 1]
		return CGColor(
			red: (components[0] * 0.62).clamp(lower: 0, upper: 1),
			green: (components[1] * 0.55).clamp(lower: 0, upper: 1),
			blue: (components[2] * 0.58).clamp(lower: 0, upper: 1),
			alpha: 0.85
		)
	}
}
