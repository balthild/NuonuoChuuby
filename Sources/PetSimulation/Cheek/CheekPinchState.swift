import Foundation

/// The cheek-pinch overlay's appearance for one frame: the rig plus the spring's
/// current pose.
///
/// The controller hands this to its presenter instead of a flattened bitmap, so
/// each presenter can draw the pinch the way it draws the pet — the full-display
/// overlay as vector sublayers, the moving panel by compositing it onto the cel.
public struct CheekPinchState: Sendable {
	public let geometry: CheekPinchGeometry
	public let dynamics: CheekPinchDynamics
}
