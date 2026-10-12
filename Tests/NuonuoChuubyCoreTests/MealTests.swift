import Foundation
import Testing

@testable import NuonuoChuubyCore

@Suite("Meal queue")
struct MealQueueTests {
	private func item(_ id: Int, name: String = "a.txt") -> DeletedItem {
		DeletedItem(
			id: id,
			originalPath: "/tmp/\(name)",
			displayName: name,
			detectedAt: Date(),
			cameFromTrash: true,
			anchor: PixelPoint(x: 100, y: 200),
			exactAnchor: true
		)
	}

	@Test("Items come out in the order they went in")
	func fifo() {
		var queue = MealQueue()
		queue.enqueue(item(1, name: "a"))
		queue.enqueue(item(2, name: "b"))
		let first = queue.dequeue()
		let second = queue.dequeue()
		#expect(first?.id == 1)
		#expect(second?.id == 2)
		#expect(queue.isEmpty)
	}

	@Test("The queue is capped")
	func capped() {
		var queue = MealQueue()
		for id in 0..<(MealQueuePolicy.maximumBufferedDeletions + 10) {
			queue.enqueue(item(id))
		}
		#expect(queue.count == MealQueuePolicy.maximumBufferedDeletions)
	}

	@Test("An interrupted meal returns to the front")
	func requeueAtFront() {
		var queue = MealQueue()
		queue.enqueue(item(1, name: "a"))
		queue.enqueue(item(2, name: "b"))
		queue.requeueAtFront(item(99, name: "z"))
		let next = queue.dequeue()
		#expect(next?.id == 99)
		#expect(queue.count == 2)
	}

	@Test("A full queue rejects new deletions")
	func policy() {
		#expect(MealQueuePolicy.canAcceptDeletion(queuedCount: 0, hasActiveDeletionMeal: false))
		#expect(MealQueuePolicy.canAcceptDeletion(queuedCount: 23, hasActiveDeletionMeal: false))
		#expect(!MealQueuePolicy.canAcceptDeletion(queuedCount: 24, hasActiveDeletionMeal: false))
		// An in-flight meal counts against the cap.
		#expect(!MealQueuePolicy.canAcceptDeletion(queuedCount: 23, hasActiveDeletionMeal: true))
	}
}

@Suite("Deletion meal detector")
struct DeletionMealDetectorTests {
	private let base = Date(timeIntervalSince1970: 1_000_000)

	private func removal(_ name: String, at offset: Double = 0) -> DeletionMealDetector.Pending {
		DeletionMealDetector.Pending(
			name: name,
			path: "/tmp/\(name)",
			detectedAt: base.addingTimeInterval(offset),
			anchor: PixelPoint(x: 10, y: 20),
			exactAnchor: true
		)
	}

	@Test("A removal is accepted once the Trash confirms it")
	func corroborated() {
		var detector = DeletionMealDetector()
		detector.noteRemoval(removal("a.txt"))
		detector.noteTrashArrival(name: "a.txt", at: base.addingTimeInterval(0.3))

		let ready = detector.collectReady(now: base.addingTimeInterval(0.5))
		#expect(ready.count == 1)
		#expect(ready.first?.cameFromTrash == true)
	}

	@Test("A locally renamed duplicate still matches")
	func duplicateSuffixMatches() {
		var detector = DeletionMealDetector()
		detector.noteRemoval(removal("report.pdf"))
		// Finder renames the second copy to "report 2.pdf".
		detector.noteTrashArrival(name: "report 2.pdf", at: base.addingTimeInterval(0.2))

		let ready = detector.collectReady(now: base.addingTimeInterval(0.4))
		#expect(ready.count == 1)
		#expect(ready.first?.cameFromTrash == true)
	}

	@Test("A removal is accepted on timeout even without a Trash entry")
	func uncorroboratedTimeout() {
		var detector = DeletionMealDetector()
		detector.noteRemoval(removal("a.txt"))

		// Immediately after, nothing is ready yet.
		let early = detector.collectReady(now: base.addingTimeInterval(0.5))
		#expect(early.isEmpty)
		// After the confirm window, it is accepted as a plain delete.
		let ready = detector.collectReady(now: base.addingTimeInterval(3))
		#expect(ready.count == 1)
		#expect(ready.first?.cameFromTrash == false)
	}

	@Test("Each removal is reported exactly once")
	func exactlyOnce() {
		var detector = DeletionMealDetector()
		detector.noteRemoval(removal("a.txt"))
		let first = detector.collectReady(now: base.addingTimeInterval(3))
		let second = detector.collectReady(now: base.addingTimeInterval(4))
		#expect(first.count == 1)
		#expect(second.isEmpty)
	}

	@Test("A stale Trash arrival does not corroborate a later removal")
	func staleTrashArrivalIgnored() {
		var detector = DeletionMealDetector()
		// The same name was trashed long before this removal.
		detector.noteTrashArrival(name: "a.txt", at: base)
		detector.noteRemoval(removal("a.txt", at: 60))

		let ready = detector.collectReady(now: base.addingTimeInterval(63))
		#expect(ready.first?.cameFromTrash == false)
	}
}

@Suite("Icon lick targeting")
struct IconLickTargetSelectorTests {
	@Test("Nothing is chosen without candidates")
	func empty() {
		#expect(
			IconLickTargetSelector.choose(
				candidates: [],
				origin: PixelPoint(x: 0, y: 0),
				randomUnit: 0.5
			) == nil
		)
	}

	@Test("Candidates that are too close are avoided when possible")
	func avoidsTooClose() {
		let candidates = [PixelPoint(x: 5, y: 0), PixelPoint(x: 200, y: 0)]
		for step in 0..<100 {
			let chosen = IconLickTargetSelector.choose(
				candidates: candidates,
				origin: PixelPoint(x: 0, y: 0),
				randomUnit: Double(step) / 100
			)
			#expect(chosen == PixelPoint(x: 200, y: 0))
		}
	}

	@Test("With only close candidates the nearest pool is used anyway")
	func fallsBackToNearest() {
		let chosen = IconLickTargetSelector.choose(
			candidates: [PixelPoint(x: 5, y: 0), PixelPoint(x: 8, y: 0)],
			origin: PixelPoint(x: 0, y: 0),
			randomUnit: 0
		)
		#expect(chosen != nil)
	}

	@Test("Duplicates are collapsed")
	func deduplicates() {
		let candidates = Array(repeating: PixelPoint(x: 200, y: 0), count: 20)
		let chosen = IconLickTargetSelector.choose(
			candidates: candidates,
			origin: PixelPoint(x: 0, y: 0),
			randomUnit: 0.9
		)
		#expect(chosen == PixelPoint(x: 200, y: 0))
	}
}

@Suite("Ghost anchor layout")
struct GhostAnchorLayoutTests {
	@Test("The preferred spot is used when free")
	func preferred() {
		let spot = GhostAnchorLayout.chooseDistinct(preferred: PixelPoint(x: 500, y: 500), occupied: [])
		#expect(spot == PixelPoint(x: 500, y: 500))
	}

	@Test("An occupied spot is shifted to a free one")
	func shiftsWhenOccupied() {
		let preferred = PixelPoint(x: 500, y: 500)
		let spot = GhostAnchorLayout.chooseDistinct(preferred: preferred, occupied: [preferred])
		#expect(spot != preferred)
		let distance = IconLickTargetSelector.squaredDistance(spot, preferred).squareRoot()
		#expect(distance >= 56)
	}

	@Test("Every ghost stays clear of the others")
	func allDistinct() {
		var occupied: [PixelPoint] = []
		for _ in 0..<GhostAnchorLayout.offsets.count {
			let spot = GhostAnchorLayout.chooseDistinct(
				preferred: PixelPoint(x: 400, y: 400),
				occupied: occupied
			)
			for other in occupied {
				#expect(IconLickTargetSelector.squaredDistance(spot, other).squareRoot() >= 56)
			}
			occupied.append(spot)
		}
	}
}

@Suite("Deletion burst tracker")
struct DeletionBurstTrackerTests {
	@Test("A single deletion is not a burst")
	func single() {
		var tracker = DeletionBurstTracker()
		let isBurst = tracker.register(detectedAt: Date(timeIntervalSince1970: 0))
		#expect(!isBurst)
	}

	@Test("Two deletions inside the window are a burst")
	func burst() {
		var tracker = DeletionBurstTracker()
		_ = tracker.register(detectedAt: Date(timeIntervalSince1970: 0))
		let isBurst = tracker.register(detectedAt: Date(timeIntervalSince1970: 2))
		#expect(isBurst)
	}

	@Test("Deletions far apart are not a burst")
	func spreadOut() {
		var tracker = DeletionBurstTracker()
		_ = tracker.register(detectedAt: Date(timeIntervalSince1970: 0))
		let isBurst = tracker.register(detectedAt: Date(timeIntervalSince1970: 30))
		#expect(!isBurst)
	}
}

@Suite("Desktop icon grid")
struct DesktopIconGridTests {
	private let workArea = PixelRect(x: 0, y: 25, width: 1440, height: 875)

	@Test("Icons run down the right edge then leftwards")
	func layout() {
		let first = DesktopIconGrid.position(xIndex: 0, yIndex: 0, in: workArea)
		let below = DesktopIconGrid.position(xIndex: 0, yIndex: 1, in: workArea)
		let nextColumn = DesktopIconGrid.position(xIndex: 1, yIndex: 0, in: workArea)

		#expect(first.x < workArea.right && first.x > workArea.right - 100)
		#expect(below.x == first.x)
		#expect(below.y > first.y)
		#expect(nextColumn.x < first.x)
		#expect(nextColumn.y == first.y)
	}

	@Test("Every slot is inside the work area horizontally")
	func insideWorkArea() {
		for position in DesktopIconGrid.positions(count: 40, in: workArea) {
			#expect(position.x < workArea.right)
			#expect(position.y > workArea.top)
		}
	}

	@Test("No slots are produced for an empty request")
	func empty() {
		#expect(DesktopIconGrid.positions(count: 0, in: workArea).isEmpty)
	}
}
