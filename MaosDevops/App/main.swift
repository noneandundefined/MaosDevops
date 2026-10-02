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
// Files tab never sends a quoted tilde to SFTP as a literal directory name.
if CommandLine.arguments.contains("--files-path-self-test") {
    let checks = [
        RemotePath.sftpPath("~") == ".",
        RemotePath.sftpPath("~/logs/app.log") == "./logs/app.log",
        RemotePath.appending("logs", to: "~") == "~/logs",
        RemotePath.parent(of: "~/logs") == "~",
        RemotePath.parent(of: "~/logs/archive") == "~/logs"
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
