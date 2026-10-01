import Cocoa
import Darwin

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let automaticUpdateCheckDateKey = "MaosDevOps.lastAutomaticUpdateCheck"
    /// Shared with Scripts/package.sh — open(1) does not forward env or capture NSLog reliably.
    static let launchSmokeStatusPath = "/tmp/maosdevops-launch-smoke.status"

    private var mainWindowController: MainWindowController?
    private let updateChecker = UpdateChecker()
    private var updateCheckInProgress = false
    private let isLaunchSmokeTest = ProcessInfo.processInfo.arguments.contains("--launch-smoke-test")
    private var smokeWatchdog: DispatchWorkItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        stageLog("willFinishLaunching")
        // Must be a regular app or Dock/window activation stays broken.
        NSApp.setActivationPolicy(.regular)
        configureMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        stageLog("didFinishLaunching")

        // Show UI first. Storage/network must never block the first paint.
        showMainWindow()
        stageLog("mainWindowShown")

        if isLaunchSmokeTest {
            armSmokeWatchdog(seconds: 15)
            // Defer one run-loop turn so AppKit can finish ordering the window.
            DispatchQueue.main.async { [weak self] in
                self?.verifyLaunchForSmokeTest()
            }
            return
        }

        bootstrapServicesInBackground()

        // Do not delay the first window with a network request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkForUpdatesAutomaticallyIfNeeded()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApp.windows.allSatisfy({ !$0.isVisible }) {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isLaunchSmokeTest
    }

    func applicationWillTerminate(_ notification: Notification) {
        smokeWatchdog?.cancel()
        if !isLaunchSmokeTest {
            AppServices.shared.shutdown()
        }
    }

    private func showMainWindow() {
        stageLog("showMainWindow.begin")
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
            stageLog("showMainWindow.controllerCreated")
        }

        guard let window = mainWindowController?.window else {
            stageLog("showMainWindow.FAILED_nil_window")
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        stageLog("showMainWindow.ordered visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(NSStringFromRect(window.frame))")
    }

    private func bootstrapServicesInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            AppServices.shared.bootstrap()
            DispatchQueue.main.async {
                self?.stageLog("bootstrapCompleted")
                NotificationCenter.default.post(name: .appServicesDidBootstrap, object: nil)
            }
        }
    }

    // MARK: - Launch smoke test

    private func armSmokeWatchdog(seconds: Int) {
        let work = DispatchWorkItem { [weak self] in
            self?.finishSmokeTest(success: false, reason: "watchdog timeout after \(seconds)s")
        }
        smokeWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func verifyLaunchForSmokeTest() {
        stageLog("smoke.verify.begin")
        guard let window = mainWindowController?.window else {
            finishSmokeTest(success: false, reason: "main window is nil")
            return
        }
        // Force another order-front in case LaunchServices activated us late.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let hasContent = window.contentViewController != nil
        let hasSize = window.frame.width > 100 && window.frame.height > 100
        // On some CI hosts `isVisible` stays false even for a valid on-screen window.
        // Accept: non-nil content + real frame + window is in NSApp.windows.
        let listed = NSApp.windows.contains(where: { $0 === window })
        let ok = hasContent && hasSize && listed

        stageLog("smoke.verify hasContent=\(hasContent) hasSize=\(hasSize) listed=\(listed) isVisible=\(window.isVisible)")
        if ok {
            finishSmokeTest(success: true, reason: "window ready")
        } else {
            finishSmokeTest(success: false, reason: "window not ready (content=\(hasContent) size=\(hasSize) listed=\(listed) visible=\(window.isVisible))")
        }
    }

    private func finishSmokeTest(success: Bool, reason: String) {
        smokeWatchdog?.cancel()
        smokeWatchdog = nil
        stageLog(success ? "smoke.PASS \(reason)" : "smoke.FAIL \(reason)")
        writeSmokeStatus(success: success, reason: reason)
        AppServices.shared.shutdown()
        // Hard exit — do not rely on AppKit terminate (can hang in headless CI).
        exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private func writeSmokeStatus(success: Bool, reason: String) {
        let body = """
        success=\(success ? "1" : "0")
        reason=\(reason)
        pid=\(ProcessInfo.processInfo.processIdentifier)
        """
        try? body.write(toFile: Self.launchSmokeStatusPath, atomically: true, encoding: .utf8)
    }

    private func stageLog(_ message: String) {
        let line = "[MaosDevOps] \(message)"
        NSLog("%@", line)
        // Append stages so package.sh can annotate even when open(1) swallows stdout.
        if isLaunchSmokeTest {
            let path = Self.launchSmokeStatusPath + ".log"
            let stamp = ISO8601DateFormatter().string(from: Date())
            let entry = "\(stamp) \(message)\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) { handle.write(data) }
                handle.closeFile()
            } else {
                try? entry.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Menu / updates

    private func configureMainMenu() {
        let menuBar = NSMenu(title: "Main Menu")
        NSApp.mainMenu = menuBar

        let appMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        let appMenu = NSMenu(title: "MaosDevOps")
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: "About MaosDevOps",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "Hide MaosDevOps",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit MaosDevOps",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let editMenuItem = NSMenuItem()
        menuBar.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        menuBar.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        performUpdateCheck(userInitiated: true)
    }

    private func checkForUpdatesAutomaticallyIfNeeded() {
        let defaults = UserDefaults.standard
        if let lastCheck = defaults.object(forKey: Self.automaticUpdateCheckDateKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 24 * 60 * 60 {
            return
        }
        performUpdateCheck(userInitiated: false)
    }

    private func performUpdateCheck(userInitiated: Bool) {
        guard !updateCheckInProgress else { return }
        updateCheckInProgress = true

        updateChecker.check { [weak self] result in
            guard let self = self else { return }
            self.updateCheckInProgress = false

            switch result {
            case .success(.updateAvailable(let release)):
                UserDefaults.standard.set(Date(), forKey: Self.automaticUpdateCheckDateKey)
                self.presentAvailableUpdate(release)
            case .success(.upToDate(let version)):
                UserDefaults.standard.set(Date(), forKey: Self.automaticUpdateCheckDateKey)
                if userInitiated { self.presentUpToDate(version: version) }
            case .failure(let error):
                NSLog("[MaosDevOps] Update check failed: \(error.localizedDescription)")
                if userInitiated { self.presentUpdateError(error) }
            }
        }
    }

    private func presentAvailableUpdate(_ release: AppRelease) {
        let alert = NSAlert()
        alert.messageText = "MaosDevOps \(release.version) is available"
        alert.informativeText = "You are running \(currentVersion). Open the GitHub release to download the new DMG."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Release")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private func presentUpToDate(version: String) {
        let alert = NSAlert()
        alert.messageText = "MaosDevOps is up to date"
        alert.informativeText = "Version \(version) is the latest available release."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentUpdateError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Unable to check for updates"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
