import Foundation

/// One FSEvents callback batch, read as the deletions it reports.
///
/// Kept pure — the caller supplies the one fact only the file system can answer —
/// so the rules below can be pinned by tests without a real desktop.
enum FolderEventBatch {
	struct Entry: Sendable, Equatable {
		/// The item's full path, as FSEvents reported it.
		var path: String
		/// The item was renamed. A move out of the folder and a move to the Trash
		/// are reported the same way: all three are `rename(2)`.
		var renamed: Bool
		/// The item was unlinked. Finder's delete does not set this, because
		/// Finder's delete is a move to the Trash.
		var removed: Bool
		/// The item was created. Set alongside `renamed` on a move to the Trash, so
		/// it means nothing on its own.
		var created: Bool
		/// Whether the path is on disk now. The event is delivered after the call
		/// that caused it has returned, so this is the post-move state.
		var isOnDisk: Bool

		init(path: String, renamed: Bool, removed: Bool, created: Bool, isOnDisk: Bool) {
			self.path = path
			self.renamed = renamed
			self.removed = removed
			self.created = created
			self.isOnDisk = isOnDisk
		}
	}

	struct Outcome: Sendable, Equatable {
		/// Paths that disappeared from the folder.
		var deleted: [String] = []
		/// Paths that vanished only because the item was renamed within the folder.
		/// These are the old names — what would otherwise have been eaten. Reported
		/// because "she did not eat the file I renamed" and "she saw nothing at all"
		/// look identical from outside.
		var renamed: [String] = []
		/// Paths that are in the folder now and were not before.
		///
		/// Not meals, and not used as meals: Finder needs a moment to draw an icon
		/// for a new file, so this is the notice that lets the icon be read while it
		/// exists — before it is deleted, and before the deletion needs to know
		/// where it was.
		var appeared: [String] = []
	}

	/// What the batch means for the meal pipeline.
	///
	/// Two rules, both measured against real `mv`/`rm` traffic:
	///
	/// 1. A renamed path that is still on disk is where an item *went*, not where
	///    one disappeared from — never a deletion. This is the fix for a rename
	///    being eaten under its new name: the destination is reported with the
	///    same `Renamed` flag as the source.
	/// 2. A renamed path that is gone is a deletion — a move out of the folder and
	///    a move to the Trash both look like this — *unless* the same batch also
	///    holds a destination, which means the item only changed its name. A lone
	///    rename leaves the folder; a paired one stays.
	///
	/// A rename within the folder arrives as a pair in one batch: FSEvents emits
	/// both paths together, with consecutive event ids. A batch of moves to the
	/// Trash stays lone however many it holds — they coalesce, they do not pair.
	///
	/// Known cost of pairing batch-wide: an unrelated deletion that lands in the
	/// same batch as a rename is cancelled too. FSEvents batches on the order of
	/// 0.3 s, so this needs a deletion and a rename driven in one go.
	static func outcome(of entries: [Entry]) -> Outcome {
		let hasRenameDestination = entries.contains { $0.renamed && !$0.removed && $0.isOnDisk }
		var outcome = Outcome()
		for entry in entries {
			// Still on disk and flagged created: a file that is there now. A move to
			// the Trash carries the flag too but is gone, so the disk is what settles
			// it — the same fact the two deletion rules turn on.
			if entry.created, !entry.removed, entry.isOnDisk {
				outcome.appeared.append(entry.path)
				continue
			}
			if entry.removed {
				outcome.deleted.append(entry.path)
			} else if entry.renamed, !entry.isOnDisk {
				// Gone: a departure, unless the batch also names where it went.
				if hasRenameDestination {
					outcome.renamed.append(entry.path)
				} else {
					outcome.deleted.append(entry.path)
				}
			}
		}
		return outcome
	}
}
