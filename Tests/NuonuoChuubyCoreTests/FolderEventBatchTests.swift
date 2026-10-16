import Testing

@testable import NuonuoChuubyCore

/// The flag shapes below are what a real FSEvents stream reports; they were read
/// off a probe (see the notes on ``FolderEventBatch``), not guessed.
@Suite("Folder event batch")
struct FolderEventBatchTests {
	private func entry(
		_ path: String,
		renamed: Bool = false,
		removed: Bool = false,
		created: Bool = false,
		onDisk: Bool
	) -> FolderEventBatch.Entry {
		FolderEventBatch.Entry(
			path: path,
			renamed: renamed,
			removed: removed,
			created: created,
			isOnDisk: onDisk
		)
	}

	private func deleted(_ entries: [FolderEventBatch.Entry]) -> [String] {
		FolderEventBatch.outcome(of: entries).deleted
	}

	@Test("A file that has appeared is reported as such")
	func createdFileAppears() {
		// Finder writes a new file: created, and on disk when the event arrives.
		let outcome = FolderEventBatch.outcome(of: [
			entry("/d/a.txt", created: true, onDisk: true)
		])
		#expect(outcome.appeared == ["/d/a.txt"])
		#expect(outcome.deleted.isEmpty)
	}

	@Test("A move to the Trash is not an appearance")
	func trashMoveIsNotAnAppearance() {
		// The trap: a move to the Trash arrives as renaming *and* creating, with the
		// path already gone. Only disk presence tells the two apart, which is the
		// same fact the deletion rules turn on.
		let outcome = FolderEventBatch.outcome(of: [
			entry("/d/a.txt", renamed: true, created: true, onDisk: false)
		])
		#expect(outcome.appeared.isEmpty)
		#expect(outcome.deleted == ["/d/a.txt"])
	}

	@Test("An unlink is not an appearance, even though it is a creation of nothing")
	func unlinkIsNotAnAppearance() {
		let outcome = FolderEventBatch.outcome(of: [
			entry("/d/a.txt", removed: true, created: false, onDisk: false)
		])
		#expect(outcome.appeared.isEmpty)
		#expect(outcome.deleted == ["/d/a.txt"])
	}

	@Test("Renaming a file within the folder deletes nothing")
	func renamePairIsNotADeletion() {
		// mv a.txt b.txt: both paths arrive together and the destination is live.
		let outcome = FolderEventBatch.outcome(of: [
			entry("/d/a.txt", renamed: true, onDisk: false),
			entry("/d/b.txt", renamed: true, onDisk: true),
		])
		#expect(outcome.deleted.isEmpty)
		// The ignored rename is reported, so the log can say why she did not move.
		#expect(outcome.renamed == ["/d/a.txt"])
	}

	@Test("A rename into a subfolder deletes nothing")
	func renameIntoSubfolderIsNotADeletion() {
		// The item is still in the watched tree, one level down.
		let outcome = FolderEventBatch.outcome(of: [
			entry("/d/a.txt", renamed: true, onDisk: false),
			entry("/d/sub/a.txt", renamed: true, onDisk: true),
		])
		#expect(outcome.deleted.isEmpty)
		#expect(outcome.renamed == ["/d/a.txt"])
	}

	@Test("A lone rename is a file leaving the folder")
	func loneRenameIsADeletion() {
		// Both a move to the Trash and a move elsewhere look exactly like this.
		let outcome = FolderEventBatch.outcome(of: [
			entry("/d/a.txt", renamed: true, onDisk: false)
		])
		#expect(outcome.deleted == ["/d/a.txt"])
		#expect(outcome.renamed.isEmpty)
	}

	@Test("An unlink is a deletion")
	func unlinkIsADeletion() {
		let deleted = deleted([
			entry("/d/a.txt", removed: true, onDisk: false)
		])
		#expect(deleted == ["/d/a.txt"])
	}

	@Test("An unlink paired with a rename is still a deletion")
	func unlinkSurvivesANeighbouringRename() {
		let deleted = deleted([
			entry("/d/a.txt", renamed: true, onDisk: false),
			entry("/d/b.txt", renamed: true, onDisk: true),
			entry("/d/c.txt", removed: true, onDisk: false),
		])
		#expect(deleted == ["/d/c.txt"])
	}

	@Test("A batch of moves to the Trash is all deletions")
	func coalescedTrashStaysDeletions() {
		// Measured: several moves to the Trash coalesce into one batch. Counting
		// renames here would cancel every one of them.
		let deleted = deleted([
			entry("/d/a.txt", renamed: true, onDisk: false),
			entry("/d/b.txt", renamed: true, onDisk: false),
			entry("/d/c.txt", renamed: true, onDisk: false),
			entry("/d/e.txt", renamed: true, onDisk: false),
		])
		#expect(deleted.count == 4)
	}

	@Test("Two renames in one batch are both intra-folder")
	func coalescedRenamesAreNotDeletions() {
		let deleted = deleted([
			entry("/d/a.txt", renamed: true, onDisk: false),
			entry("/d/b.txt", renamed: true, onDisk: true),
			entry("/d/c.txt", renamed: true, onDisk: false),
			entry("/d/d.txt", renamed: true, onDisk: true),
		])
		#expect(deleted.isEmpty)
	}

	@Test("A rename cancels an unrelated deletion in the same batch")
	func deletionBesideARenameIsCancelled() {
		// Recorded, not desired: the pairing is batch-wide, so this is the price of
		// not being able to tell which departure a destination belongs to. It needs
		// a deletion and a rename inside one FSEvents batch.
		let deleted = deleted([
			entry("/d/renamed-away.txt", renamed: true, onDisk: false),
			entry("/d/renamed-to.txt", renamed: true, onDisk: true),
			entry("/d/trashed.txt", renamed: true, onDisk: false),
		])
		#expect(deleted.isEmpty)
	}
}
