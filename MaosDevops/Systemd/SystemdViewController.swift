import Cocoa

final class SystemdViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let server: Server
    private let table = NSTableView()
    private var services: [SystemdService] = []
    private let statusLabel = NSTextField(labelWithString: "")

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        refresh.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor

        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        for (id, title, w) in [("name", "Service", 220), ("active", "Active", 100), ("sub", "Sub", 100), ("desc", "Description", 280)] as [(String, String, CGFloat)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = w
            table.addTableColumn(col)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        for (t, s) in [("Start", #selector(startS)), ("Stop", #selector(stopS)), ("Restart", #selector(restartS)),
                       ("Status", #selector(statusS)), ("Enable", #selector(enableS)), ("Disable", #selector(disableS)),
                       ("Logs", #selector(logsS)), ("Live Logs", #selector(liveLogsS))] as [(String, Selector)] {
            actions.addArrangedSubview(NSButton(title: t, target: self, action: s))
        }

        root.addSubview(refresh)
        root.addSubview(statusLabel)
        root.addSubview(scroll)
        root.addSubview(actions)
        NSLayoutConstraint.activate([
            refresh.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            refresh.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: refresh.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: refresh.trailingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: refresh.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    @objc private func reload() {
        let cmd = "systemctl list-units --type=service --all --no-pager --no-legend --plain 2>/dev/null | head -n 200"
        AppServices.shared.sshManager.execute(on: server, command: cmd) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let r):
                if r.exitCode != 0 {
                    self.statusLabel.stringValue = "systemd not available"
                    self.services = []
                } else {
                    self.services = r.stdout.split(separator: "\n").compactMap { line in
                        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                        guard parts.count >= 4 else { return nil }
                        return SystemdService(name: parts[0], load: parts[1], active: parts[2], sub: parts[3],
                                              description: parts.dropFirst(4).joined(separator: " "))
                    }
                    self.statusLabel.stringValue = "\(self.services.count) services"
                }
                self.table.reloadData()
            case .failure(let e):
                self.statusLabel.stringValue = e.localizedDescription
            }
        }
    }

    private func selected() -> SystemdService? {
        let row = table.selectedRow
        guard row >= 0, row < services.count else { return nil }
        return services[row]
    }

    private func systemctl(_ args: String) {
        guard let s = selected() else { return }
        AppServices.shared.sshManager.execute(on: server, command: "systemctl \(args) \(s.name)") { [weak self] _ in
            self?.reload()
        }
    }

    @objc private func startS() { systemctl("start") }
    @objc private func stopS() { systemctl("stop") }
    @objc private func restartS() { systemctl("restart") }
    @objc private func enableS() { systemctl("enable") }
    @objc private func disableS() { systemctl("disable") }
    @objc private func statusS() {
        guard let s = selected() else { return }
        AppServices.shared.sshManager.execute(on: server, command: "systemctl status \(s.name) --no-pager -l") { result in
            let alert = NSAlert()
            alert.messageText = s.name
            alert.informativeText = String((try? result.get().stdout) ?? "").prefix(3500).description
            alert.runModal()
        }
    }
    @objc private func logsS() {
        guard let s = selected() else { return }
        presentAsSheet(LogStreamViewController(server: server, title: s.name, command: "journalctl -u \(s.name) -n 200 --no-pager"))
    }
    @objc private func liveLogsS() {
        guard let s = selected() else { return }
        presentAsSheet(LogStreamViewController(server: server, title: "Live \(s.name)",
                                               command: "journalctl -fu \(s.name) -n 100 --no-pager", streaming: true))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { services.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = services[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = s.name
        case "active":
            let ok = s.active == "active"
            let failed = s.active == "failed"
            value = "\(failed ? "●" : ok ? "●" : "○") \(s.active)"
        case "sub": value = s.sub
        case "desc": value = s.description
        default: value = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        if s.active == "failed" { label.textColor = .systemRed }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
        ])
        return cell
    }
}

struct SystemdService {
    let name: String
    let load: String
    let active: String
    let sub: String
    let description: String
}
