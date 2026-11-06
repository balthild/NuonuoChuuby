import AppKit
import Testing

@testable import PetPresentation

@Suite("Pet chrome panel")
@MainActor
struct PetChromePanelTests {
	/// Her foot anchor is near the bottom of her square, so standing on a window
	/// close to the top of the screen needs the window to hang above the screen — and
	/// the overlay has to reach the menu bar strip too. AppKit's default constraint
	/// pulls a window back into the screen's visible frame, which would leave her
	/// drawn below the simulation position and stop the overlay covering the strip.
	@Test("The window may be placed off the screen edges")
	func notConstrained() {
		let frame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
		let panel = PetChromePanel(contentRect: frame)
		let proposed = NSRect(x: -40, y: 1100, width: 1728, height: 1117)
		#expect(panel.constrainFrameRect(proposed, to: NSScreen.main) == proposed)
	}

	/// The pet is stacked above the menu bar (24) and the Dock (20) so neither can
	/// occlude her, and below open menus (101). It must stay above 0 because
	/// `FullscreenDetector` matches any level-0 window filling a display and does not
	/// exclude our own process, so a level-0 overlay would suspend her against itself.
	@Test("The pet clears the menu bar and the Dock, and stays above level 0")
	func stackingLevel() {
		#expect(PetChromePanel(contentRect: .zero).level == PetChromePanel.petPanelLevel)
		#expect(PetChromePanel.petPanelLevel.rawValue == NSWindow.Level.mainMenu.rawValue + 1)
		#expect(PetChromePanel.petPanelLevel.rawValue > 20)
		#expect(PetChromePanel.petPanelLevel.rawValue > 0)
		#expect(PetChromePanel.petPanelLevel.rawValue < NSWindow.Level.popUpMenu.rawValue)
	}

	/// A ghost icon is a window of its own and is drawn over her, because she is the one
	/// eating it. The gap is what holds that: at her own level it would fall behind her
	/// window as soon as that window was placed again, which during a meal is every frame.
	@Test("A ghost icon stacks above the pet, and stays under open menus")
	func ghostLevel() {
		let ghost = PetChromePanel(
			contentRect: .zero,
			ignoresMouseEvents: true,
			level: PetChromePanel.ghostPanelLevel
		)
		#expect(ghost.level == PetChromePanel.ghostPanelLevel)
		#expect(PetChromePanel.ghostPanelLevel.rawValue > PetChromePanel.petPanelLevel.rawValue)
		#expect(PetChromePanel.ghostPanelLevel.rawValue < NSWindow.Level.popUpMenu.rawValue)
	}
}
