import Cocoa

final class DockerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let server: Server
    private let table = NSTableView()
    private var containers: [DockerContainer] = []
    private let statusLabel = NSTextField(labelWithString: "")
    private var isVisible = false
    private var timer: DispatchSourceTimer?

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
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reload))
        let compose = NSButton(title: "Compose…", target: self, action: #selector(showCompose))
        refresh.translatesAutoresizingMaskIntoConstraints = false
        compose.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor

        table.headerView = NSTableHeaderView()
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(inspectSelected)
        for (id, title, width) in [
            ("name", "Container", 160), ("status", "Status", 120),
            ("image", "Image", 180), ("ports", "Ports", 160), ("stats", "CPU / RAM", 120)
        ] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = CGFloat(width)
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
        for (title, sel) in [
            ("Start", #selector(startSelected)), ("Stop", #selector(stopSelected)),
            ("Restart", #selector(restartSelected)), ("Logs", #selector(logsSelected)),
            ("Live Logs", #selector(liveLogsSelected)), ("Shell", #selector(shellSelected)),
            ("Inspect", #selector(inspectSelected)), ("Stats", #selector(statsSelected)),
            ("Remove", #selector(removeSelected))
        ] as [(String, Selector)] {
            actions.addArrangedSubview(NSButton(title: title, target: self, action: sel))
        }

        root.addSubview(refresh)
        root.addSubview(compose)
        root.addSubview(statusLabel)
        root.addSubview(scroll)
        root.addSubview(actions)

        NSLayoutConstraint.activate([
            refresh.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            refresh.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            compose.centerYAnchor.constraint(equalTo: refresh.centerYAnchor),
            compose.leadingAnchor.constraint(equalTo: refresh.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: refresh.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: compose.trailingAnchor, constant: 12),

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
        isVisible = true
        reload()
        let seconds = AppServices.shared.storage.preferences.dockerPollSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        t.setEventHandler { [weak self] in
            guard let self = self, self.isVisible else { return }
            self.reload()
        }
        timer = t
        t.resume()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        isVisible = false
        timer?.cancel()
        timer = nil
    }

    @objc private func reload() {
        statusLabel.stringValue = "Loading…"
        let cmd = "docker ps -a --format '{{.Names}}\\t{{.Status}}\\t{{.Image}}\\t{{.Ports}}\\t{{.RunningFor}}\\t{{.ID}}' 2>/dev/null"
        AppServices.shared.sshManager.execute(on: server, command: cmd) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let r):
                if r.exitCode != 0 {
                    self.statusLabel.stringValue = "Docker not available"
                    self.containers = []
                } else {
                    self.containers = r.stdout.split(separator: "\n").compactMap { line in
                        let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                        guard p.count >= 4 else { return nil }
                        return DockerContainer(name: p[0], status: p[1], image: p[2], ports: p[3],
                                               uptime: p.count > 4 ? p[4] : "", id: p.count > 5 ? p[5] : p[0])
                    }
                    self.statusLabel.stringValue = "\(self.containers.count) containers"
                }
                self.table.reloadData()
            case .failure(let error):
                self.statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private func selected() -> DockerContainer? {
        let row = table.selectedRow
        guard row >= 0, row < containers.count else { return nil }
        return containers[row]
    }

    private func docker(_ args: String) {
        guard let c = selected() else { return }
        AppServices.shared.sshManager.execute(on: server, command: "docker \(args) \(c.name)") { [weak self] _ in
            self?.reload()
        }
    }

    @objc private func startSelected() { docker("start") }
    @objc private func stopSelected() { docker("stop") }
    @objc private func restartSelected() { docker("restart") }
    @objc private func shellSelected() {
        guard let c = selected() else { return }
        AppServices.shared.sshManager.execute(on: server, command: "docker exec -it \(c.name) sh -c 'echo shell-ready'") { result in
            let alert = NSAlert()
            alert.messageText = "Shell"
            alert.informativeText = (try? result.get().stdout) ?? (result.getError()?.localizedDescription ?? "")
            alert.runModal()
        }
    }
    @objc private func inspectSelected() {
        guard let c = selected() else { return }
        AppServices.shared.sshManager.execute(on: server, command: "docker inspect \(c.name)") { result in
            let alert = NSAlert()
            alert.messageText = "Inspect \(c.name)"
            alert.informativeText = String((try? result.get().stdout) ?? "").prefix(4000).description
            alert.runModal()
        }
    }
    @objc private func statsSelected() {
        guard let c = selected() else { return }
        AppServices.shared.sshManager.execute(on: server, command: "docker stats --no-stream --format '{{.Name}} CPU={{.CPUPerc}} MEM={{.MemUsage}}' \(c.name)") { result in
            let alert = NSAlert()
            alert.messageText = "Stats"
            alert.informativeText = (try? result.get().stdout) ?? ""
            alert.runModal()
        }
    }
    @objc private func logsSelected() {
        guard let c = selected() else { return }
        presentAsSheet(LogStreamViewController(server: server, title: "Docker \(c.name)", command: "docker logs --tail 200 \(c.name)"))
    }
    @objc private func liveLogsSelected() {
        guard let c = selected() else { return }
        presentAsSheet(LogStreamViewController(server: server, title: "Live \(c.name)", command: "docker logs -f --tail 100 \(c.name)", streaming: true))
    }
    @objc private func removeSelected() {
        guard let c = selected() else { return }
        let alert = NSAlert()
        alert.messageText = "Remove container \(c.name)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        docker("rm -f")
    }
    @objc private func showCompose() {
        presentAsSheet(ComposeViewController(server: server))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { containers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = containers[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = c.name
        case "status":
            let running = c.status.lowercased().contains("up")
            value = "\(running ? "●" : "○") \(c.status)"
        case "image": value = c.image
        case "ports": value = c.ports
        case "stats": value = c.uptime
        default: value = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

struct DockerContainer {
    let name: String
    let status: String
    let image: String
    let ports: String
    let uptime: String
    let id: String
}

private extension Result {
    func getError() -> Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}

final class ComposeViewController: NSViewController {
    private let server: Server
    private let pathField = NSTextField(string: ".")
    private let output = NSTextView()

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for (t, s) in [("ps", #selector(ps)), ("pull", #selector(pull)), ("up", #selector(up)),
                       ("down", #selector(down)), ("restart", #selector(restart)), ("logs", #selector(logs)), ("build", #selector(build))] as [(String, Selector)] {
            buttons.addArrangedSubview(NSButton(title: t, target: self, action: s))
        }
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.translatesAutoresizingMaskIntoConstraints = false
        pathField.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        output.isEditable = false
        output.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pathField)
        root.addSubview(buttons)
        root.addSubview(scroll)
        root.addSubview(close)
        NSLayoutConstraint.activate([
            pathField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            pathField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            pathField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
    }

    @objc private func closeSheet() { dismiss(nil) }
    @objc private func ps() { run("ps") }
    @objc private func pull() { run("pull") }
    @objc private func up() { run("up -d") }
    @objc private func down() { run("down") }
    @objc private func restart() { run("restart") }
    @objc private func logs() { run("logs --tail 100") }
    @objc private func build() { run("build") }

    private func run(_ args: String) {
        let dir = pathField.stringValue
        AppServices.shared.sshManager.execute(on: server, command: "docker compose \(args)", workingDirectory: dir) { [weak self] result in
            let text: String
            switch result {
            case .success(let r): text = r.stdout + r.stderr
            case .failure(let e): text = e.localizedDescription
            }
            self?.output.string = text
        }
    }
}
