import Foundation

/// The runtime assets the tests need.
///
/// `make test` hard-links them out of the upstream submodule into a build
/// directory and hands the location over through `NUONUO_ASSET_ROOT`. A bare
/// `swift test` has none, and the tests that need artwork then fail with
/// `TestSkip.missingAssets` rather than silently skipping.
enum TestAssets {
	static var root: URL? {
		guard let path = ProcessInfo.processInfo.environment["NUONUO_ASSET_ROOT"] else { return nil }
		let url = URL(fileURLWithPath: path)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}
}
