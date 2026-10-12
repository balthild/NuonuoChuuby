import AppKit

/// Resolves the icon a Finder would show for a path.
public enum ShellIconProvider {
	/// The icon for an existing file, or the generic document icon for a path
	/// that is already gone (a deleted file no longer has an icon to read).
	public static func icon(forPath path: String, size: Double = 64) -> NSImage? {
		let manager = FileManager.default
		if manager.fileExists(atPath: path) {
			return NSWorkspace.shared.icon(forFile: path)
		}
		// Reconstruct from the file's type, which survives its deletion.
		let ext = (path as NSString).pathExtension
		if ext.isEmpty {
			return NSWorkspace.shared.icon(for: .folder)
		}
		return NSWorkspace.shared.icon(for: .init(filenameExtension: ext) ?? .data)
	}
}

/// A small, click-through panel that shows a deleted item's icon where it used
/// to be, so the pet visibly walks over and eats it.
@MainActor
public final class GhostIconWindow {
	private let panel: GhostIconPanel
	private let imageView: NSImageView

	public init() {
		panel = GhostIconPanel(
			contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false)
		panel.isFloatingPanel = true
		panel.level = .floating
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.ignoresMouseEvents = true
		panel.hidesOnDeactivate = false
		panel.animationBehavior = .none
		panel.isReleasedWhenClosed = false

		imageView = NSImageView()
		imageView.imageScaling = .scaleProportionallyUpOrDown
		panel.contentView = imageView
	}

	public func show(icon: NSImage?, at center: PixelPoint, size: Double, displaySpace: DisplaySpace) {
		imageView.image = icon
		let frame = DisplaySpace.toAppKit(
			PixelRect(
				x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
			primaryHeight: displaySpace.primaryHeight)
		panel.setFrame(frame, display: true)
		imageView.frame = NSRect(origin: .zero, size: frame.size)
		panel.alphaValue = 1
		panel.orderFrontRegardless()
	}

	/// Fades the icon out as the pet finishes eating it.
	public func fadeOut(then completion: (() -> Void)? = nil) {
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.25
			panel.animator().alphaValue = 0
		} completionHandler: { [weak self] in
			self?.panel.orderOut(nil)
			completion?()
		}
	}

	public func hide() {
		panel.orderOut(nil)
	}
}

private final class GhostIconPanel: NSPanel {
	override var canBecomeKey: Bool { false }
	override var canBecomeMain: Bool { false }
}
