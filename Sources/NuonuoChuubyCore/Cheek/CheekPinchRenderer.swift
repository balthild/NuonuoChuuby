import CoreGraphics
import Foundation

/// Draws the pinched cheek over the pet's resting frame.
public enum CheekPinchRenderer {
	public static func render(
		base: CGImage,
		geometry: CheekPinchGeometry,
		dynamics: CheekPinchDynamics
	) -> CGImage? {
		guard dynamics.isActive else { return base }

		let size = SpriteGeometry.runtimeFrameSize
		let pixel = Int(size)
		guard
			let context = CGContext(
				data: nil,
				width: pixel,
				height: pixel,
				bitsPerComponent: 8,
				bytesPerRow: 0,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else { return base }

		let frame = CGRect(x: 0, y: 0, width: size, height: size)
		context.interpolationQuality = .high
		// `draw(_:in:)` maps the image's bottom-left origin onto the rect, so the
		// base has to go in before the flip below — under the flipped CTM it would
		// land upside down.
		context.draw(base, in: frame)

		// Canvas space is top-left, Y down; flip so the anchors can be used as-is.
		context.translateBy(x: 0, y: size)
		context.scaleBy(x: 1, y: -1)

		let scale = SpriteGeometry.canvasToRuntime
		let restCheek = CGPoint(
			x: geometry.x(for: dynamics.side) * scale,
			y: geometry.cheekY * scale
		)
		let skin =
			sampleColor(base, at: restCheek) ?? CGColor(red: 0.98, green: 0.90, blue: 0.89, alpha: 1)

		// A pull that builds no tension — dragging inwards, say — draws nothing at
		// all, rather than a cheek at rest.
		if dynamics.tension > 0.001 {
			drawStretchedCheek(
				in: context,
				geometry: geometry,
				dynamics: dynamics,
				scale: scale,
				skin: skin
			)
			drawBlush(in: context, geometry: geometry, dynamics: dynamics, scale: scale)

			if dynamics.tension > 0.45 {
				drawMouth(
					in: context,
					geometry: geometry,
					dynamics: dynamics,
					scale: scale,
					skin: skin
				)
			}
		}

		return context.makeImage() ?? base
	}

	private static func drawStretchedCheek(
		in context: CGContext,
		geometry: CheekPinchGeometry,
		dynamics: CheekPinchDynamics,
		scale: Double,
		skin: CGColor
	) {
		let restX = geometry.x(for: dynamics.side)
		let center = CGPoint(
			x: (restX + dynamics.outwardOffset) * scale,
			y: (geometry.cheekY + dynamics.y) * scale
		)

		let stretch = 1 + dynamics.tension * 0.45
		let radiusX = geometry.hitRadiusX * scale * stretch
		let radiusY = geometry.hitRadiusY * scale * (1 + dynamics.tension * 0.12)

		context.saveGState()
		context.setFillColor(skin)
		context.fillEllipse(
			in: CGRect(
				x: center.x - radiusX,
				y: center.y - radiusY,
				width: radiusX * 2,
				height: radiusY * 2
			)
		)

		context.setStrokeColor(inkColor(from: skin))
		context.setLineWidth(1.1)
		context.strokeEllipse(
			in: CGRect(
				x: center.x - radiusX,
				y: center.y - radiusY,
				width: radiusX * 2,
				height: radiusY * 2
			)
		)
		context.restoreGState()
	}

	private static func drawBlush(
		in context: CGContext,
		geometry: CheekPinchGeometry,
		dynamics: CheekPinchDynamics,
		scale: Double
	) {
		guard dynamics.tension > 0.05 else { return }
		let center = CGPoint(
			x: (geometry.x(for: dynamics.side) + dynamics.outwardOffset * 0.8) * scale,
			y: (geometry.cheekY + dynamics.y * 0.8) * scale
		)
		let radius = geometry.hitRadiusX * scale * (0.62 + dynamics.tension * 0.2)

		context.saveGState()
		context.setFillColor(
			CGColor(red: 0.96, green: 0.55, blue: 0.58, alpha: 0.22 + dynamics.tension * 0.28)
		)
		context.fillEllipse(
			in: CGRect(
				x: center.x - radius,
				y: center.y - radius * 0.7,
				width: radius * 2,
				height: radius * 1.4
			)
		)
		context.restoreGState()
	}

	private static func drawMouth(
		in context: CGContext,
		geometry: CheekPinchGeometry,
		dynamics: CheekPinchDynamics,
		scale: Double,
		skin: CGColor
	) {
		let tension = dynamics.tension
		let direction = dynamics.side == .left ? -1.0 : 1.0
		let origin = CGPoint(x: geometry.mouthX * scale, y: geometry.mouthY * scale)

		// Radii are in runtime-frame pixels, matching the upstream rig's own units.
		let radiusX = 4.5 + 2 * tension
		let radiusY = 2.5 + 2.4 * tension + 3.5 * dynamics.nibble
		let center = CGPoint(x: origin.x + direction * 5 * tension, y: origin.y + 1)

		context.saveGState()
		// Upstream erases the cel's own mouth before drawing the stretched one;
		// without this the smaller ellipse leaves the artwork's mouth showing.
		context.setFillColor(skin)
		context.fillEllipse(in: CGRect(x: origin.x - 8, y: origin.y - 6, width: 16, height: 12))

		context.setFillColor(CGColor(red: 0.35, green: 0.14, blue: 0.18, alpha: 1))
		context.fillEllipse(
			in: CGRect(
				x: center.x - radiusX,
				y: center.y - radiusY,
				width: radiusX * 2,
				height: radiusY * 2
			)
		)

		let tongueRadiusY = max(1, radiusY * 0.35)
		context.setFillColor(CGColor(red: 0.94, green: 0.55, blue: 0.60, alpha: 1))
		context.fillEllipse(
			in: CGRect(
				x: center.x - 3,
				y: center.y + radiusY * 0.38 - tongueRadiusY,
				width: 6,
				height: tongueRadiusY * 2
			)
		)

		if dynamics.nibble > 0.15 {
			context.setFillColor(CGColor(red: 1, green: 0.98, blue: 0.93, alpha: 1))
			context.fill(
				CGRect(x: center.x - 3, y: center.y - radiusY + 1, width: 6, height: 2)
			)
		}
		context.restoreGState()
	}

	/// The pixel colour of the base image at a point, or nil if it is transparent
	/// there (the cheek anchor can sit outside the silhouette mid-pull).
	static func sampleColor(_ image: CGImage, at point: CGPoint) -> CGColor? {
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

	static func inkColor(from color: CGColor) -> CGColor {
		let components = color.components ?? [0.5, 0.4, 0.4, 1]
		return CGColor(
			red: (components[0] * 0.62).clamp(lower: 0, upper: 1),
			green: (components[1] * 0.55).clamp(lower: 0, upper: 1),
			blue: (components[2] * 0.58).clamp(lower: 0, upper: 1),
			alpha: 0.85
		)
	}
}
