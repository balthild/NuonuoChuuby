import Foundation

/// What the pet does when it runs out of surface at an edge.
public enum TerrainEdgeAction: Sendable, Equatable {
	case turnAround
	case hop
	case slideDown
	case jumpDown
}

public enum TerrainBehaviorPlanner {
	/// On the desktop floor she mostly just turns around; on a window top she may
	/// instead hop, slide down the side, or jump off.
	public static func chooseAtEdge(isDesktopFloor: Bool, randomUnit: Double) -> TerrainEdgeAction {
		let random = min(max(randomUnit, 0), 0.999999)
		if isDesktopFloor {
			return random < 0.22 ? .hop : .turnAround
		}
		switch random {
		case ..<0.20: return .hop
		case ..<0.34: return .slideDown
		case ..<0.48: return .jumpDown
		default: return .turnAround
		}
	}
}
