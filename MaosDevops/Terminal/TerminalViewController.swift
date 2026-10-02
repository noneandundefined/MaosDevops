import Cocoa

private enum TerminalCommandStore {
    private static let historyLimit = 500

    private static func historyKey(_ server: Server) -> String {
        "terminal.history.\(server.id.uuidString)"
    }

    private static func favoritesKey(_ server: Server) -> String {
        "terminal.favorites.\(server.id.uuidString)"
    }

    static func history(for server: Server) -> [String] {
        UserDefaults.standard.stringArray(forKey: historyKey(server)) ?? []
    }

    static func addToHistory(_ command: String, server: Server) -> [String] {
        var values = history(for: server)
        if values.last != command { values.append(command) }
        if values.count > historyLimit { values.removeFirst(values.count - historyLimit) }
        UserDefaults.standard.set(values, forKey: historyKey(server))
        return values
    }

    static func favorites(for server: Server) -> [String] {
        UserDefaults.standard.stringArray(forKey: favoritesKey(server)) ?? []
    }

    static func addFavorite(_ command: String, server: Server) {
        var values = favorites(for: server)
        guard !values.contains(command) else { return }
        values.append(command)
        UserDefaults.standard.set(values, forKey: favoritesKey(server))
    }

    static func removeFavorite(_ command: String, server: Server) {
        UserDefaults.standard.set(favorites(for: server).filter { $0 != command }, forKey: favoritesKey(server))
    }
}

private enum TerminalCommandSafety {
    static func warning(for command: String) -> String? {
        let value = command.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let dangerous: [(String, String)] = [
            ("rm -rf", "This command can permanently delete files recursively."),
            ("rm -fr", "This command can permanently delete files recursively."),
            ("rm -r ", "This command can permanently delete files recursively."),
            ("mkfs", "This command can erase a disk or partition."),
            ("dd if=", "This command can overwrite disks or files."),
            ("shutdown", "This command can shut down the server."),
            ("reboot", "This command can restart the server."),
            ("poweroff", "This command can power off the server."),
            ("docker system prune", "This command can remove unused Docker data."),
            ("docker volume rm", "This command can permanently remove Docker data."),
            ("docker rm", "This command can permanently remove containers."),
            ("docker compose down -v", "This command can remove Docker volumes and their data."),
            ("git reset --hard", "This command discards uncommitted changes."),
            ("git clean -f", "This command permanently removes untracked files."),
            ("git push --force", "This command can overwrite remote Git history."),
            ("systemctl stop", "This command can interrupt a server service."),
            ("systemctl disable", "This command disables a server service."),
            ("drop database", "This command permanently removes a database."),
            ("truncate table", "This command permanently removes table data."),
            ("chmod -r", "This command changes permissions recursively."),
            ("chown -r", "This command changes ownership recursively.")
        ]
        return dangerous.first(where: { value.contains($0.0) })?.1
    }

    static func confirm(_ command: String) -> Bool {
        guard let warning = warning(for: command) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Potentially dangerous command"
        alert.informativeText = "\(warning)\n\n\(command)"
        alert.addButton(withTitle: "Run anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Multi-tab SSH terminal with persistent history and favorite commands.
final class TerminalViewController: NSViewController, NSTabViewDelegate {
    private let server: Server
    private let remoteCommand: String
    private let dismissable: Bool
    private let tabView = NSTabView()
    private let toolbar = NSStackView()
    private let favoritesPopup = NSPopUpButton()
    private var sessions: [UUID: TerminalSessionController] = [:]
    private var nextSessionNumber = 1

    init(server: Server, remoteCommand: String = "export TERM=xterm-256color; exec ${SHELL:-/bin/sh} -l", dismissable: Bool = false) {
        self.server = server
        self.remoteCommand = remoteCommand
        self.dismissable = dismissable
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 440))
        let sessionRow = NSStackView(views: [
            NSButton(title: "+ Tab", target: self, action: #selector(addTab)),
            NSButton(title: "Close Tab", target: self, action: #selector(closeCurrentTab)),
            NSButton(title: "Reconnect", target: self, action: #selector(reconnectCurrent))
        ])
        sessionRow.orientation = .horizontal
        sessionRow.spacing = 6
        if dismissable {
            sessionRow.addArrangedSubview(NSButton(title: "Close", target: self, action: #selector(closeSheet)))
        }

        favoritesPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let favoriteRow = NSStackView(views: [
            favoritesPopup,
            NSButton(title: "Run Favorite", target: self, action: #selector(runFavorite)),
            NSButton(title: "Add Favorite", target: self, action: #selector(addFavorite)),
            NSButton(title: "Remove", target: self, action: #selector(removeFavorite))
        ])
        favoriteRow.orientation = .horizontal
        favoriteRow.spacing = 6

        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 5
        toolbar.addArrangedSubview(sessionRow)
        toolbar.addArrangedSubview(favoriteRow)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            favoritesPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            tabView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        L10n.apply(to: root)
        view = root
        refreshFavorites()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addTab()
    }

    @objc private func addTab() {
        let id = UUID()
        let session = TerminalSessionController(server: server, remoteCommand: remoteCommand)
        sessions[id] = session
        let item = NSTabViewItem(identifier: id.uuidString)
        item.label = "SSH \(nextSessionNumber)"
        nextSessionNumber += 1
        item.viewController = session
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        session.connect()
    }

    @objc private func reconnectCurrent() { currentSession()?.reconnect() }

    @objc private func closeCurrentTab() {
        guard let item = tabView.selectedTabViewItem,
              let idString = item.identifier as? String,
              let id = UUID(uuidString: idString) else { return }
        tabView.removeTabViewItem(item)
        sessions[id] = nil
        if tabView.numberOfTabViewItems == 0 { addTab() }
    }

    @objc private func addFavorite() {
        var command = currentSession()?.commandText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if command.isEmpty {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = "Command"
            let alert = NSAlert()
            alert.messageText = "Add favorite command"
            alert.accessoryView = field
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            command = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !command.isEmpty else { return }
        TerminalCommandStore.addFavorite(command, server: server)
        refreshFavorites(selecting: command)
    }

    @objc private func runFavorite() {
        guard favoritesPopup.indexOfSelectedItem > 0,
              let command = favoritesPopup.selectedItem?.representedObject as? String else { return }
        currentSession()?.runCommand(command)
    }

    @objc private func removeFavorite() {
        guard favoritesPopup.indexOfSelectedItem > 0,
              let command = favoritesPopup.selectedItem?.representedObject as? String else { return }
        TerminalCommandStore.removeFavorite(command, server: server)
        refreshFavorites()
    }

    private func refreshFavorites(selecting command: String? = nil) {
        favoritesPopup.removeAllItems()
        favoritesPopup.addItem(withTitle: "Favorite commands")
        favoritesPopup.lastItem?.isEnabled = false
        for favorite in TerminalCommandStore.favorites(for: server) {
            favoritesPopup.addItem(withTitle: favorite)
            favoritesPopup.lastItem?.representedObject = favorite
        }
        if let command = command,
           let item = favoritesPopup.itemArray.first(where: { ($0.representedObject as? String) == command }) {
            favoritesPopup.select(item)
        } else {
            favoritesPopup.selectItem(at: 0)
        }
    }

    private func currentSession() -> TerminalSessionController? {
        guard let idString = tabView.selectedTabViewItem?.identifier as? String,
              let id = UUID(uuidString: idString) else { return nil }
        return sessions[id]
    }

    @objc private func closeSheet() { dismiss(nil) }
}

final class TerminalSessionController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    private let server: Server
    private let remoteCommand: String
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let inputField = NSTextField()
    private var history: [String]
    private var historyIndex: Int
    private var historyDraft = ""
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var connectionGeneration = UUID()
    private var lastTerminalSize = NSSize.zero
    private let maxCharacters = 200_000

    init(server: Server, remoteCommand: String = "export TERM=xterm-256color; exec ${SHELL:-/bin/sh} -l") {
        self.server = server
        self.remoteCommand = remoteCommand
        self.history = TerminalCommandStore.history(for: server)
        self.historyIndex = self.history.count
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var commandText: String { inputField.stringValue }

    override func loadView() {
        let root = NSView()
        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.textColor
        textView.autoresizingMask = [.width]
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        inputField.placeholderString = "Command — Enter to send"
        inputField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        inputField.target = self
        inputField.action = #selector(sendCommand)
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false
        let send = NSButton(title: "Send", target: self, action: #selector(sendCommand))
        send.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(inputField)
        root.addSubview(send)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -6),
            inputField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            inputField.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            inputField.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -8),
            send.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            send.centerYAnchor.constraint(equalTo: inputField.centerYAnchor)
        ])
        L10n.apply(to: root)
        view = root
    }

    func connect() {
        disconnectProcess()
        let generation = UUID()
        connectionGeneration = generation
        append("Connecting to \(server.username)@\(server.host)…\n")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let process = try AppServices.shared.sshManager.session(for: self.server)
                    .makeInteractiveProcess(remoteCommand: self.remoteCommand)
                let input = Pipe(), output = Pipe(), error = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = error
                let consume: (FileHandle) -> Void = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async { self?.append(text) }
                }
                output.fileHandleForReading.readabilityHandler = consume
                error.fileHandleForReading.readabilityHandler = consume
                process.terminationHandler = { [weak self] process in
                    output.fileHandleForReading.readabilityHandler = nil
                    error.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.main.async {
                        guard let self = self, self.connectionGeneration == generation else { return }
                        self.process = nil
                        self.stdinHandle = nil
                        self.stdoutHandle = nil
                        self.stderrHandle = nil
                        self.append("\n[SSH disconnected: \(process.terminationStatus)]\n")
                    }
                }
                try process.run()
                DispatchQueue.main.async {
                    guard self.connectionGeneration == generation else { process.terminate(); return }
                    self.process = process
                    self.stdinHandle = input.fileHandleForWriting
                    self.stdoutHandle = output.fileHandleForReading
                    self.stderrHandle = error.fileHandleForReading
                    self.append("Connected. This tab uses a persistent multiplexed SSH shell.\n\n")
                    self.updateRemoteTerminalSizeIfNeeded()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.connectionGeneration == generation else { return }
                    self.append("Connection failed: \(error.localizedDescription)\n")
                }
            }
        }
    }

    func reconnect() {
        disconnectProcess()
        connect()
    }

    func runCommand(_ command: String) {
        inputField.stringValue = command
        sendCommand()
    }

    @objc private func sendCommand() {
        let command = inputField.stringValue.trimmingCharacters(in: .newlines)
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard TerminalCommandSafety.confirm(command) else { return }
        history = TerminalCommandStore.addToHistory(command, server: server)
        historyIndex = history.count
        historyDraft = ""
        inputField.stringValue = ""

        if ["clear", "cls"].contains(command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            textView.string = ""
            return
        }

        append("$ \(command)\n")
        guard let data = (command + "\n").data(using: .utf8), let stdinHandle = stdinHandle else {
            append("Not connected. Press Reconnect.\n")
            return
        }
        stdinHandle.write(data)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateRemoteTerminalSizeIfNeeded()
    }

    deinit { disconnectProcess() }

    private func disconnectProcess() {
        connectionGeneration = UUID()
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdinHandle?.closeFile()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
    }

    private func updateRemoteTerminalSizeIfNeeded() {
        guard let stdinHandle = stdinHandle else { return }
        let size = scrollView.contentSize
        guard size.width > 0, size.height > 0, size != lastTerminalSize else { return }
        lastTerminalSize = size
        let columns = max(20, Int(size.width / 7.3))
        let rows = max(5, Int(size.height / 15.0))
        if let data = "stty cols \(columns) rows \(rows) >/dev/null 2>&1\n".data(using: .utf8) {
            stdinHandle.write(data)
        }
    }

    private func append(_ text: String) {
        let clean = text
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "")
        let storage = textView.textStorage ?? NSTextStorage()
        storage.append(NSAttributedString(string: clean, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]))
        if storage.length > maxCharacters {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maxCharacters))
        }
        textView.scrollToEndOfDocument(nil)
    }

    private func moveHistory(_ direction: Int) {
        history = TerminalCommandStore.history(for: server)
        if direction < 0, historyIndex > 0 {
            if historyIndex == history.count { historyDraft = inputField.stringValue }
            historyIndex -= 1
            inputField.stringValue = history[historyIndex]
        } else if direction > 0, historyIndex < history.count {
            historyIndex += 1
            inputField.stringValue = historyIndex < history.count ? history[historyIndex] : historyDraft
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) { moveHistory(-1); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { moveHistory(1); return true }
        return false
    }
}
