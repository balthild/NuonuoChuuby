import CoreGraphics
import Foundation

/// Draws the pinched cheek over the pet's resting frame.
///
/// The original redrew a face rig (cheek patch, eye squint, mouth) over a stable
/// cel. This does the same with the geometry that is actually known: the cheek
/// and mouth anchors. Everything is drawn at the runtime frame size, so the
/// result scales with the pet like any other frame.
public enum CheekPinchRenderer {
	/// Draws `base` with the cheek stretched by `dynamics`.
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
				data: nil, width: pixel, height: pixel, bitsPerComponent: 8, bytesPerRow: 0,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return base }

		// Canvas space is top-left, Y down; flip so the anchors can be used as-is.
		context.translateBy(x: 0, y: size)
		context.scaleBy(x: 1, y: -1)
		context.interpolationQuality = .high

		let frame = CGRect(x: 0, y: 0, width: size, height: size)
		context.draw(base, in: frame)

		let scale = SpriteGeometry.canvasToRuntime
		let restCheek = CGPoint(
			x: geometry.x(for: dynamics.side) * scale, y: geometry.cheekY * scale)
		let skin = sampleColor(base, at: restCheek) ?? CGColor(red: 0.98, green: 0.90, blue: 0.89, alpha: 1)

		drawStretchedCheek(
			in: context, geometry: geometry, dynamics: dynamics, scale: scale, skin: skin)
		drawBlush(in: context, geometry: geometry, dynamics: dynamics, scale: scale)

		// A wide pull opens a small mouth, which is what reads as "she is being
		// pinched" rather than merely bulging.
		if dynamics.tension > 0.45 {
			drawMouth(in: context, geometry: geometry, dynamics: dynamics, scale: scale)
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
			x: (restX + dynamics.x) * scale,
			y: (geometry.cheekY + dynamics.y) * scale)

		// The patch stretches along the pull direction, so the cheek reads as
		// elastic rather than as a circle that moved.
		let stretch = 1 + dynamics.tension * 0.45
		let radiusX = geometry.hitRadiusX * scale * stretch
		let radiusY = geometry.hitRadiusY * scale * (1 + dynamics.tension * 0.12)

		context.saveGState()
		context.setFillColor(skin)
		context.fillEllipse(
			in: CGRect(
				x: center.x - radiusX, y: center.y - radiusY,
				width: radiusX * 2, height: radiusY * 2))

		// A soft outline keeps the patch from dissolving into the face.
		context.setStrokeColor(inkColor(from: skin))
		context.setLineWidth(1.1)
		context.strokeEllipse(
			in: CGRect(
				x: center.x - radiusX, y: center.y - radiusY,
				width: radiusX * 2, height: radiusY * 2))
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
			x: (geometry.x(for: dynamics.side) + dynamics.x * 0.8) * scale,
			y: (geometry.cheekY + dynamics.y * 0.8) * scale)
		let radius = geometry.hitRadiusX * scale * (0.62 + dynamics.tension * 0.2)

		context.saveGState()
		context.setFillColor(
			CGColor(red: 0.96, green: 0.55, blue: 0.58, alpha: 0.22 + dynamics.tension * 0.28))
		context.fillEllipse(
			in: CGRect(
				x: center.x - radius, y: center.y - radius * 0.7,
				width: radius * 2, height: radius * 1.4))
		context.restoreGState()
	}

	private static func drawMouth(
		in context: CGContext,
		geometry: CheekPinchGeometry,
		dynamics: CheekPinchDynamics,
		scale: Double
	) {
		let openness = (dynamics.tension - 0.45) / 0.55
		let center = CGPoint(x: geometry.mouthX * scale, y: geometry.mouthY * scale)
		// The nibble wobble modulates how far the mouth is open.
		let height = (7 + 9 * openness) * (0.75 + dynamics.nibble * 0.5) * scale
		let width = (11 + 5 * openness) * scale

		context.saveGState()
		context.setFillColor(CGColor(red: 0.35, green: 0.14, blue: 0.18, alpha: 1))
		context.fillEllipse(
			in: CGRect(
				x: center.x - width, y: center.y - height,
				width: width * 2, height: height * 2))

		// Tongue, visible only once the mouth is properly open.
		if openness > 0.4 {
			context.setFillColor(CGColor(red: 0.94, green: 0.55, blue: 0.60, alpha: 1))
			context.fillEllipse(
				in: CGRect(
					x: center.x - width * 0.55, y: center.y - height * 0.1,
					width: width * 1.1, height: height * 1.0))
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
				data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))

		let alpha = Double(pixel[3]) / 255
		guard alpha > 0.2 else { return nil }
		return CGColor(
			red: Double(pixel[0]) / 255 / alpha,
			green: Double(pixel[1]) / 255 / alpha,
			blue: Double(pixel[2]) / 255 / alpha,
			alpha: 1)
	}

	private static func inkColor(from color: CGColor) -> CGColor {
		let components = color.components ?? [0.5, 0.4, 0.4, 1]
		return CGColor(
			red: (components[0] * 0.62).clamped01(),
			green: (components[1] * 0.55).clamped01(),
			blue: (components[2] * 0.58).clamped01(),
			alpha: 0.85)
	}
}

extension Double {
	func clamped01() -> Double { min(max(self, 0), 1) }
}
