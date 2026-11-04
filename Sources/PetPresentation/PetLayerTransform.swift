import QuartzCore

/// How the pet is placed inside her layer: the lean, and the mirror.
enum PetLayerTransform {
	/// Mirroring is applied **after** the lean: the lean is a rotation about her foot,
	/// and mirroring that afterwards is what puts a pulled cheek's lean on the same
	/// side of the screen as the pointer.
	///
	static func make(lean: Double, facing: Double) -> CATransform3D {
		let rotate = CATransform3DMakeRotation(CGFloat(lean) * .pi / 180, 0, 0, 1)
		guard facing < 0 else { return rotate }
		return CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), rotate)
	}
}
