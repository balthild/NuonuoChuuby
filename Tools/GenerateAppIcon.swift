// Draws the app icon from source, so no binary artwork is committed.
//
//   swift Tools/GenerateAppIcon.swift <output-iconset-directory>
//
// Writes the ten PNGs `iconutil` expects. The design is deliberately generic —
// a paw print — because the character artwork has no redistribution grant and
// the icon ships inside the bundle.
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
	fatalError("usage: GenerateAppIcon.swift <iconset-directory>")
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Sizes required by `iconutil`, as (filename, pixels).
let variants: [(name: String, pixels: Int)] = [
	("icon_16x16", 16), ("icon_16x16@2x", 32),
	("icon_32x32", 32), ("icon_32x32@2x", 64),
	("icon_128x128", 128), ("icon_128x128@2x", 256),
	("icon_256x256", 256), ("icon_256x256@2x", 512),
	("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func drawIcon(pixels: Int) -> CGImage? {
	let size = Double(pixels)
	guard
		let context = CGContext(
			data: nil,
			width: pixels,
			height: pixels,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		)
	else { return nil }

	context.setAllowsAntialiasing(true)
	context.interpolationQuality = .high

	// Rounded square with a soft warm gradient.
	let inset = size * 0.08
	let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
	let corner = body.width * 0.22
	let path = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)
	context.saveGState()
	context.addPath(path)
	context.clip()
	let gradient = CGGradient(
		colorsSpace: CGColorSpaceCreateDeviceRGB(),
		colors: [
			CGColor(red: 0.99, green: 0.93, blue: 0.90, alpha: 1),
			CGColor(red: 0.93, green: 0.62, blue: 0.60, alpha: 1),
		] as CFArray,
		locations: [0, 1]
	)
	if let gradient {
		context.drawLinearGradient(
			gradient,
			start: CGPoint(x: body.minX, y: body.maxY),
			end: CGPoint(x: body.maxX, y: body.minY),
			options: []
		)
	}
	context.restoreGState()

	// Paw print: a wide pad with four toes above it.
	let paw = CGColor(red: 0.32, green: 0.19, blue: 0.22, alpha: 0.92)
	context.setFillColor(paw)

	/// The icon is drawn in a bottom-left origin, so "above" is larger y.
	func ellipse(centerX: Double, centerY: Double, radiusX: Double, radiusY: Double) {
		context.fillEllipse(
			in: CGRect(
				x: size * centerX - size * radiusX,
				y: size * centerY - size * radiusY,
				width: size * radiusX * 2,
				height: size * radiusY * 2
			)
		)
	}

	// Main pad.
	ellipse(centerX: 0.50, centerY: 0.38, radiusX: 0.20, radiusY: 0.165)
	// Toes.
	ellipse(centerX: 0.30, centerY: 0.62, radiusX: 0.088, radiusY: 0.108)
	ellipse(centerX: 0.43, centerY: 0.72, radiusX: 0.088, radiusY: 0.108)
	ellipse(centerX: 0.57, centerY: 0.72, radiusX: 0.088, radiusY: 0.108)
	ellipse(centerX: 0.70, centerY: 0.62, radiusX: 0.088, radiusY: 0.108)

	return context.makeImage()
}

for variant in variants {
	guard let image = drawIcon(pixels: variant.pixels) else {
		fatalError("cannot draw \(variant.name)")
	}
	let url = outputDirectory.appendingPathComponent("\(variant.name).png")
	guard
		let destination = CGImageDestinationCreateWithURL(
			url as CFURL,
			"public.png" as CFString,
			1,
			nil
		)
	else { fatalError("cannot write \(url.path)") }
	CGImageDestinationAddImage(destination, image, nil)
	guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(url.path)") }
}

print("Wrote \(variants.count) icon images to \(outputDirectory.path)")
