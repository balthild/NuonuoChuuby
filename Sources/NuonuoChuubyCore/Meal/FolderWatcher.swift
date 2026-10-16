import CoreServices
import Foundation

/// Watches a directory for deletions, using an FSEvents stream.
///
/// Deliberately *not* a `DispatchSource` on a directory file descriptor: `open`
/// on a folder managed by a File Provider (an iCloud-synced Desktop or
/// Documents) blocks, which hangs whatever calls it. An FSEvents stream is
/// created asynchronously and reports per-file flags instead.
final class FolderWatcher {
	private let url: URL
	private let queue = DispatchQueue(label: "com.balthild.NuonuoChuuby.folder-watcher")
	private var stream: FSEventStreamRef?

	/// Called once per batch of file events that means something to the meals.
	var onEvents: (@Sendable (FolderEventBatch.Outcome) -> Void)?

	init(url: URL) {
		self.url = url
	}

	func start() {
		guard stream == nil else { return }

		var context = FSEventStreamContext()
		context.info = Unmanaged.passUnretained(self).toOpaque()

		let flags = FSEventStreamCreateFlags(
			kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
				| kFSEventStreamCreateFlagNoDefer
		)

		guard
			let created = FSEventStreamCreate(
				kCFAllocatorDefault,
				FolderWatcher.eventCallback,
				&context,
				[url.path] as CFArray,
				FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
				0.3,
				flags
			)
		else {
			DiagnosticsLog.shared.write("cannot watch folder for deletions")
			return
		}

		FSEventStreamSetDispatchQueue(created, queue)
		guard FSEventStreamStart(created) else {
			FSEventStreamInvalidate(created)
			FSEventStreamRelease(created)
			DiagnosticsLog.shared.write("cannot start folder watch")
			return
		}
		stream = created
	}

	func stop() {
		guard let stream else { return }
		FSEventStreamStop(stream)
		FSEventStreamInvalidate(stream)
		FSEventStreamRelease(stream)
		self.stream = nil
	}

	deinit { stop() }

	private static let eventCallback: FSEventStreamCallback = {
		_,
		info,
		count,
		eventPaths,
		eventFlags,
		_ in
		guard let info, count > 0 else { return }
		let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
		// With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of
		// CFString; without it the pointer would be a raw char** instead.
		let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
		let flags = UnsafeBufferPointer(start: eventFlags, count: count)
		watcher.handle(paths: paths, flags: flags)
	}

	private func handle(paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
		var entries: [FolderEventBatch.Entry] = []

		for (index, rawFlags) in flags.enumerated() where index < paths.count {
			let path = paths[index]
			let name = (path as NSString).lastPathComponent
			// The Finder's own bookkeeping is not a user file.
			guard !name.isEmpty, name != ".DS_Store", !name.hasPrefix(".") else { continue }

			let renamed = rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0
			let removed = rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
			let created = rawFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
			guard renamed || removed || created else { continue }

			entries.append(
				FolderEventBatch.Entry(
					path: path,
					renamed: renamed,
					removed: removed,
					created: created,
					isOnDisk: FileManager.default.fileExists(atPath: path)
				)
			)
		}

		let outcome = FolderEventBatch.outcome(of: entries)
		guard !outcome.deleted.isEmpty || !outcome.renamed.isEmpty || !outcome.appeared.isEmpty
		else { return }
		let onEvents = self.onEvents
		DispatchQueue.main.async { onEvents?(outcome) }
	}
}
