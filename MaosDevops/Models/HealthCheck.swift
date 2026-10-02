import Cocoa

struct HealthCheck: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case http, tcp, shell }
    var id: UUID
    var name: String
    var serverId: UUID?
    var kind: Kind
    var target: String
    var intervalSeconds: Int

    init(id: UUID = UUID(), name: String, serverId: UUID? = nil, kind: Kind,
         target: String, intervalSeconds: Int = 30) {
        self.id = id
        self.name = name
        self.serverId = serverId
        self.kind = kind
        self.target = target
        self.intervalSeconds = intervalSeconds
    }
}

struct HealthCheckResult {
    let healthy: Bool
    let summary: String
    let durationMilliseconds: Int
    let checkedAt: Date
}

final class HealthCheckRunner {
    private let sshManager: SSHConnectionManager

    init(sshManager: SSHConnectionManager) {
        self.sshManager = sshManager
    }

    func run(_ check: HealthCheck, server: Server?, completion: @escaping (HealthCheckResult) -> Void) {
        let started = Date()
        let finish: (Bool, String) -> Void = { healthy, summary in
            let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1_000))
            DispatchQueue.main.async {
                completion(HealthCheckResult(healthy: healthy, summary: summary,
                                             durationMilliseconds: elapsed, checkedAt: Date()))
            }
        }

        switch check.kind {
        case .http:
            let normalizedTarget = check.target.contains("://") ? check.target : "http://\(check.target)"
            guard let url = URL(string: normalizedTarget), let scheme = url.scheme,
                  scheme == "http" || scheme == "https" else {
                finish(false, "Invalid HTTP URL")
                return
            }
            guard let server = server else {
                finish(false, "Server is required")
                return
            }

            let target = Self.shellQuote(normalizedTarget)
            let command = """
            command -v curl >/dev/null 2>&1 || { echo 'curl is not installed on the server' >&2; exit 127; }
            curl -k -L -sS --connect-timeout 8 --max-time 12 -o /dev/null -w 'HTTP %{http_code}' -- \(target)
            """
            sshManager.execute(on: server, command: command) { result in
                switch result {
                case .success(let value) where value.exitCode == 0:
                    let summary = value.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let code = Int(summary.split(separator: " ").last ?? "") ?? 0
                    finish((100...599).contains(code), summary.isEmpty ? "HTTP check completed" : summary)
                case .success(let value):
                    let message = (value.stderr.isEmpty ? value.stdout : value.stderr)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(false, message.isEmpty ? "HTTP check failed (exit \(value.exitCode))" : message)
                case .failure(let error):
                    finish(false, error.localizedDescription)
                }
            }

        case .tcp:
            guard let endpoint = Self.parseTCP(check.target) else {
                finish(false, "Use host:port")
                return
            }
            guard let server = server else {
                finish(false, "Server is required")
                return
            }

            let host = Self.shellQuote(endpoint.host)
            let port = Self.shellQuote(String(endpoint.port))
            let command = """
            HOST=\(host)
            PORT=\(port)
            if command -v python3 >/dev/null 2>&1; then
                python3 - "$HOST" "$PORT" <<'PY'
            import socket
            import sys
            connection = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=8)
            connection.close()
            PY
            elif command -v nc >/dev/null 2>&1; then
                nc -z -w 8 "$HOST" "$PORT"
            elif command -v bash >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
                timeout 8 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$HOST" "$PORT"
            else
                echo 'No TCP probe tool available on the server (python3, nc, or bash+timeout)' >&2
                exit 127
            fi
            """
            sshManager.execute(on: server, command: command) { result in
                switch result {
                case .success(let value) where value.exitCode == 0:
                    finish(true, "Connected")
                case .success(let value):
                    let message = (value.stderr.isEmpty ? value.stdout : value.stderr)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(false, message.isEmpty ? "TCP connection failed" : String(message.prefix(160)))
                case .failure(let error):
                    finish(false, error.localizedDescription)
                }
            }

        case .shell:
            guard let server = server else {
                finish(false, "Server is required")
                return
            }
            sshManager.execute(on: server, command: check.target) { result in
                switch result {
                case .success(let value):
                    let message = value.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(value.exitCode == 0, message.isEmpty ? "Exit \(value.exitCode)" : String(message.prefix(160)))
                case .failure(let error):
                    finish(false, error.localizedDescription)
                }
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func parseTCP(_ value: String) -> (host: String, port: UInt16)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.first == ":", let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = trimmed.lastIndex(of: ":"), let port = UInt16(trimmed[trimmed.index(after: colon)...]) else { return nil }
        return (String(trimmed[..<colon]), port)
    }
}

final class HealthChecksViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let server: Server
    private let table = NSTableView()
    private var checks: [HealthCheck] = []
    private var results: [UUID: HealthCheckResult] = [:]
    private var lastRun: [UUID: Date] = [:]
    private var timer: DispatchSourceTimer?
    private var running: Set<UUID> = []
    private let detailsText = NSTextView()

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Health Checks")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: "Add", target: self, action: #selector(addCheck))
        let edit = NSButton(title: "Edit", target: self, action: #selector(editCheck))
        let remove = NSButton(title: "Delete", target: self, action: #selector(deleteCheck))
        let run = NSButton(title: "Run Now", target: self, action: #selector(runSelected))
        let bar = NSStackView(views: [add, edit, remove, run])
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        table.dataSource = self
        table.delegate = self
        table.rowHeight = 25
        table.target = self
        table.doubleAction = #selector(editCheckByDoubleClick)
        for (id, label, width) in [("name", "Name", 150), ("kind", "Type", 70),
                                   ("target", "Target", 260), ("status", "Status", 220)] as [(String, String, CGFloat)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let detailsTitle = NSTextField(labelWithString: "Full result")
        detailsTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        detailsTitle.translatesAutoresizingMaskIntoConstraints = false
        detailsText.isEditable = false
        detailsText.isRichText = false
        detailsText.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsText.frame = NSRect(x: 0, y: 0, width: 640, height: 100)
        detailsText.string = "Select a health check to see the complete result."
        detailsText.autoresizingMask = [.width, .height]
        let detailsScroll = NSScrollView()
        detailsScroll.documentView = detailsText
        detailsScroll.hasVerticalScroller = true
        detailsScroll.hasHorizontalScroller = true
        detailsScroll.borderType = .bezelBorder
        detailsScroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(bar)
        root.addSubview(scroll)
        root.addSubview(detailsTitle)
        root.addSubview(detailsScroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bar.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: detailsTitle.topAnchor, constant: -8),
            detailsTitle.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            detailsTitle.bottomAnchor.constraint(equalTo: detailsScroll.topAnchor, constant: -5),
            detailsScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            detailsScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            detailsScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            detailsScroll.heightAnchor.constraint(equalToConstant: 105)
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        timer?.cancel()
        reload()
        runDue(force: true)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 5, repeating: 5)
        source.setEventHandler { [weak self] in self?.runDue(force: false) }
        timer = source
        source.resume()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.cancel()
        timer = nil
    }

    private func reload() {
        checks = (try? AppServices.shared.storage.allHealthChecks(serverId: server.id)) ?? []
        table.reloadData()
        if !checks.isEmpty, table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateDetails()
    }

    private func selected() -> HealthCheck? {
        let row = table.selectedRow
        guard row >= 0, row < checks.count else { return nil }
        return checks[row]
    }

    private func runDue(force: Bool) {
        let now = Date()
        for check in checks where !running.contains(check.id) {
            let due = lastRun[check.id].map { now.timeIntervalSince($0) >= Double(max(5, check.intervalSeconds)) } ?? true
            if force || due { run(check) }
        }
    }

    private func run(_ check: HealthCheck) {
        running.insert(check.id)
        table.reloadData()
        AppServices.shared.healthChecks.run(check, server: server) { [weak self] result in
            self?.running.remove(check.id)
            self?.lastRun[check.id] = result.checkedAt
            self?.results[check.id] = result
            self?.table.reloadData()
            self?.updateDetails()
        }
    }

    @objc private func runSelected() { if let check = selected() { run(check) } }
    @objc private func addCheck() { presentEditor(nil) }
    @objc private func editCheck() { if let check = selected() { presentEditor(check) } }

    @objc private func editCheckByDoubleClick() {
        guard table.clickedRow >= 0, table.clickedRow < checks.count else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        presentEditor(checks[table.clickedRow])
    }
    @objc private func deleteCheck() {
        guard let check = selected() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete health check?"
        alert.informativeText = check.name
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? AppServices.shared.storage.deleteHealthCheck(id: check.id)
        results[check.id] = nil
        reload()
    }

    private func presentEditor(_ check: HealthCheck?) {
        presentAsSheet(HealthCheckEditorViewController(server: server, check: check) { [weak self] in
            self?.reload()
            self?.runDue(force: true)
        })
    }

    func numberOfRows(in tableView: NSTableView) -> Int { checks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let check = checks[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = check.name
        case "kind": value = check.kind.rawValue.uppercased()
        case "target": value = check.target
        case "status":
            if running.contains(check.id) {
                value = "◌ Checking…"
            } else if let result = results[check.id] {
                value = "\(result.healthy ? "●" : "●") \(result.summary)  \(result.durationMilliseconds) ms"
            } else { value = "• Not checked" }
        default: value = ""
        }
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: value)
        field.font = NSFont.systemFont(ofSize: 12)
        if tableColumn?.identifier.rawValue == "status", let result = results[check.id] {
            // A received HTTP status (including 403) means the service is reachable.
            // Failed checks use the normal label color: black in the light appearance.
            field.textColor = result.healthy ? .systemGreen : .labelColor
        }
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = value
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetails()
    }

    private func updateDetails() {
        guard let check = selected() else {
            detailsText.string = L10n.text("Select a health check to see the complete result.")
            return
        }
        var lines = ["\(check.name)", "\(check.kind.rawValue.uppercased()): \(check.target)"]
        if running.contains(check.id) {
            lines.append(L10n.text("Checking…"))
        } else if let result = results[check.id] {
            lines.append(result.healthy ? L10n.text("Healthy") : L10n.text("Failed"))
            lines.append(result.summary)
            lines.append("\(result.durationMilliseconds) ms")
        } else {
            lines.append(L10n.text("Not checked yet"))
        }
        detailsText.string = lines.joined(separator: "\n")
    }
}

private final class HealthCheckEditorViewController: NSViewController {
    private let server: Server
    private var check: HealthCheck?
    private let onSave: () -> Void
    private let nameField = NSTextField(string: "")
    private let kindPopup = NSPopUpButton()
    private let targetField = NSTextField(string: "")
    private let intervalField = NSTextField(string: "30")

    init(server: Server, check: HealthCheck?, onSave: @escaping () -> Void) {
        self.server = server
        self.check = check
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 250))
        kindPopup.addItems(withTitles: ["http", "tcp", "shell"])
        if let check = check {
            nameField.stringValue = check.name
            kindPopup.selectItem(withTitle: check.kind.rawValue)
            targetField.stringValue = check.target
            intervalField.stringValue = "\(check.intervalSeconds)"
        }
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Type"), kindPopup],
            [NSTextField(labelWithString: "URL / host:port / command"), targetField],
            [NSTextField(labelWithString: "Interval, sec"), intervalField]
        ])
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEdit))
        let save = NSButton(title: "Save", target: self, action: #selector(saveEdit))
        let buttons = NSStackView(views: [cancel, save])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            targetField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            buttons.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        L10n.apply(to: root)
        view = root
    }

    @objc private func cancelEdit() { dismiss(nil) }
    @objc private func saveEdit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !target.isEmpty else { return }
        var value = check ?? HealthCheck(name: name, serverId: server.id, kind: .http, target: target)
        value.name = name
        value.serverId = server.id
        value.kind = HealthCheck.Kind(rawValue: kindPopup.titleOfSelectedItem ?? "http") ?? .http
        value.target = target
        value.intervalSeconds = max(5, Int(intervalField.stringValue) ?? 30)
        try? AppServices.shared.storage.saveHealthCheck(value)
        onSave()
        dismiss(nil)
    }
}
