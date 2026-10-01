import Cocoa
import Darwin

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let automaticUpdateCheckDateKey = "MaosDevOps.lastAutomaticUpdateCheck"

    private var mainWindowController: MainWindowController?
    private let updateChecker = UpdateChecker()
    private var updateCheckInProgress = false
    private let isLaunchSmokeTest = ProcessInfo.processInfo.arguments.contains("--launch-smoke-test")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSLog("[MaosDevOps] Application will finish launching")
        NSApp.setActivationPolicy(.regular)
        configureMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[MaosDevOps] Application did finish launching")
        AppServices.shared.bootstrap()
        NSLog("[MaosDevOps] Storage bootstrap completed")
        showMainWindow()

        if isLaunchSmokeTest {
            verifyLaunchForSmokeTest()
            return
        }

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
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.shutdown()
    }

    private func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }

        guard let window = mainWindowController?.window else {
            NSLog("[MaosDevOps] Failed to create the main window")
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSLog("[MaosDevOps] Main window ordered to front; visible=\(window.isVisible)")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func verifyLaunchForSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let window = self?.mainWindowController?.window, window.isVisible else {
                NSLog("[MaosDevOps] Launch smoke test failed: the main window is not visible")
                exit(EXIT_FAILURE)
            }
            NSLog("[MaosDevOps] Launch smoke test passed: main window is visible")
            AppServices.shared.shutdown()
            exit(EXIT_SUCCESS)
        }
    }

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
