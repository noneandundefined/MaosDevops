import Cocoa

final class ServerDetailViewController: NSViewController {
    private var server: Server
    private let tabControl = NSSegmentedControl()
    private let container = ContentContainerViewController()
    private var snapshot = ServerSnapshot()
    private var isVisible = false

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

        let back = NSButton(title: "← Servers", target: self, action: #selector(goBack))
        back.bezelStyle = .recessed
        back.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: server.name)
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "\(server.username)@\(server.host):\(server.port)")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        tabControl.segmentCount = ServerDetailTab.allCases.count
        for (i, tab) in ServerDetailTab.allCases.enumerated() {
            tabControl.setLabel(tab.title, forSegment: i)
        }
        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.segmentStyle = .texturedRounded

        addChild(container)
        container.view.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(back)
        root.addSubview(title)
        root.addSubview(subtitle)
        root.addSubview(tabControl)
        root.addSubview(container.view)

        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            back.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),

            title.centerYAnchor.constraint(equalTo: back.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 12),

            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 12),
            subtitle.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            tabControl.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 10),
            tabControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabControl.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),

            container.view.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            container.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        showTab(.overview)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        isVisible = true
        AppServices.shared.monitoring.start(for: server) { [weak self] snap in
            guard let self = self, self.isVisible else { return }
            self.snapshot = snap
            NotificationCenter.default.post(name: .serverSnapshotUpdated, object: self.server.id, userInfo: ["snapshot": snap])
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        isVisible = false
        // Stop aggressive polling when server window/tab not visible
        AppServices.shared.monitoring.stop(serverId: server.id)
    }

    @objc private func goBack() {
        AppServices.shared.monitoring.stop(serverId: server.id)
        if let container = parent as? ContentContainerViewController {
            container.embed(ServersListViewController())
        } else if let window = view.window,
                  let split = window.contentViewController as? NSSplitViewController,
                  let content = split.splitViewItems.last?.viewController as? ContentContainerViewController {
            content.embed(ServersListViewController())
        }
    }

    @objc private func tabChanged() {
        let idx = tabControl.selectedSegment
        guard idx >= 0, idx < ServerDetailTab.allCases.count else { return }
        showTab(ServerDetailTab.allCases[idx])
    }

    private func showTab(_ tab: ServerDetailTab) {
        switch tab {
        case .overview:
            container.embed(ServerOverviewViewController(server: server))
        case .terminal:
            container.embed(TerminalViewController(server: server))
        case .docker:
            container.embed(DockerViewController(server: server))
        case .services:
            container.embed(SystemdViewController(server: server))
        case .logs:
            container.embed(LogsViewController(server: server))
        case .files:
            container.embed(FilesViewController(server: server))
        case .monitoring:
            container.embed(ServerMonitoringViewController(server: server))
        case .actions:
            container.embed(ServerActionsViewController(server: server))
        }
    }
}

extension Notification.Name {
    static let serverSnapshotUpdated = Notification.Name("MaosDevOps.serverSnapshotUpdated")
}
