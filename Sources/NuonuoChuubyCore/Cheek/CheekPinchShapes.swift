import CoreGraphics
import Foundation

/// The shapes the cheek-pinch overlay draws, in the pet's own point space
/// (top-left origin, Y down) — the space the sprite is drawn in.
///
/// This is `CheekPinchRenderer`'s sequence of Core Graphics calls restated as
/// paths, one shape per call and in the same order, so the layer overlay and the
/// bitmap composite are the same picture. The only conversion is the rig's
/// runtime-frame pixels into the pet layer's points; every literal stays in the
/// rig's own units.
enum CheekPinchShapes {
	/// What a shape is painted with.
	///
	/// The cheek's skin is sampled from the sprite rather than fixed, so it is a
	/// case here and resolved to a colour by whoever has the frame.
	enum Paint {
		case skin
		case ink
		case blush(alpha: Double)
		case mouth
		case tongue
		case teeth
	}

	struct Shape {
		var path: CGPath
		var fill: Paint
		var stroke: Paint?
		var lineWidth: Double

		init(path: CGPath, fill: Paint, stroke: Paint? = nil, lineWidth: Double = 0) {
			self.path = path
			self.fill = fill
			self.stroke = stroke
			self.lineWidth = lineWidth
		}
	}

	struct Shapes {
		var cheek: Shape?
		var blush: Shape?
		var mouthCover: Shape?
		var mouth: Shape?
		var tongue: Shape?
		var teeth: Shape?

		/// In draw order, back to front.
		var inOrder: [Shape] {
			[cheek, blush, mouthCover, mouth, tongue, teeth].compactMap { $0 }
		}

		var isEmpty: Bool { inOrder.isEmpty }
	}

	static func shapes(state: CheekPinchState, pointsPerPixel: Double) -> Shapes {
		let dynamics = state.dynamics
		let geometry = state.geometry
		let scale = SpriteGeometry.canvasToRuntime

		func px(_ value: Double) -> Double { value * pointsPerPixel }
		func ellipse(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGPath {
			CGPath(
				ellipseIn: CGRect(
					x: px(x),
					y: px(y),
					width: px(width),
					height: px(height)
				),
				transform: nil
			)
		}

		var shapes = Shapes()

		// A pull that builds no tension — dragging inwards, say — draws nothing at
		// all, rather than a cheek at rest.
		guard dynamics.tension > 0.001 else { return shapes }

		let stretch = 1 + dynamics.tension * 0.45
		let radiusX = geometry.hitRadiusX * scale * stretch
		let radiusY = geometry.hitRadiusY * scale * (1 + dynamics.tension * 0.12)
		let cheekCenterX = (geometry.x(for: dynamics.side) + dynamics.outwardOffset) * scale
		let cheekCenterY = (geometry.cheekY + dynamics.y) * scale
		shapes.cheek = Shape(
			path: ellipse(
				cheekCenterX - radiusX,
				cheekCenterY - radiusY,
				radiusX * 2,
				radiusY * 2
			),
			fill: .skin,
			stroke: .ink,
			lineWidth: px(1.1)
		)

		if dynamics.tension > 0.05 {
			let blushCenterX = (geometry.x(for: dynamics.side) + dynamics.outwardOffset * 0.8) * scale
			let blushCenterY = (geometry.cheekY + dynamics.y * 0.8) * scale
			let radius = geometry.hitRadiusX * scale * (0.62 + dynamics.tension * 0.2)
			shapes.blush = Shape(
				path: ellipse(
					blushCenterX - radius,
					blushCenterY - radius * 0.7,
					radius * 2,
					radius * 1.4
				),
				fill: .blush(alpha: 0.22 + dynamics.tension * 0.28)
			)
		}

		if dynamics.tension > 0.45 {
			let tension = dynamics.tension
			let direction = dynamics.side == .left ? -1.0 : 1.0
			let mouthX = geometry.mouthX * scale
			let mouthY = geometry.mouthY * scale
			// Radii are in runtime-frame pixels, matching the rig's own units.
			let mouthRadiusX = 4.5 + 2 * tension
			let mouthRadiusY = 2.5 + 2.4 * tension + 3.5 * dynamics.nibble
			let centerX = mouthX + direction * 5 * tension
			let centerY = mouthY + 1

			// Upstream erases the cel's own mouth before drawing the stretched one;
			// an opaque skin ellipse over it is that erasure.
			shapes.mouthCover = Shape(
				path: ellipse(mouthX - 8, mouthY - 6, 16, 12),
				fill: .skin
			)
			shapes.mouth = Shape(
				path: ellipse(
					centerX - mouthRadiusX,
					centerY - mouthRadiusY,
					mouthRadiusX * 2,
					mouthRadiusY * 2
				),
				fill: .mouth
			)

			let tongueRadiusY = max(1, mouthRadiusY * 0.35)
			shapes.tongue = Shape(
				path: ellipse(
					centerX - 3,
					centerY + mouthRadiusY * 0.38 - tongueRadiusY,
					6,
					tongueRadiusY * 2
				),
				fill: .tongue
			)

			if dynamics.nibble > 0.15 {
				shapes.teeth = Shape(
					path: CGPath(
						rect: CGRect(
							x: px(centerX - 3),
							y: px(centerY - mouthRadiusY + 1),
							width: px(6),
							height: px(2)
						),
						transform: nil
					),
					fill: .teeth
				)
			}
		}

		return shapes
	}
}
