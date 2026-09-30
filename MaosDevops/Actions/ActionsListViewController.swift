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
        view = root
    }
}
