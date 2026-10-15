import AppKit

/// Watches the folders a deletion can happen in, and reports meals once a
/// disappearance has settled.
@MainActor
public final class FileDeletionWatcher {
	/// Called with the items that are ready to be eaten.
	public var onMealsReady: (([DeletedItem]) -> Void)?

	private var detectors = DeletionMealDetector()
	private var watchers: [FolderWatcher] = []
	private var pump: Timer?
	private var nextIdentifier = 1

	/// Resolves where the deleted icon was, by file name. The icon's accessibility
	/// element still exists for a fraction of a second after the deletion, so this
	/// is asked right here rather than when she sets off.
	private let anchorProvider: (String) -> (point: PixelPoint, isExact: Bool)

	public init(anchorProvider: @escaping (String) -> (point: PixelPoint, isExact: Bool)) {
		self.anchorProvider = anchorProvider
	}

	/// Desktop and Downloads by default; `extraFolders` are added from settings.
	public func start(extraFolders: [String] = []) {
		guard watchers.isEmpty else { return }

		let manager = FileManager.default
		var directories: [URL] = []
		if let desktop = manager.urls(for: .desktopDirectory, in: .userDomainMask).first {
			directories.append(desktop)
		}
		if let downloads = manager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
			directories.append(downloads)
		}
		directories.append(
			contentsOf: extraFolders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
		)

		for directory in directories where manager.fileExists(atPath: directory.path) {
			let watcher = FolderWatcher(url: directory)
			watcher.onChange = { [weak self] change in
				Task { @MainActor in self?.handle(change, in: directory) }
			}
			watcher.start()
			watchers.append(watcher)
		}

		// A removal settles for a moment before it is accepted, so a burst of raw
		// events is drained together rather than one at a time.
		let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.drain() }
		}
		RunLoop.main.add(timer, forMode: .common)
		pump = timer

		DiagnosticsLog.shared.writeEvent(
			"DeletionWatcherStarted",
			[("Count", "\(watchers.count)")]
		)
	}

	public func stop() {
		pump?.invalidate()
		pump = nil
		for watcher in watchers { watcher.stop() }
		watchers.removeAll()
	}

	private func handle(_ change: FolderWatcher.Change, in directory: URL) {
		let now = Date()
		for name in change.removed {
			let anchor = anchorProvider(name)
			detectors.noteRemoval(
				DeletionMealDetector.Pending(
					name: name,
					path: directory.appendingPathComponent(name).path,
					detectedAt: now,
					anchor: anchor.point,
					exactAnchor: anchor.isExact
				)
			)
		}
	}

	private func drain() {
		let ready = detectors.collectReady(now: Date())
		guard !ready.isEmpty else { return }

		// If no real position is known, spread the ghosts out so a burst does not
		// pile every item on the same spot.
		var occupied: [PixelPoint] = []
		let items = ready.map { entry -> DeletedItem in
			let anchor: PixelPoint
			if entry.exactAnchor {
				anchor = entry.anchor
			} else {
				anchor = GhostAnchorLayout.chooseDistinct(preferred: entry.anchor, occupied: occupied)
			}
			occupied.append(anchor)

			let item = DeletedItem(
				id: nextIdentifier,
				originalPath: entry.path,
				displayName: entry.name,
				detectedAt: entry.detectedAt,
				anchor: anchor,
				exactAnchor: entry.exactAnchor
			)
			nextIdentifier += 1
			return item
		}

		DiagnosticsLog.shared.writeEvent(
			"DeletionDetected",
			[
				("Count", "\(items.count)"),
				// A file name is user content, so it is logged as a reference.
				("Name", items.map(\.displayName).joined(separator: ",")),
			]
		)
		onMealsReady?(items)
	}
}
