import AppKit
import Darwin

// OpenSSH launches SSH_ASKPASS as a separate process. Reusing the signed app
// executable avoids fragile temporary scripts on older macOS versions.
if ProcessInfo.processInfo.environment["MAOSDEVOPS_ASKPASS"] == "1" {
    let secret = ProcessInfo.processInfo.environment["MAOSDEVOPS_SSH_SECRET"] ?? ""
    FileHandle.standardOutput.write(Data((secret + "\n").utf8))
    exit(EXIT_SUCCESS)
}

// Use the same explicit AppKit entry point as MaosVPN. Keeping the delegate in
// this top-level constant guarantees that it lives for the complete app run.
let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.regular)
application.run()
