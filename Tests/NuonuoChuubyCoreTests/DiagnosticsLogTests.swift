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

	/// Every line carries the time it happened, events included. That is what makes
	/// a run readable as a timeline: how long a file lived between its creation and
	/// its deletion, how soon a read followed a deletion. A per-run id, which is what
	/// the original had, only orders lines within one run.
	@Test("An event line is stamped like any other")
	func eventLinesCarryATimestamp() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-stamp-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("activity.log")

		let log = DiagnosticsLog()
		log.configure(fileURL: url)
		log.writeEvent("First", [("Count", "1")])

		let text = try String(contentsOf: url, encoding: .utf8)
		let line = try #require(text.split(separator: "\n").first.map(String.init))
		let pattern = #"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] TRACE event=First "#
		#expect(line.range(of: pattern, options: .regularExpression) != nil, "\(line)")
	}

	/// Rotation decides when to move the file aside from the offset `seekToEnd` reports,
	/// which is also how it appends — so this is the check that the size it reads is the
	/// size the file really has, and that the handle is reopened on the new one.
	///
	/// A limit small enough to be crossed several times over is deliberate: it is the
	/// reopen that is under test, and a single rotation would pass even if the handle
	/// were left pointing at the file that moved.
	@Test("A log that outgrows its limit is moved aside and started again")
	func rotatesWhenFull() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-rotate-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("activity.log")

		let log = DiagnosticsLog()
		log.configure(fileURL: url, maximumBytes: 200)
		for index in 0..<40 {
			log.writeEvent("Filler", [("Index", "\(index)")])
		}

		let previous = directory.appendingPathComponent("activity.previous.log")
		#expect(FileManager.default.fileExists(atPath: previous.path))
		// Whatever was rotated away, the lines written since must not be in it: that is
		// what says the handle was reopened on the file that replaced it.
		let previousText = try String(contentsOf: previous, encoding: .utf8)
		let liveText = try String(contentsOf: url, encoding: .utf8)
		#expect(liveText.contains("Index=\"39\""))
		#expect(!previousText.contains("Index=\"39\""))
		// The size is checked before the write, so the live file may sit up to one line
		// over the limit — but nowhere near the sixteen hundred bytes all forty lines
		// would take, which is what an unreopened handle would have produced.
		#expect(liveText.count < 300)
	}

	/// The switch and the lines around it. A log that simply stops looks the same
	/// whether it was turned off or the app died, so the change itself is recorded —
	/// and the "off" line has to land *before* the flag moves, or it is the first
	/// line dropped.
	@Test("Logging off records the change last, and then stays quiet")
	func disablingLogsTheChangeItself() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-gate-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("activity.log")

		let log = DiagnosticsLog()
		log.configure(fileURL: url)
		log.writeEvent("BeforeOff")

		log.setEnabled(false)
		log.writeEvent("WhileOff")
		log.write("while off")

		let text = try String(contentsOf: url, encoding: .utf8)
		#expect(text.contains("event=BeforeOff"))
		#expect(text.contains("event=LoggingDisabled"), "the switch itself is recorded")
		#expect(!text.contains("WhileOff"), "and nothing after it is")
		#expect(!text.contains("while off"))
		// The off line is the last one there is.
		let lines = text.split(separator: "\n").map(String.init)
		#expect(lines.last?.contains("event=LoggingDisabled") == true)
		// Setting it off again changes nothing, so it must not add another line.
		log.setEnabled(false)
		#expect(try String(contentsOf: url, encoding: .utf8).count == text.count)
	}

	@Test("Logging on again records the change and resumes")
	func enablingResumesAndLogs() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-gate-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("activity.log")

		let log = DiagnosticsLog()
		log.configure(fileURL: url)
		log.setEnabled(false)
		log.setEnabled(true)
		log.writeEvent("AfterOn")

		let text = try String(contentsOf: url, encoding: .utf8)
		#expect(text.contains("event=LoggingDisabled"))
		#expect(text.contains("event=LoggingEnabled"))
		#expect(text.contains("event=AfterOn"))
		#expect(log.isEnabled)
	}

	/// A run that starts with logging off writes nothing at all — not even a
	/// ProcessStarted line — which is what the launch order in AppDelegate is for.
	@Test("A run configured off writes nothing from the start")
	func startsQuiet() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("nuonuo-quiet-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("activity.log")

		let log = DiagnosticsLog()
		log.configure(fileURL: url, enabled: false)
		log.writeEvent("ProcessStarted")

		#expect(!FileManager.default.fileExists(atPath: url.path))
	}
}
