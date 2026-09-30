import Cocoa

final class ServerOverviewViewController: NSViewController {
    private let server: Server
    private let metricsLabel = NSTextField(wrappingLabelWithString: "Connecting…")
    private let problemsStack = NSStackView()
    private let quickActionsStack = NSStackView()
    private var snapshot = ServerSnapshot()

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
        metricsLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        metricsLabel.translatesAutoresizingMaskIntoConstraints = false

        let problemsTitle = NSTextField(labelWithString: "Problems")
        problemsTitle.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        problemsTitle.translatesAutoresizingMaskIntoConstraints = false

        problemsStack.orientation = .vertical
        problemsStack.alignment = .leading
        problemsStack.spacing = 4
        problemsStack.translatesAutoresizingMaskIntoConstraints = false

        let qaTitle = NSTextField(labelWithString: "Quick Actions")
        qaTitle.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        qaTitle.translatesAutoresizingMaskIntoConstraints = false

        quickActionsStack.orientation = .horizontal
        quickActionsStack.spacing = 8
        quickActionsStack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(metricsLabel)
        root.addSubview(problemsTitle)
        root.addSubview(problemsStack)
        root.addSubview(qaTitle)
        root.addSubview(quickActionsStack)

        NSLayoutConstraint.activate([
            metricsLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            metricsLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            metricsLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            problemsTitle.topAnchor.constraint(equalTo: metricsLabel.bottomAnchor, constant: 20),
            problemsTitle.leadingAnchor.constraint(equalTo: metricsLabel.leadingAnchor),

            problemsStack.topAnchor.constraint(equalTo: problemsTitle.bottomAnchor, constant: 8),
            problemsStack.leadingAnchor.constraint(equalTo: metricsLabel.leadingAnchor),
            problemsStack.trailingAnchor.constraint(equalTo: metricsLabel.trailingAnchor),

            qaTitle.topAnchor.constraint(equalTo: problemsStack.bottomAnchor, constant: 20),
            qaTitle.leadingAnchor.constraint(equalTo: metricsLabel.leadingAnchor),

            quickActionsStack.topAnchor.constraint(equalTo: qaTitle.bottomAnchor, constant: 8),
            quickActionsStack.leadingAnchor.constraint(equalTo: metricsLabel.leadingAnchor)
        ])

        view = root
        reloadQuickActions()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(onSnapshot(_:)), name: .serverSnapshotUpdated, object: nil)
        refreshOnce()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onSnapshot(_ note: Notification) {
        guard let id = note.object as? UUID, id == server.id,
              let snap = note.userInfo?["snapshot"] as? ServerSnapshot else { return }
        snapshot = snap
        render()
    }

    private func refreshOnce() {
        AppServices.shared.monitoring.fetchOnce(server: server) { [weak self] result in
            if case .success(let snap) = result {
                self?.snapshot = snap
                self?.render()
            }
        }
    }

    private func render() {
        let status: String
        switch snapshot.status {
        case .online: status = "● Online"
        case .offline: status = "○ Offline"
        case .connecting: status = "◌ Connecting"
        case .unknown: status = "• Unknown"
        }
        let uptime = Formatters.uptime(snapshot.uptimeSeconds)
        metricsLabel.stringValue = """
        \(status)
        Hostname: \(snapshot.hostname.isEmpty ? "—" : snapshot.hostname)
        OS: \(snapshot.osName.isEmpty ? "—" : snapshot.osName)
        Uptime: \(uptime)
        CPU: \(String(format: "%.0f%%", snapshot.cpuPercent))
        RAM: \(String(format: "%.0f%%", snapshot.ramPercent))
        Disk: \(String(format: "%.0f%%", snapshot.diskPercent))
        Load: \(String(format: "%.2f %.2f %.2f", snapshot.load1, snapshot.load5, snapshot.load15))
        Network: RX \(Formatters.bytes(snapshot.netRxBytesPerSec))/s  TX \(Formatters.bytes(snapshot.netTxBytesPerSec))/s
        Docker: \(snapshot.dockerAvailable ? "available" : "not found")
        systemd: \(snapshot.systemdAvailable ? "available" : "not found")
        """

        problemsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for problem in ProblemsDetector.detect(snapshot: snapshot) {
            let row = NSTextField(labelWithString: problem.title)
            row.font = NSFont.systemFont(ofSize: 12)
            problemsStack.addArrangedSubview(row)
        }
        if problemsStack.arrangedSubviews.isEmpty {
            problemsStack.addArrangedSubview(NSTextField(labelWithString: "No problems detected"))
        }
    }

    private func reloadQuickActions() {
        quickActionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let actions = ((try? AppServices.shared.storage.allActions()) ?? [])
            .filter { $0.serverId == server.id && $0.isPinnedQuickAction }
        if actions.isEmpty {
            let hint = NSTextField(labelWithString: "Pin Custom Actions to show them here.")
            hint.textColor = .secondaryLabelColor
            quickActionsStack.addArrangedSubview(hint)
            return
        }
        for action in actions {
            let btn = NSButton(title: action.name, target: self, action: #selector(runQuickAction(_:)))
            btn.tag = actions.firstIndex(where: { $0.id == action.id }) ?? 0
            btn.identifier = NSUserInterfaceItemIdentifier(action.id.uuidString)
            quickActionsStack.addArrangedSubview(btn)
        }
    }

    @objc private func runQuickAction(_ sender: NSButton) {
        guard let id = UUID(uuidString: sender.identifier?.rawValue ?? ""),
              let action = ((try? AppServices.shared.storage.allActions()) ?? []).first(where: { $0.id == id }) else { return }
        if action.confirmationRequired {
            let alert = NSAlert()
            alert.messageText = "Run \(action.name)?"
            alert.informativeText = action.command
            alert.addButton(withTitle: "Run")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        AppServices.shared.actions.run(action, server: server) { _ in }
    }
}
