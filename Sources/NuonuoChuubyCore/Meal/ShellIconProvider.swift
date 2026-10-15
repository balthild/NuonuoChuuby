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
