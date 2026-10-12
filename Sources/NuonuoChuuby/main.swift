import AppKit
import NuonuoChuubyCore

// The app runs on AppKit's lifecycle so the status item, the pet panel and the
// auxiliary panels can all be driven directly. SwiftUI, where used, is hosted
// inside those AppKit containers.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
