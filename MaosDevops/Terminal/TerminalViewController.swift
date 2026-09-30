import Cocoa

/// Simple multi-tab SSH terminal. Commands run off the main thread.
final class TerminalViewController: NSViewController, NSTabViewDelegate {
    private let server: Server
    private let tabView = NSTabView()
    private let toolbar = NSStackView()
    private var sessions: [UUID: TerminalSessionController] = [:]

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()

        let newTab = NSButton(title: "+ Tab", target: self, action: #selector(addTab))
        let closeTab = NSButton(title: "Close Tab", target: self, action: #selector(closeCurrentTab))
        let reconnect = NSButton(title: "Reconnect", target: self, action: #selector(reconnectCurrent))
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.addArrangedSubview(newTab)
        toolbar.addArrangedSubview(closeTab)
        toolbar.addArrangedSubview(reconnect)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),

            tabView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addTab()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Keep SSH ControlMaster; only release terminal processes when leaving
    }

    @objc private func addTab() {
        let id = UUID()
        let session = TerminalSessionController(server: server)
        sessions[id] = session
        let item = NSTabViewItem(identifier: id.uuidString)
        item.label = "SSH \(sessions.count)"
        item.viewController = session
        tabView.addTabViewItem(item)
        tabView.select(item)
        session.connect()
    }

    @objc private func reconnectCurrent() {
        guard let idString = tabView.selectedTabViewItem?.identifier as? String,
              let id = UUID(uuidString: idString),
              let session = sessions[id] else { return }
        session.reconnect()
    }

    @objc private func closeCurrentTab() {
        guard let item = tabView.selectedTabViewItem,
              let idString = item.identifier as? String,
              let id = UUID(uuidString: idString) else { return }
        tabView.removeTabViewItem(item)
        sessions[id] = nil
        if tabView.numberOfTabViewItems == 0 {
            addTab()
        }
    }
}

final class TerminalSessionController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    private let server: Server
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let inputField = NSTextField()
    private var history: [String] = []
    private var historyIndex = 0
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var connectionGeneration = UUID()
    private var lastTerminalSize = NSSize.zero
    private let maxCharacters = 200_000

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
                let process = try AppServices.shared.sshManager.session(for: self.server).makeInteractiveProcess()
                let input = Pipe()
                let output = Pipe()
                let error = Pipe()
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
                    guard self.connectionGeneration == generation else {
                        process.terminate()
                        return
                    }
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
        AppServices.shared.sshManager.disconnect(serverId: server.id)
        connect()
    }

    @objc private func sendCommand() {
        let cmd = inputField.stringValue
        guard !cmd.isEmpty else { return }
        history.append(cmd)
        historyIndex = history.count
        inputField.stringValue = ""
        append("$ \(cmd)\n")

        guard let data = (cmd + "\n").data(using: .utf8), let stdinHandle = stdinHandle else {
            append("Not connected. Press Reconnect.\n")
            return
        }
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            append("Write failed: \(error.localizedDescription)\n")
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateRemoteTerminalSizeIfNeeded()
    }

    deinit {
        disconnectProcess()
    }

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
        let command = "stty cols \(columns) rows \(rows) >/dev/null 2>&1\n"
        if let data = command.data(using: .utf8) {
            try? stdinHandle.write(contentsOf: data)
        }
    }

    private func append(_ text: String) {
        let storage = textView.textStorage ?? NSTextStorage()
        storage.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]))
        // Cap buffer — do not keep infinite stdout in RAM / NSTextView
        if storage.length > maxCharacters {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maxCharacters))
        }
        textView.scrollToEndOfDocument(nil)
    }

    private func moveHistory(_ direction: Int) {
        if direction < 0, historyIndex > 0 {
            historyIndex -= 1
            inputField.stringValue = history[historyIndex]
        } else if direction > 0 {
            if historyIndex + 1 < history.count {
                historyIndex += 1
                inputField.stringValue = history[historyIndex]
            } else {
                historyIndex = history.count
                inputField.stringValue = ""
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveHistory(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveHistory(1)
            return true
        }
        return false
    }
}
