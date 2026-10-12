import Foundation
import Testing

@testable import NuonuoChuubyCore

/// The index itself is testable without Accessibility, because the read is
/// injected. The real read cannot be: it is cross-process IPC to Finder.
@MainActor
@Suite("Desktop icon index")
struct DesktopIconIndexTests {
	@Test("Icons are keyed by name and ordered stably")
	func indexesByName() {
		let index = DesktopIconIndex(reader: {
			[
				DesktopIcon(name: "b", position: PixelPoint(x: 10, y: 20)),
				DesktopIcon(name: "a", position: PixelPoint(x: 5, y: 5)),
			]
		})
		index.refresh()

		#expect(index.isAvailable)
		#expect(index.position(of: "a") == PixelPoint(x: 5, y: 5))
		#expect(index.position(of: "b") == PixelPoint(x: 10, y: 20))
		#expect(index.position(of: "missing") == nil)
		// Ordered by (y, x), so a random pick from `positions` is reproducible.
		#expect(index.positions == [PixelPoint(x: 5, y: 5), PixelPoint(x: 10, y: 20)])
	}

	@Test("An unreadable source yields nothing, so the caller falls back")
	func unreadable() {
		// Accessibility not granted, or Finder not running.
		let index = DesktopIconIndex(reader: { nil })
		index.refresh()

		#expect(!index.isAvailable)
		#expect(index.positions.isEmpty)
	}

	@Test("A later reading replaces the previous one")
	func refreshReplaces() {
		var icons = [DesktopIcon(name: "a", position: PixelPoint(x: 1, y: 1))]
		let index = DesktopIconIndex(reader: { icons })
		index.refresh()
		#expect(index.position(of: "a") != nil)

		// The icon is deleted, so the next reading does not see it.
		icons = []
		index.refresh()
		#expect(index.position(of: "a") == nil)
		#expect(!index.isAvailable)
	}

	@Test("The real reader is safe to call whatever the permission state")
	func realReaderDoesNotTrap() {
		_ = DesktopIconIndex.readFinderIcons()
	}
}
