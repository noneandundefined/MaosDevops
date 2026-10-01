import AppKit

// Use the same explicit AppKit entry point as MaosVPN. Keeping the delegate in
// this top-level constant guarantees that it lives for the complete app run.
let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.regular)
application.run()
