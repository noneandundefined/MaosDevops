import AppKit
import Darwin

// OpenSSH launches SSH_ASKPASS as a separate process. Reusing the signed app
// executable avoids fragile temporary scripts on older macOS versions.
if ProcessInfo.processInfo.environment["MAOSDEVOPS_ASKPASS"] == "1" {
    let secret = ProcessInfo.processInfo.environment["MAOSDEVOPS_SSH_SECRET"] ?? ""
    FileHandle.standardOutput.write(Data((secret + "\n").utf8))
    exit(EXIT_SUCCESS)
}

// Headless regression probe used by the release build. It verifies that the
// Files tab resolves a tilde to the remote user's absolute home directory.
if CommandLine.arguments.contains("--files-path-self-test") {
    let checks = [
        RemotePath.homeRelativeComponent("~") == "",
        RemotePath.homeRelativeComponent("~/logs/app.log") == "logs/app.log",
        RemotePath.homeRelativeComponent("/var/log") == nil,
        RemotePath.resolving("~", home: "/root") == "/root",
        RemotePath.resolving("~/logs/app.log", home: "/root") == "/root/logs/app.log"
    ]
    if !checks.allSatisfy({ $0 }) {
        FileHandle.standardError.write(Data("Files path self-test failed\n".utf8))
        exit(EXIT_FAILURE)
    }
    exit(EXIT_SUCCESS)
}

// Use the same explicit AppKit entry point as MaosVPN. Keeping the delegate in
// this top-level constant guarantees that it lives for the complete app run.
let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.regular)
application.run()
