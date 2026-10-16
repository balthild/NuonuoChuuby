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
			.icons([
				DesktopIcon(name: "b", position: PixelPoint(x: 10, y: 20), size: 64),
				DesktopIcon(name: "a", position: PixelPoint(x: 5, y: 5), size: 56),
			])
		})
		index.refresh()

		#expect(index.isAvailable)
		#expect(index.icon(of: "a")?.position == PixelPoint(x: 5, y: 5))
		#expect(index.icon(of: "b")?.position == PixelPoint(x: 10, y: 20))
		#expect(index.icon(of: "missing") == nil)
		// The size Finder reported is kept, so a ghost can match the real icon.
		#expect(index.icon(of: "a")?.size == 56)
		// Ordered by (y, x), so a random pick from `positions` is reproducible.
		#expect(index.positions == [PixelPoint(x: 5, y: 5), PixelPoint(x: 10, y: 20)])
	}

	@Test("An unreadable source yields nothing, so the caller falls back")
	func unreadable() {
		let index = DesktopIconIndex(reader: { .unavailable(.finderNotRunning) })
		index.refresh()

		#expect(!index.isAvailable)
		#expect(index.positions.isEmpty)
	}

	@Test("A later reading replaces the previous one")
	func refreshReplaces() {
		var icons = [DesktopIcon(name: "a", position: PixelPoint(x: 1, y: 1), size: 56)]
		let index = DesktopIconIndex(reader: { .icons(icons) })
		index.refresh()
		#expect(index.icon(of: "a") != nil)

		// The icon is deleted, so the next reading does not see it.
		icons = []
		index.refresh()
		#expect(index.icon(of: "a") == nil)
		#expect(!index.isAvailable)
	}

	@Test("A deletion is read from the live tree, not only from the index")
	func deletionReadsTheLiveTree() {
		var read = [DesktopIcon(name: "kept", position: PixelPoint(x: 1, y: 1), size: 56)]
		let index = DesktopIconIndex(reader: { .icons(read) })
		index.refresh()

		// A folder created, and deleted, since the last refresh: the index never
		// held it, so a deletion of it must not fall back to the cursor.
		read = [DesktopIcon(name: "fresh", position: PixelPoint(x: 700, y: 400), size: 56)]
		#expect(index.icon(of: "fresh") == nil)

		let deleted = index.iconsForDeletion(of: ["fresh"])
		#expect(deleted["fresh"]?.position == PixelPoint(x: 700, y: 400))
		#expect(deleted["fresh"]?.size == 56)

		// The eaten icon is dropped from the cache, so it is not offered as a
		// spot to walk over to and lick while the element is still in Finder's
		// tree.
		#expect(!index.positions.contains(PixelPoint(x: 700, y: 400)))
		#expect(index.icon(of: "fresh") == nil)
	}

	@Test("A batch of deletions costs one read")
	func batchIsOneRead() {
		var reads = 0
		let index = DesktopIconIndex(reader: {
			reads += 1
			return .icons([DesktopIcon(name: "a", position: PixelPoint(x: 1, y: 1), size: 56)])
		})
		index.refresh()

		reads = 0
		_ = index.iconsForDeletion(of: ["a", "b", "c", "d", "e"])
		#expect(reads == 1)
	}

	@Test("A failed read falls back to the snapshot for this call and empties the cache")
	func deletionFallsBackToTheIndex() {
		var read: IconReading = .icons([
			DesktopIcon(name: "a", position: PixelPoint(x: 2, y: 3), size: 64),
			// A second icon, so "the cache was emptied" and "the eaten name was
			// dropped" cannot produce the same dictionary.
			DesktopIcon(name: "kept", position: PixelPoint(x: 9, y: 9), size: 56),
		])
		let index = DesktopIconIndex(reader: { read })
		index.refresh()

		// Accessibility lost, or Finder gone: the live read answers nothing. The
		// icon's last known position still answers this deletion, so she walks to
		// it rather than to the cursor...
		read = .unavailable(.accessibilityNotTrusted)
		#expect(index.icon(of: "a") != nil)
		#expect(index.iconsForDeletion(of: ["a"])["a"]?.position == PixelPoint(x: 2, y: 3))

		// ...but the snapshot is not kept alive to do so: the cache always says
		// what the last read said, and a failed read says nothing.
		#expect(index.icons.isEmpty)
		#expect(index.icon(of: "kept") == nil)

		let empty = DesktopIconIndex(reader: { .unavailable(.noIconContainer) })
		empty.refresh()
		#expect(empty.iconsForDeletion(of: ["a"])["a"] == nil)
	}

	@Test("The real reader is safe to call whatever the permission state")
	func realReaderDoesNotTrap() {
		_ = DesktopIconIndex.readDesktopIcons()
	}

	@Test("A reading whose names carry hidden extensions is reported as a miss")
	func hiddenExtensionIsAMiss() {
		// Finder reports the file's name; the desktop hides the extension. If the
		// two ever disagree, the lookup misses and the ghost falls back — the count
		// of prefix matches is what makes that visible.
		let index = DesktopIconIndex(reader: {
			.icons([DesktopIcon(name: "report.txt", position: PixelPoint(x: 4, y: 5), size: 56)])
		})
		index.refresh()

		#expect(index.iconsForDeletion(of: ["report"])["report"] == nil)
		#expect(index.iconsForDeletion(of: ["report.txt"])["report.txt"] != nil)
	}
}
