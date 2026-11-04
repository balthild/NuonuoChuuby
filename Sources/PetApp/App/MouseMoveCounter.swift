import AppKit
import PetFoundation

/// Counts the `.mouseMoved` events this process is handed, once a second.
///
/// Only started by `--mouse-move-count`, for the overlay-versus-grid comparison. The
/// count is the part that makes a CPU reading meaningful: the whole hypothesis is that
/// a full-display window is handed the move stream wherever the pointer is and a small
/// window only over the pet, and a reading without these counters cannot tell a
/// renderer that receives nothing from one that is simply idle.
@MainActor
final class MouseMoveCounter {
	private var monitor: Any?
	private var timer: Timer?
	private var count = 0

	func start() {
		guard monitor == nil else { return }

		monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
			MainActor.assumeIsolated { self.count += 1 }
			return event
		}

		let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.report() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	private func report() {
		let value = count
		count = 0
		DiagnosticsLog.shared.writeEvent("MouseMoveCount", [("PerSecond", "\(value)")])
	}
}
