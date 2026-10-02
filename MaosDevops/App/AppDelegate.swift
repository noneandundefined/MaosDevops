import Cocoa
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared with Scripts/package.sh — open(1) does not forward env or capture NSLog reliably.
    static let launchSmokeStatusPath = "/tmp/maosdevops-launch-smoke.status"
    static let launchSmokeRequestPath = "/tmp/maosdevops-launch-smoke.request"

    private var mainWindowController: MainWindowController?
    private var updateController: UpdateController?
    private var updateTimer: Timer?
    private lazy var isLaunchSmokeTest: Bool = {
        let requestedByArgument = ProcessInfo.processInfo.arguments.contains("--launch-smoke-test")
        let requestedByFile = FileManager.default.fileExists(atPath: Self.launchSmokeRequestPath)
        if requestedByFile {
            try? FileManager.default.removeItem(atPath: Self.launchSmokeRequestPath)
        }
        return requestedByArgument || requestedByFile
    }()
    private var smokeWatchdog: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        stageLog("didFinishLaunching")
        NSApp.appearance = nil
        configureMainMenu()

        // Follow the same startup order as MaosVPN: build and retain the controller,
        // attach its content, then show the window and activate the application.
        ensureMainWindowController()
        showMainWindow()
        if let window = mainWindowController?.window {
            updateController = UpdateController(presentingWindow: window)
        }

        if isLaunchSmokeTest {
            armSmokeWatchdog(seconds: 15)
            DispatchQueue.main.async { [weak self] in
                self?.verifyLaunchForSmokeTest()
            }
            return
        }

        bootstrapServicesInBackground()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.updateController?.checkAutomatically()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.updateController?.checkAutomatically()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApp.windows.allSatisfy({ !$0.isVisible }) {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        stageLog("handleReopen hasVisibleWindows=\(flag)")
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        smokeWatchdog?.cancel()
        updateTimer?.invalidate()
        if !isLaunchSmokeTest {
            AppServices.shared.shutdown()
        }
    }

    private func ensureMainWindowController() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
            stageLog("controllerCreated")
        }
    }

    private func showMainWindow() {
        stageLog("showMainWindow.begin")
        ensureMainWindowController()
        guard let controller = mainWindowController, let window = controller.window else {
            stageLog("showMainWindow.FAILED_nil_window")
            return
        }
        // Loading the view before ordering the window avoids an empty first frame
        // on Catalina and makes construction failures visible during startup.
        _ = window.contentViewController?.view
        controller.showWindow(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        stageLog("showMainWindow.ordered visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(NSStringFromRect(window.frame)) appWindows=\(NSApp.windows.count)")
    }

    @objc private func showMainWindowMenuAction(_ sender: Any?) {
        showMainWindow()
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
        mainWindowController?.forcePresent()
        NSApp.activate(ignoringOtherApps: true)

        guard let window = mainWindowController?.window else {
            finishSmokeTest(success: false, reason: "main window is nil after forcePresent")
            return
        }

        let hasContent = window.contentViewController != nil
        let hasSize = window.frame.width > 100 && window.frame.height > 100
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
        // Always persist startup stages — used for local diagnosis and CI smoke tests.
        let path = "/tmp/maosdevops-startup.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) { handle.write(data) }
            handle.closeFile()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if isLaunchSmokeTest {
            let smokeLog = Self.launchSmokeStatusPath + ".log"
            if let handle = FileHandle(forWritingAtPath: smokeLog) {
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) { handle.write(data) }
                handle.closeFile()
            } else {
                try? entry.write(toFile: smokeLog, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Menu / updates

    private func configureMainMenu() {
        let menuBar = NSMenu(title: "Main Menu")
        NSApp.mainMenu = menuBar

        let appMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Maos DevOps")
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: L10n.text("About Maos DevOps"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)

        let updateItem = NSMenuItem(
            title: L10n.text("Check for Updates…"),
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        appMenu.addItem(updateItem)

        let languageItem = NSMenuItem(title: L10n.text("Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: L10n.text("Language"))
        for language in InterfaceLanguage.allCases {
            let item = NSMenuItem(title: language.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = L10n.language == language ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        appMenu.addItem(languageItem)
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: L10n.text("Hide Maos DevOps"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: L10n.text("Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: L10n.text("Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.text("Quit Maos DevOps"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let editMenuItem = NSMenuItem()
        menuBar.addItem(editMenuItem)
        let editMenu = NSMenu(title: L10n.language == .russian ? "Правка" : "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: L10n.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.text("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        menuBar.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: L10n.text("Window"))
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: L10n.text("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.text("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let showMain = NSMenuItem(
            title: L10n.text("Show Maos DevOps Window"),
            action: #selector(showMainWindowMenuAction(_:)),
            keyEquivalent: "0"
        )
        showMain.target = self
        windowMenu.addItem(showMain)
        windowMenu.addItem(withTitle: L10n.text("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updateController?.checkForUpdates(silent: false)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = InterfaceLanguage(rawValue: raw),
              language != L10n.language else { return }

        L10n.language = language
        let oldFrame = mainWindowController?.window?.frame
        mainWindowController?.close()
        mainWindowController = MainWindowController()
        if let frame = oldFrame { mainWindowController?.window?.setFrame(frame, display: false) }
        configureMainMenu()
        showMainWindow()
        if let window = mainWindowController?.window {
            updateController = UpdateController(presentingWindow: window)
        }
    }
}
