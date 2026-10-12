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

	/// The menu bar is composited above every ordinary window level, so the panel
	/// has to rise above it while it reaches into it — and only then, or she
	/// would cover the Dock too.
	@Test("The panel rises above the menu bar only while it overlaps it")
	func levelAboveMenuBar() {
		let workArea = PixelRect(x: 0, y: 24, width: 1440, height: 876)
		#expect(PetPanelLevel.level(panelTop: 10, workArea: workArea) == PetPanelLevel.aboveMenuBar)
		#expect(PetPanelLevel.level(panelTop: 24, workArea: workArea) == .floating)
		#expect(PetPanelLevel.level(panelTop: 400, workArea: workArea) == .floating)
	}
}
