import Foundation

/// The sprite art is authored on a fixed 512-unit logical canvas; the shipped
/// PNGs are 384 px square. Anchors are stored in canvas units so they survive a
/// change of runtime frame size.
public enum SpriteGeometry {
	public static let canvasSize: Double = 512
	public static let runtimeFrameSize: Double = 384
	public static let runtimeFootBaseline: Double = 374
	public static let footCanvasX: Double = canvasSize / 2
	public static let footCanvasY: Double = runtimeFootBaseline / runtimeFrameSize * canvasSize

	/// Converts a canvas-unit length to runtime frame pixels.
	public static let canvasToRuntime: Double = runtimeFrameSize / canvasSize
}
