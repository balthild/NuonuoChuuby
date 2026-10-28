import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width: CGFloat = 600
let height: CGFloat = 400
let scale: CGFloat = 2

guard let path = CommandLine.arguments.dropFirst().first else {
	FileHandle.standardError.write(Data("usage: dmg-background.swift <output.png>\n".utf8))
	exit(1)
}

guard
	let context = CGContext(
		data: nil,
		width: Int(width * scale),
		height: Int(height * scale),
		bitsPerComponent: 8,
		bytesPerRow: 0,
		space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
	)
else {
	preconditionFailure("cannot create a drawing context")
}

// Flip the context so the drawing code can use the same top-left origin as the
// Finder window.
context.scaleBy(x: scale, y: scale)
context.translateBy(x: 0, y: height)
context.scaleBy(x: 1, y: -1)

context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

let ref = CGPoint(x: 280, y: 200)

let main = CGMutablePath()
main.move(to: CGPoint(x: ref.x, y: ref.y - 10))
main.addLine(to: CGPoint(x: ref.x + 10, y: ref.y - 10))
main.addLine(to: CGPoint(x: ref.x + 10, y: ref.y - 30))
main.addLine(to: CGPoint(x: ref.x + 40, y: ref.y))
main.addLine(to: CGPoint(x: ref.x + 10, y: ref.y + 30))
main.addLine(to: CGPoint(x: ref.x + 10, y: ref.y + 10))
main.addLine(to: CGPoint(x: ref.x, y: ref.y + 10))
main.closeSubpath()
context.addPath(main)

let tail = CGMutablePath()
let gap = 3.0
let widths = [7.0, 4.0]
for i in widths.indices {
	let totalWidth = widths[0...i].reduce(0.0, +)
	let totalGap = gap * Double(i + 1)

	tail.addRect(
		.init(
			x: ref.x - totalWidth - totalGap,
			y: ref.y - 10,
			width: widths[i],
			height: 20
		)
	)
}
context.addPath(tail)

context.setFillColor(.init(red: 0.7, green: 0.7, blue: 0.7, alpha: 1))
context.fillPath()

guard let image = context.makeImage() else { preconditionFailure("no image in the context") }

guard
	let destination = CGImageDestinationCreateWithURL(
		URL(fileURLWithPath: path) as CFURL,
		UTType.png.identifier as CFString,
		1,
		nil
	)
else {
	preconditionFailure("cannot write \(path)")
}
let properties =
	[
		kCGImagePropertyDPIWidth: 72 * scale,
		kCGImagePropertyDPIHeight: 72 * scale,
	] as CFDictionary
CGImageDestinationAddImage(destination, image, properties)
guard CGImageDestinationFinalize(destination) else {
	preconditionFailure("cannot finish \(path)")
}
