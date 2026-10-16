import CryptoKit
import Foundation

/// A local, rotating activity log.
///
/// Every write is best-effort; free text is scrubbed of paths and e-mail
/// addresses, and user content is replaced by a session-scoped reference.
public final class DiagnosticsLog: @unchecked Sendable {
	public static let shared = DiagnosticsLog()

	public static let defaultMaximumLogBytes = 8 * 1024 * 1024
	/// Set by ``configure(fileURL:maximumBytes:)``. Settable so rotation can be exercised
	/// without writing eight megabytes to reach it.
	private var maximumLogBytes = DiagnosticsLog.defaultMaximumLogBytes

	/// Built once. A write can arrive once per frame, and constructing a
	/// `DateFormatter` on every line is expensive (refactor-plan §3.2).
	private static let timestampFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
		return formatter
	}()

	private let lock = NSLock()
	private let hmacKey = SymmetricKey(size: .bits256)
	private var fileURL: URL?
	/// Kept open between writes, so a hot path does not pay an
	/// open/seek/write/close per line. Nil until the first write, and on rotation.
	private var handle: FileHandle?
	/// The log directory only needs creating once per configured file.
	private var hasCreatedDirectory = false

	public init() {}

	deinit {
		try? handle?.close()
	}

	public func configure(
		fileURL: URL,
		maximumBytes: Int = DiagnosticsLog.defaultMaximumLogBytes
	) {
		lock.lock()
		defer { lock.unlock() }
		try? handle?.close()
		handle = nil
		hasCreatedDirectory = false
		maximumLogBytes = maximumBytes
		self.fileURL = fileURL
	}

	public func write(_ message: String) {
		append("[\(timestamp())] \(DiagnosticsPrivacy.message(message))")
	}

	public func write(_ message: String, error: Error) {
		append(
			"[\(timestamp())] \(DiagnosticsPrivacy.message(message)) :: \(String(describing: type(of: error)))"
		)
	}

	/// A structured event, stamped like every other line.
	///
	/// The stamp is what makes a sequence of events answer questions about time —
	/// how long a file lived, how soon a read followed a deletion. The original
	/// carries a per-run id instead, which orders lines within one run and cannot
	/// date any of them.
	public func writeEvent(_ name: String, _ fields: [(String, String)] = []) {
		let rendered =
			fields
			.map {
				"\($0.0)=\"\(DiagnosticsPrivacy.field(key: $0.0, value: $0.1, reference: reference))\" "
			}
			.joined()
		append("[\(timestamp())] TRACE event=\(name) \(rendered)")
	}

	/// A stable-within-this-session, irreversible stand-in for user content.
	public func reference(_ value: String) -> String {
		let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: hmacKey)
		let hex = mac.prefix(8).map { String(format: "%02x", $0) }.joined()
		return "[private:\(hex)]"
	}

	private func timestamp() -> String {
		Self.timestampFormatter.string(from: Date())
	}

	private func append(_ line: String) {
		lock.lock()
		defer { lock.unlock() }
		guard let fileURL else { return }
		do {
			let manager = FileManager.default
			if !hasCreatedDirectory {
				try manager.createDirectory(
					at: fileURL.deletingLastPathComponent(),
					withIntermediateDirectories: true
				)
				hasCreatedDirectory = true
			}
			// `seekToEnd` returns the offset it moved to, which is the file's size — so
			// rotation needs no `stat` of its own. That call was already being made to
			// append, and asking for the size separately made a line cost about half
			// again as much as it needed to.
			if try openHandle(for: fileURL, manager: manager).seekToEnd()
				>= UInt64(maximumLogBytes)
			{
				rotate(fileURL: fileURL, manager: manager)
				_ = try openHandle(for: fileURL, manager: manager).seekToEnd()
			}
			try handle?.write(contentsOf: Data((line + "\n").utf8))
			// The line reaches the kernel on every write, so an app crash cannot
			// lose it. Deliberately no fsync: forcing a disk write per frame would
			// add the stall this change removes.
		} catch {
			// A failed write must never interrupt the pet. Drop the handle so the
			// next write reopens cleanly.
			try? handle?.close()
			handle = nil
		}
	}

	private func openHandle(for fileURL: URL, manager: FileManager) throws -> FileHandle {
		if let handle { return handle }
		if !manager.fileExists(atPath: fileURL.path) {
			manager.createFile(atPath: fileURL.path, contents: nil)
		}
		let opened = try FileHandle(forWritingTo: fileURL)
		handle = opened
		return opened
	}

	private func rotate(fileURL: URL, manager: FileManager) {
		// The cached handle points at the file being moved, so drop it first; the
		// next write opens the fresh file.
		try? handle?.close()
		handle = nil
		let previous = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
		try? manager.removeItem(at: previous)
		try? manager.moveItem(at: fileURL, to: previous)
	}
}

enum DiagnosticsPrivacy {
	/// Absolute POSIX paths (any slash-led token) and e-mail addresses. Compiled
	/// once: compiling them per field on the drag hot path was measurable.
	private static let redactions: [NSRegularExpression] = [
		"/[^\\s\"']+",
		"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
	].compactMap { try? NSRegularExpression(pattern: $0) }

	/// Flattens newlines; used where the text is already known to be free of
	/// user content.
	static func message(_ value: String) -> String {
		flatten(value)
	}

	static func message(_ value: String, reference: (String) -> String) -> String {
		var text = flatten(value)
		for regex in redactions {
			text = redact(regex, in: text, reference: reference)
		}
		return text
	}

	static func field(key: String, value: String, reference: (String) -> String) -> String {
		let sensitiveKeys = [
			"path", "directory", "folder", "title", "caption", "username", "name", "text",
		]
		let lower = key.lowercased()
		if sensitiveKeys.contains(where: { lower.contains($0) }) {
			return reference(value)
		}
		return message(value, reference: reference)
	}

	private static func flatten(_ value: String) -> String {
		value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
	}

	private static func redact(
		_ regex: NSRegularExpression,
		in text: String,
		reference: (String) -> String
	)
		-> String
	{
		var result = text
		// Walk matches backwards so the earlier ranges stay valid.
		let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
		for match in matches.reversed() {
			guard let range = Range(match.range, in: result),
				let original = Range(match.range, in: text)
			else { continue }
			result.replaceSubrange(range, with: reference(String(text[original])))
		}
		return result
	}
}
