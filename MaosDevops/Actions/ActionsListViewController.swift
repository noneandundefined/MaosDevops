import Cocoa

final class ActionsListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var actions: [CustomAction] = []
    private let outputView = NSTextView()

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Custom Actions")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: "Add Action", target: self, action: #selector(addAction))
        let run = NSButton(title: "Run", target: self, action: #selector(runSelected))
        let stop = NSButton(title: "Stop", target: self, action: #selector(stopSelected))
        let edit = NSButton(title: "Edit", target: self, action: #selector(editSelected))
        let del = NSButton(title: "Delete", target: self, action: #selector(deleteSelected))
        let bar = NSStackView(views: [add, run, stop, edit, del])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        for (id, t, w) in [("name", "Name", 180), ("type", "Type", 80), ("server", "Server", 140), ("cmd", "Command", 320)] as [(String, String, CGFloat)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = t
            col.width = w
            table.addTableColumn(col)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        outputView.isEditable = false
        outputView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let outScroll = NSScrollView()
        outScroll.documentView = outputView
        outScroll.hasVerticalScroller = true
        outScroll.borderType = .bezelBorder
        outScroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(bar)
        root.addSubview(scroll)
        root.addSubview(outScroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bar.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 280),
            outScroll.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            outScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            outScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            outScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        L10n.apply(to: root)
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        actions = (try? AppServices.shared.storage.allActions()) ?? []
        table.reloadData()
    }

    private func selected() -> CustomAction? {
        let row = table.selectedRow
        guard row >= 0, row < actions.count else { return nil }
        return actions[row]
    }

    @objc private func addAction() {
        presentAsSheet(ActionEditorViewController(action: nil) { [weak self] in self?.reload() })
    }

    @objc private func editSelected() {
        guard let a = selected() else { return }
        presentAsSheet(ActionEditorViewController(action: a) { [weak self] in self?.reload() })
    }

    @objc private func deleteSelected() {
        guard let a = selected() else { return }
        AppServices.shared.actions.stop(actionId: a.id)
        try? AppServices.shared.storage.deleteAction(id: a.id)
        reload()
    }

    @objc private func stopSelected() {
        guard let a = selected() else { return }
        AppServices.shared.actions.stop(actionId: a.id)
        outputView.string += "\n[stopped \(a.name)]\n"
    }

    @objc private func runSelected() {
        guard let action = selected() else { return }
        if action.confirmationRequired {
            let alert = NSAlert()
            alert.messageText = "Run \(action.name)?"
            alert.informativeText = action.command
            alert.addButton(withTitle: "Run")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let serverId = action.serverId,
              let server = ((try? AppServices.shared.storage.allServers()) ?? []).first(where: { $0.id == serverId }) else {
            outputView.string = "Action has no server assigned."
            return
        }
        outputView.string = "Running \(action.name)…\n"
        AppServices.shared.actions.run(action, server: server, onOutput: { [weak self] chunk in
            self?.appendOutput(chunk)
        }, completion: { [weak self] result in
            switch result {
            case .success(let r):
                self?.appendOutput(r.stdout)
                if r.exitCode != 0 { self?.appendOutput("\n[exit \(r.exitCode)]\n") }
            case .failure(let e):
                self?.appendOutput(e.localizedDescription)
            }
        })
    }

    private func appendOutput(_ text: String) {
        let maxChars = 100_000
        var s = outputView.string + text
        if s.count > maxChars {
            s = String(s.suffix(maxChars))
        }
        outputView.string = s
        outputView.scrollToEndOfDocument(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let a = actions[row]
        let servers = (try? AppServices.shared.storage.allServers()) ?? []
        let serverName = servers.first(where: { $0.id == a.serverId })?.name ?? "—"
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = a.name + (a.isPinnedQuickAction ? " ★" : "")
        case "type": value = a.type.rawValue
        case "server": value = serverName
        case "cmd": value = a.command.replacingOccurrences(of: "\n", with: " ; ")
        default: value = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.font = NSFont.systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

final class ActionEditorViewController: NSViewController {
    private var existing: CustomAction?
    private let onSave: () -> Void
    private let nameField = NSTextField(string: "")
    private let serverPopup = NSPopUpButton()
    private let typePopup = NSPopUpButton()
    private let commandView = NSTextView()
    private let intervalField = NSTextField(string: "30")
    private let cwdField = NSTextField(string: "")
    private let environmentView = NSTextView()
    private let displayPopup = NSPopUpButton()
    private let confirmButton = NSButton(checkboxWithTitle: "Confirmation required", target: nil, action: nil)
    private let stopOnErrorButton = NSButton(checkboxWithTitle: "Stop on error", target: nil, action: nil)
    private let pinButton = NSButton(checkboxWithTitle: "Pin as Quick Action", target: nil, action: nil)

    init(action: CustomAction?, onSave: @escaping () -> Void) {
        self.existing = action
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 620))
        let servers = (try? AppServices.shared.storage.allServers()) ?? []
        serverPopup.removeAllItems()
        serverPopup.addItem(withTitle: "—")
        servers.forEach { serverPopup.addItem(withTitle: $0.name) }
        typePopup.removeAllItems()
        typePopup.addItems(withTitles: ActionType.allCases.map(\.rawValue))
        displayPopup.removeAllItems()
        displayPopup.addItems(withTitles: ActionDisplayType.allCases.map(\.rawValue))

        if let a = existing {
            nameField.stringValue = a.name
            typePopup.selectItem(withTitle: a.type.rawValue)
            commandView.string = a.command
            intervalField.stringValue = "\(a.intervalSeconds)"
            cwdField.stringValue = a.workingDirectory ?? ""
            environmentView.string = a.environment.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
            displayPopup.selectItem(withTitle: a.displayType.rawValue)
            confirmButton.state = a.confirmationRequired ? .on : .off
            stopOnErrorButton.state = a.stopOnError ? .on : .off
            pinButton.state = a.isPinnedQuickAction ? .on : .off
            if let sid = a.serverId, let s = servers.first(where: { $0.id == sid }) {
                serverPopup.selectItem(withTitle: s.name)
            }
        } else {
            stopOnErrorButton.state = .on
        }

        commandView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let cmdScroll = NSScrollView(frame: .zero)
        cmdScroll.documentView = commandView
        cmdScroll.hasVerticalScroller = true
        cmdScroll.borderType = .bezelBorder
        cmdScroll.translatesAutoresizingMaskIntoConstraints = false
        cmdScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true

        environmentView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let environmentScroll = NSScrollView(frame: .zero)
        environmentScroll.documentView = environmentView
        environmentScroll.hasVerticalScroller = true
        environmentScroll.borderType = .bezelBorder
        environmentScroll.translatesAutoresizingMaskIntoConstraints = false
        environmentScroll.heightAnchor.constraint(equalToConstant: 50).isActive = true

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 5
        form.translatesAutoresizingMaskIntoConstraints = false

        func field(_ title: String, _ view: NSView) -> NSView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 460).isActive = true
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(view)
            return stack
        }

        form.addArrangedSubview(field("Name", nameField))
        form.addArrangedSubview(field("Server", serverPopup))
        form.addArrangedSubview(field("Type", typePopup))
        form.addArrangedSubview(field("Command (one per line for Action Group)", cmdScroll))
        form.addArrangedSubview(field("Interval seconds (Poll/Check)", intervalField))
        form.addArrangedSubview(field("Working directory", cwdField))
        form.addArrangedSubview(field("Environment (KEY=VALUE, one per line)", environmentScroll))
        form.addArrangedSubview(field("Display type", displayPopup))
        form.addArrangedSubview(confirmButton)
        form.addArrangedSubview(stopOnErrorButton)
        form.addArrangedSubview(pinButton)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(form)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        L10n.apply(to: root)
        view = root
    }

    @objc private func cancel() { dismiss(nil) }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let servers = (try? AppServices.shared.storage.allServers()) ?? []
        let serverId: UUID?
        if serverPopup.indexOfSelectedItem > 0 {
            serverId = servers[serverPopup.indexOfSelectedItem - 1].id
        } else {
            serverId = existing?.serverId
        }
        var action = existing ?? CustomAction(name: name)
        action.name = name
        action.serverId = serverId
        action.type = ActionType(rawValue: typePopup.titleOfSelectedItem ?? "command") ?? .command
        action.command = commandView.string
        action.intervalSeconds = Int(intervalField.stringValue) ?? 30
        action.workingDirectory = cwdField.stringValue.isEmpty ? nil : cwdField.stringValue
        var environment: [String: String] = [:]
        environmentView.string
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (key, String(parts[1]))
            }
            .forEach { environment[$0.0] = $0.1 }
        action.environment = environment
        action.displayType = ActionDisplayType(rawValue: displayPopup.titleOfSelectedItem ?? "output") ?? .output
        action.confirmationRequired = confirmButton.state == .on
        action.stopOnError = stopOnErrorButton.state == .on
        action.isPinnedQuickAction = pinButton.state == .on
        action.updatedAt = Date()
        try? AppServices.shared.storage.saveAction(action)
        onSave()
        dismiss(nil)
    }
}

final class ServerActionsViewController: NSViewController {
    private let server: Server
    private let list = ActionsListViewController()

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(list.view)
        NSLayoutConstraint.activate([
            list.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.view.topAnchor.constraint(equalTo: root.topAnchor),
            list.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        L10n.apply(to: root)
        view = root
    }
}


// MARK: - Server-side scheduled execution

/// Commands created here are scheduled on the remote server. Once the timer/job
/// has been accepted by systemd (or `at` as a fallback), the Mac application can
/// be closed and the remote job will still run.
final class ScheduledExecutionViewController: NSViewController, NSTextViewDelegate {
    private var servers: [Server] = []
    private var loadedScriptURL: URL?
    private var isLoadingScriptPreview = false

    private let serverPopup = NSPopUpButton()
    private let datePicker = NSDatePicker()
    private let commandView = NSTextView()
    private let scriptLabel = NSTextField(labelWithString: "Drop a .sh/.bash file here, or enter a command below.")
    private let statusLabel = NSTextField(labelWithString: "")
    private let outputView = NSTextView()
    private lazy var dropView: ScriptDropView = {
        let drop = ScriptDropView()
        drop.onFileDropped = { [weak self] url in self?.loadScript(url) }
        return drop
    }()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 560))

        let title = NSTextField(labelWithString: "Execution")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        serverPopup.translatesAutoresizingMaskIntoConstraints = false
        reloadServers()

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        datePicker.dateValue = Date().addingTimeInterval(300)
        datePicker.translatesAutoresizingMaskIntoConstraints = false

        let serverLabel = NSTextField(labelWithString: "Server")
        let timeLabel = NSTextField(labelWithString: "Run at")
        serverLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        let serverRow = NSStackView(views: [serverLabel, serverPopup, timeLabel, datePicker])
        serverRow.orientation = .horizontal
        serverRow.spacing = 8
        serverRow.translatesAutoresizingMaskIntoConstraints = false

        scriptLabel.textColor = .secondaryLabelColor
        scriptLabel.translatesAutoresizingMaskIntoConstraints = false

        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.heightAnchor.constraint(equalToConstant: 62).isActive = true

        commandView.isRichText = false
        commandView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        commandView.delegate = self
        let commandScroll = NSScrollView()
        commandScroll.documentView = commandView
        commandScroll.hasVerticalScroller = true
        commandScroll.borderType = .bezelBorder
        commandScroll.translatesAutoresizingMaskIntoConstraints = false

        let runNow = NSButton(title: "Run Now", target: self, action: #selector(runNow))
        let schedule = NSButton(title: "Schedule on Server", target: self, action: #selector(schedule))
        let refresh = NSButton(title: "Refresh Jobs", target: self, action: #selector(refreshJobs))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearForm))
        let buttons = NSStackView(views: [runNow, schedule, refresh, clear])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        outputView.isEditable = false
        outputView.isRichText = false
        outputView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let outputScroll = NSScrollView()
        outputScroll.documentView = outputView
        outputScroll.hasVerticalScroller = true
        outputScroll.borderType = .bezelBorder
        outputScroll.translatesAutoresizingMaskIntoConstraints = false

        [title, serverRow, scriptLabel, dropView, commandScroll, buttons, statusLabel, outputScroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            serverRow.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            serverRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            serverRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            serverPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            datePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),

            scriptLabel.topAnchor.constraint(equalTo: serverRow.bottomAnchor, constant: 12),
            scriptLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scriptLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            dropView.topAnchor.constraint(equalTo: scriptLabel.bottomAnchor, constant: 6),
            dropView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            commandScroll.topAnchor.constraint(equalTo: dropView.bottomAnchor, constant: 10),
            commandScroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            commandScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            commandScroll.heightAnchor.constraint(equalToConstant: 150),

            buttons.topAnchor.constraint(equalTo: commandScroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            outputScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            outputScroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            outputScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            outputScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        L10n.apply(to: root)
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadServers()
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoadingScriptPreview, loadedScriptURL != nil else { return }
        loadedScriptURL = nil
        scriptLabel.stringValue = L10n.text("Script preview was edited — the command text will be used.")
        dropView.setDetail(L10n.text("Drop another .sh/.bash file to use the file itself."))
    }

    private func reloadServers() {
        let selectedId: UUID? = {
            let index = serverPopup.indexOfSelectedItem
            guard index >= 0, index < servers.count else { return nil }
            return servers[index].id
        }()

        servers = (try? AppServices.shared.storage.allServers()) ?? []
        serverPopup.removeAllItems()
        if servers.isEmpty {
            serverPopup.addItem(withTitle: L10n.text("Add a server first"))
            serverPopup.isEnabled = false
            return
        }

        serverPopup.isEnabled = true
        serverPopup.addItems(withTitles: servers.map(\.name))
        if let selectedId = selectedId, let index = servers.firstIndex(where: { $0.id == selectedId }) {
            serverPopup.selectItem(at: index)
        } else {
            serverPopup.selectItem(at: 0)
        }
    }

    private func selectedServer() -> Server? {
        let index = serverPopup.indexOfSelectedItem
        guard serverPopup.isEnabled, index >= 0, index < servers.count else { return nil }
        return servers[index]
    }

    @objc private func runNow() {
        performExecution(scheduleDate: nil)
    }

    @objc private func schedule() {
        guard datePicker.dateValue.timeIntervalSinceNow > 1 else {
            setStatus("Choose a future time.")
            return
        }
        performExecution(scheduleDate: datePicker.dateValue)
    }

    @objc private func refreshJobs() {
        guard let server = selectedServer() else {
            setStatus("Add a server first")
            return
        }
        setStatus("Loading server-side jobs…")
        let command = """
        printf 'systemd timers:\\n'
        if command -v systemctl >/dev/null 2>&1; then
          if [ "$(id -u)" -eq 0 ]; then
            systemctl list-timers --all --no-pager --no-legend 'maosdevops-*.timer' 2>/dev/null || true
          else
            systemctl --user list-timers --all --no-pager --no-legend 'maosdevops-*.timer' 2>/dev/null || true
          fi
        fi
        printf '\\nat jobs:\\n'
        if command -v atq >/dev/null 2>&1; then atq 2>/dev/null || true; fi
        """
        AppServices.shared.sshManager.execute(on: server, command: command) { [weak self] result in
            switch result {
            case .success(let value):
                self?.outputView.string = value.stdout + (value.stderr.isEmpty ? "" : "\n" + value.stderr)
                self?.setStatus("Server-side jobs refreshed.")
            case .failure(let error):
                self?.setStatus(error.localizedDescription)
            }
        }
    }

    @objc private func clearForm() {
        loadedScriptURL = nil
        isLoadingScriptPreview = true
        commandView.string = ""
        isLoadingScriptPreview = false
        scriptLabel.stringValue = L10n.text("Drop a .sh/.bash file here, or enter a command below.")
        dropView.setDetail(L10n.text("The file is uploaded to the selected server and can run even after the app is closed."))
        outputView.string = ""
        statusLabel.stringValue = ""
    }

    private func performExecution(scheduleDate: Date?) {
        guard let server = selectedServer() else {
            setStatus("Add a server first")
            return
        }

        let typedCommand = commandView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadedScriptURL != nil || !typedCommand.isEmpty else {
            setStatus("Enter a command or drop a script file.")
            return
        }

        if let scriptURL = loadedScriptURL {
            prepareRemoteScript(scriptURL, on: server) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let payload):
                    self.executePayload(payload, on: server, scheduleDate: scheduleDate)
                case .failure(let error):
                    self.setStatus(error.localizedDescription)
                }
            }
        } else {
            executePayload(typedCommand, on: server, scheduleDate: scheduleDate)
        }
    }

    private func executePayload(_ payload: String, on server: Server, scheduleDate: Date?) {
        if let date = scheduleDate {
            let delay = max(1, Int(ceil(date.timeIntervalSinceNow)))
            let epoch = Int(date.timeIntervalSince1970)
            let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let unit = "maosdevops-" + String(token.prefix(12))
            let command = serverScheduleCommand(
                payload: payload,
                unit: unit,
                delaySeconds: delay,
                targetEpoch: epoch
            )
            setStatus("Creating a server-side job…")
            AppServices.shared.sshManager.execute(on: server, command: command) { [weak self] result in
                switch result {
                case .success(let value) where value.exitCode == 0:
                    let text = value.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.appendOutput((text.isEmpty ? "Scheduled on server." : text) + "\n")
                    self?.setStatus("Scheduled on the server. You can close Maos DevOps or the Mac.")
                case .success(let value):
                    self?.appendOutput(value.stderr + "\n")
                    self?.setStatus("The server could not create a persistent remote job.")
                case .failure(let error):
                    self?.setStatus(error.localizedDescription)
                }
            }
            return
        }

        setStatus("Running on server…")
        AppServices.shared.sshManager.execute(on: server, command: payload) { [weak self] result in
            switch result {
            case .success(let value):
                self?.outputView.string = value.stdout + (value.stderr.isEmpty ? "" : "\n" + value.stderr)
                self?.setStatus("Finished with exit code \(value.exitCode).")
            case .failure(let error):
                self?.setStatus(error.localizedDescription)
            }
        }
    }

    private func prepareRemoteScript(
        _ localURL: URL,
        on server: Server,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            completion(.failure(SSHError.processFailed("The selected script no longer exists.")))
            return
        }

        setStatus("Preparing remote script directory…")
        AppServices.shared.sshManager.execute(on: server, command: "printf '%s' \"$HOME\"") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let value):
                let home = value.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !home.isEmpty else {
                    completion(.failure(SSHError.processFailed("Could not determine remote HOME.")))
                    return
                }

                let remoteDirectory = home + "/.maosdevops/scripts"
                let remoteName = UUID().uuidString.lowercased() + "-" + self.safeRemoteFilename(localURL.lastPathComponent)
                let remotePath = remoteDirectory + "/" + remoteName
                let makeDirectory = "mkdir -p -- \(self.shellQuote(remoteDirectory)) && chmod 700 -- \(self.shellQuote(remoteDirectory))"

                AppServices.shared.sshManager.execute(on: server, command: makeDirectory) { mkdirResult in
                    switch mkdirResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let r) where r.exitCode != 0:
                        completion(.failure(SSHError.commandFailed(r.exitCode, r.stderr)))
                    case .success:
                        self.setStatus("Uploading script… 0%")
                        AppServices.shared.sshManager.uploadFile(
                            on: server,
                            localURL: localURL,
                            remotePath: remotePath,
                            atomic: true,
                            progress: { [weak self] progress in
                                self?.setStatus("Uploading script… \(Int(progress.fractionCompleted * 100))%")
                            },
                            completion: { uploadResult in
                                switch uploadResult {
                                case .failure(let error):
                                    completion(.failure(error))
                                case .success:
                                    let path = self.shellQuote(remotePath)
                                    let chmod = "chmod 700 -- \(path)"
                                    AppServices.shared.sshManager.execute(on: server, command: chmod) { chmodResult in
                                        switch chmodResult {
                                        case .failure(let error):
                                            completion(.failure(error))
                                        case .success(let chmodValue) where chmodValue.exitCode != 0:
                                            completion(.failure(SSHError.commandFailed(chmodValue.exitCode, chmodValue.stderr)))
                                        case .success:
                                            let payload = """
                                            if command -v bash >/dev/null 2>&1; then
                                              bash \(path)
                                            else
                                              sh \(path)
                                            fi
                                            status=$?
                                            rm -f -- \(path)
                                            exit $status
                                            """
                                            completion(.success(payload))
                                        }
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private func serverScheduleCommand(
        payload: String,
        unit: String,
        delaySeconds: Int,
        targetEpoch: Int
    ) -> String {
        let quotedPayload = shellQuote(payload)
        let quotedUnit = shellQuote(unit)
        return """
        payload=\(quotedPayload)
        unit=\(quotedUnit)
        delay=\(delaySeconds)
        epoch=\(targetEpoch)

        if command -v systemd-run >/dev/null 2>&1; then
          if [ "$(id -u)" -eq 0 ]; then
            if systemd-run --unit="$unit" --on-active="$delay"s /bin/sh -lc "$payload"; then
              printf 'Scheduled with systemd: %s.timer\\n' "$unit"
              exit 0
            fi
          else
            if systemd-run --user --unit="$unit" --on-active="$delay"s /bin/sh -lc "$payload"; then
              printf 'Scheduled with user systemd: %s.timer\\n' "$unit"
              exit 0
            fi
          fi
        fi

        if command -v at >/dev/null 2>&1; then
          when="$(date -d "@$epoch" '+%Y%m%d%H%M.%S' 2>/dev/null || date -r "$epoch" '+%Y%m%d%H%M.%S' 2>/dev/null)"
          if [ -n "$when" ]; then
            if printf '%s\\n' "$payload" | at -t "$when"; then
              printf 'Scheduled with at for %s\\n' "$when"
              exit 0
            fi
          fi
        fi

        printf '%s\\n' 'Neither systemd-run nor at could schedule this job.' >&2
        exit 127
        """
    }

    private func loadScript(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["sh", "bash", "command"].contains(ext) else {
            setStatus("Only .sh, .bash and .command scripts are supported.")
            return
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= 2 * 1024 * 1024 else {
                setStatus("The script is too large. Maximum size is 2 MB.")
                return
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            loadedScriptURL = url
            isLoadingScriptPreview = true
            commandView.string = text
            isLoadingScriptPreview = false
            scriptLabel.stringValue = url.lastPathComponent
            dropView.setDetail(L10n.text("Script loaded. It will be uploaded to the server before execution."))
            setStatus("Script loaded: \(url.lastPathComponent)")
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    private func safeRemoteFilename(_ filename: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let chars: [Character] = filename.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : Character("_")
        }
        let value = String(chars)
        return value.isEmpty ? "script.sh" : String(value.prefix(96))
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = L10n.text(text)
    }

    private func appendOutput(_ text: String) {
        let maxCharacters = 120_000
        var value = outputView.string + text
        if value.count > maxCharacters {
            value = String(value.suffix(maxCharacters))
        }
        outputView.string = value
        outputView.scrollToEndOfDocument(nil)
    }
}

final class ScriptDropView: NSView {
    var onFileDropped: ((URL) -> Void)?
    private let detailLabel = NSTextField(labelWithString: "The file is uploaded to the selected server and can run even after the app is closed.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func commonInit() {
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let title = NSTextField(labelWithString: "Drop Bash / SH script")
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            detailLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
        L10n.apply(to: self)
    }

    func setDetail(_ value: String) {
        detailLabel.stringValue = value
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        firstFileURL(from: sender) == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        firstFileURL(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = firstFileURL(from: sender) else { return false }
        onFileDropped?(url)
        return true
    }

    private func firstFileURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let values = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL],
              let value = values.first else { return nil }
        return value as URL
    }
}
