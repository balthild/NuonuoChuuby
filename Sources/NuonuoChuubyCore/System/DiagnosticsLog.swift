import Foundation
import CryptoKit

/// A local, rotating activity log.
///
/// Diagnostics must never interrupt the pet, so every write is best-effort. Free
/// text is scrubbed of paths and e-mail addresses, and anything the caller marks
/// as user content is replaced by a session-scoped reference that keeps events
/// correlatable without recording what the user had on screen.
public final class DiagnosticsLog: @unchecked Sendable {
	public static let shared = DiagnosticsLog()

	private static let maximumLogBytes = 8 * 1024 * 1024
	private let lock = NSLock()
	private let sessionID: String
	private let hmacKey = SymmetricKey(size: .bits256)
	private var fileURL: URL?

	public init() {
		let stamp = ISO8601DateFormatter()
		sessionID = stamp.string(from: Date())
	}

	public func configure(fileURL: URL) {
		lock.lock()
		defer { lock.unlock() }
		self.fileURL = fileURL
	}

	public func write(_ message: String) {
		append("[\(timestamp())] \(DiagnosticsPrivacy.message(message))")
	}

	public func write(_ message: String, error: Error) {
		append("[\(timestamp())] \(DiagnosticsPrivacy.message(message)) :: \(String(describing: type(of: error)))")
	}

	public func writeEvent(_ name: String, _ fields: [(String, String)] = []) {
		let rendered = fields
			.map { "\($0.0)=\"\(DiagnosticsPrivacy.field(key: $0.0, value: $0.1, reference: reference))\" " }
			.joined()
		append("TRACE session=\(sessionID) event=\(name) \(rendered)")
	}

	/// A stable-within-this-session, irreversible stand-in for user content.
	public func reference(_ value: String) -> String {
		let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: hmacKey)
		let hex = mac.prefix(8).map { String(format: "%02x", $0) }.joined()
		return "[private:\(hex)]"
	}

	private func timestamp() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
		return formatter.string(from: Date())
	}

	private func append(_ line: String) {
		guard let fileURL else { return }
		lock.lock()
		defer { lock.unlock() }
		do {
			try FileManager.default.createDirectory(
				at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			rotateIfNeeded(fileURL)
			let data = Data((line + "\n").utf8)
			if let handle = try? FileHandle(forWritingTo: fileURL) {
				defer { try? handle.close() }
				try handle.seekToEnd()
				try handle.write(contentsOf: data)
			} else {
				try data.write(to: fileURL)
			}
		} catch {
			// Diagnostics must never interrupt the pet.
		}
	}

	private func rotateIfNeeded(_ fileURL: URL) {
		let manager = FileManager.default
		guard let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
			let size = attributes[.size] as? Int, size >= Self.maximumLogBytes
		else { return }
		let previous = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
		try? manager.removeItem(at: previous)
		try? manager.moveItem(at: fileURL, to: previous)
	}
}

enum DiagnosticsPrivacy {
	/// Absolute POSIX paths (any slash-led token) and e-mail addresses.
	private static let redactions = [
		"/[^\\s\"']+",
		"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
	]

	/// Flattens newlines; used where the text is already known to be free of
	/// user content.
	static func message(_ value: String) -> String {
		flatten(value)
	}

	/// Flattens and then scrubs anything path- or identity-shaped.
	static func message(_ value: String, reference: (String) -> String) -> String {
		var text = flatten(value)
		for pattern in redactions {
			text = redact(pattern, in: text, reference: reference)
		}
		return text
	}

	static func field(key: String, value: String, reference: (String) -> String) -> String {
		let sensitiveKeys = ["path", "directory", "folder", "title", "caption", "username", "name", "text"]
		let lower = key.lowercased()
		if sensitiveKeys.contains(where: { lower.contains($0) }) {
			return reference(value)
		}
		return message(value, reference: reference)
	}

	private static func flatten(_ value: String) -> String {
		value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
	}

	private static func redact(_ pattern: String, in text: String, reference: (String) -> String) -> String {
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
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
