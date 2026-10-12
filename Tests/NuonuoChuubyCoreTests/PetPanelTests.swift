import AppKit
import Testing

@testable import NuonuoChuubyCore

@Suite("Pet panel")
@MainActor
struct PetPanelTests {
	/// Her foot anchor is near the bottom of the panel, so standing on a window
	/// close to the top of the screen needs the panel to hang above the screen.
	/// AppKit's default constraint pulled it back to the visible frame, which left
	/// her drawn ~130 pt below the simulation position — floating in mid-air.
	@Test("The panel may be placed off the screen edges")
	func notConstrained() {
		let panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 132, height: 132))
		let proposed = NSRect(x: -40, y: 1100, width: 132, height: 132)
		let constrained = panel.constrainFrameRect(proposed, to: NSScreen.main)
		#expect(constrained == proposed)
	}
}
