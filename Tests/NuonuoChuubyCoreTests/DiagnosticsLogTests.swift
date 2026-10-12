import Foundation
import Testing

@testable import NuonuoChuubyCore

/// Guards the cached-handle write path: lines must still be written, and
/// user-content fields must still be redacted.
@Suite("Diagnostics log")
struct DiagnosticsLogTests {
	@Test("Events and messages reach the configured file")
	func writesToFile() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-log-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("activity.log")

		let log = DiagnosticsLog()
		log.configure(fileURL: url)
		log.writeEvent("First", [("Response", "follow")])
		log.write("plain line")
		log.writeEvent("Second", [("Path", "/Users/someone/secret.txt")])

		let text = try String(contentsOf: url, encoding: .utf8)
		#expect(text.contains("event=First"))
		#expect(text.contains("event=Second"))
		#expect(text.contains("plain line"))
		// The `Path` field is user content, so it is replaced by a reference.
		#expect(!text.contains("secret"))
		#expect(text.contains("[private:"))
	}
}
