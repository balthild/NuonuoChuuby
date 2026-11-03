import Foundation

/// Registers the app as a login item.
///
/// `SMAppService.mainApp` is the modern API, but it requires a Team-signed bundle;
/// under this project's self-signed certificate it reports `.notFound`. The
/// System Events login-item list works with any signature, at the cost of a
/// one-time automation prompt.
public enum StartupRegistrationService {
	enum RegistrationError: Error {
		case scriptFailed(String)
	}

	/// Login items are matched by path: their displayed name is the app's
	/// localized name, which is not what we registered.
	public static func isEnabled(appPath: String) -> Bool {
		guard
			let output = try? runAppleScript(
				"""
				tell application "System Events" to get the path of every login item
				"""
			)
		else { return false }
		return output.components(separatedBy: ", ").contains {
			$0.trimmingCharacters(in: .whitespacesAndNewlines) == appPath
		}
	}

	public static func setEnabled(_ enabled: Bool, appPath: String) throws {
		let path = scriptEscape(appPath)
		if enabled {
			// `login item "X"` addresses an item by NAME, so existence has to be
			// tested by walking the list and comparing paths.
			try runAppleScript(
				"""
				tell application "System Events"
					set alreadyRegistered to false
					repeat with candidate in login items
						if path of candidate is "\(path)" then set alreadyRegistered to true
					end repeat
					if not alreadyRegistered then
						make login item at end with properties {path:"\(path)", hidden:false}
					end if
				end tell
				"""
			)
		} else {
			// Deleting shifts the remaining indices, so walk them in reverse.
			try runAppleScript(
				"""
				tell application "System Events"
					repeat with index from (count of login items) to 1 by -1
						if path of login item index is "\(path)" then
							delete login item index
						end if
					end repeat
				end tell
				"""
			)
		}
	}

	private static func scriptEscape(_ value: String) -> String {
		value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
	}

	@discardableResult
	private static func runAppleScript(_ source: String) throws -> String {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = ["-e", source]
		let output = Pipe()
		let errors = Pipe()
		process.standardOutput = output
		process.standardError = errors

		try process.run()
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()

		guard process.terminationStatus == 0 else {
			let message =
				String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
			throw RegistrationError.scriptFailed(message)
		}
		return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
			?? ""
	}
}
