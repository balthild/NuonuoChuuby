import AppKit

/// Shows the first-launch download: progress while it runs, and a retry when it
/// fails.
@MainActor
public final class AssetSetupWindowController {
	private let panel: NSPanel
	private let statusLabel: NSTextField
	private let progressBar: NSProgressIndicator
	private let retryButton: NSButton

	public var onRetry: (() -> Void)?

	public init() {
		panel = NSPanel(
			contentRect: NSRect(x: 0, y: 0, width: 360, height: 132),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		panel.title = "糯糯啾比"
		panel.isReleasedWhenClosed = false
		panel.level = .floating

		let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

		statusLabel = NSTextField(labelWithString: "正在下载桌宠素材…")
		statusLabel.frame = NSRect(x: 24, y: 84, width: 312, height: 20)
		statusLabel.font = NSFont.systemFont(ofSize: 13)

		progressBar = NSProgressIndicator()
		progressBar.frame = NSRect(x: 24, y: 56, width: 312, height: 12)
		progressBar.style = .bar
		progressBar.isIndeterminate = false
		progressBar.minValue = 0
		progressBar.maxValue = 1

		retryButton = NSButton(title: "重试", target: nil, action: nil)
		retryButton.frame = NSRect(x: 246, y: 16, width: 90, height: 28)
		retryButton.bezelStyle = .rounded
		retryButton.isHidden = true

		container.addSubview(statusLabel)
		container.addSubview(progressBar)
		container.addSubview(retryButton)
		panel.contentView = container

		retryButton.target = self
		retryButton.action = #selector(retryTapped)
	}

	/// Whether the user asked to retry since the last failure.
	private var retryRequested = false

	@objc private func retryTapped() {
		retryRequested = true
		showProgress(completed: 0, total: 0)
		onRetry?()
	}

	public func show() {
		panel.center()
		// The pet has no Dock icon, so the window has to bring itself forward.
		panel.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	public func close() {
		panel.orderOut(nil)
	}

	public func showProgress(completed: Int, total: Int) {
		retryButton.isHidden = true
		progressBar.isHidden = false
		progressBar.isIndeterminate = total == 0
		if total == 0 {
			progressBar.startAnimation(nil)
			statusLabel.stringValue = "正在准备…"
		} else {
			progressBar.doubleValue = Double(completed) / Double(total)
			statusLabel.stringValue = "正在下载桌宠素材… \(completed)/\(total)"
		}
	}

	public func showFailure(_ message: String) {
		progressBar.isHidden = true
		retryButton.isHidden = false
		statusLabel.stringValue = message
	}

	/// Waits for the user to retry, so the caller can loop without blocking a run
	/// loop turn.
	public func waitForRetry() async {
		retryRequested = false
		while !retryRequested {
			try? await Task.sleep(nanoseconds: 100_000_000)
		}
	}
}
