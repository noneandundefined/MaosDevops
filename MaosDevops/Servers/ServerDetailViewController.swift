import Cocoa

final class ServerDetailViewController: NSViewController {
    private var server: Server
    private let tabControl = NSPopUpButton()
    private let container = ContentContainerViewController()
    private var snapshot = ServerSnapshot()
    private var isVisible = false
    private var availableTabs = ServerDetailTab.allCases
    // Keep controllers alive while the user switches between server tabs.
    // In particular, this preserves SSH terminal processes, tabs and output.
    private var tabControllers: [ServerDetailTab: NSViewController] = [:]

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
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        configureTabs(selecting: .overview)
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false

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
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),

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
            self.updateAvailableTabs(for: snap)
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
        let idx = tabControl.indexOfSelectedItem
        guard idx >= 0, idx < availableTabs.count else { return }
        showTab(availableTabs[idx])
    }

    private func updateAvailableTabs(for snapshot: ServerSnapshot) {
        guard snapshot.status == .online else { return }
        let selectedIndex = tabControl.indexOfSelectedItem
        let selected = selectedIndex >= 0 && selectedIndex < availableTabs.count
            ? availableTabs[selectedIndex] : .overview
        let next = ServerDetailTab.allCases.filter { tab in
            if tab == .docker { return snapshot.dockerAvailable }
            if tab == .services { return snapshot.systemdAvailable }
            return true
        }
        guard next != availableTabs else { return }
        availableTabs = next
        let target = next.contains(selected) ? selected : .overview
        configureTabs(selecting: target)
        if target != selected { showTab(target) }
    }

    private func configureTabs(selecting tab: ServerDetailTab) {
        tabControl.removeAllItems()
        tabControl.addItems(withTitles: availableTabs.map { $0.title })
        tabControl.selectItem(at: availableTabs.firstIndex(of: tab) ?? 0)
    }

    private func showTab(_ tab: ServerDetailTab) {
        let controller: NSViewController
        if let cached = tabControllers[tab] {
            controller = cached
        } else {
            controller = makeController(for: tab)
            tabControllers[tab] = controller
        }
        container.embed(controller)
    }

    private func makeController(for tab: ServerDetailTab) -> NSViewController {
        switch tab {
        case .overview:
            return ServerOverviewViewController(server: server)
        case .terminal:
            return TerminalViewController(server: server)
        case .docker:
            return DockerViewController(server: server)
        case .services:
            return SystemdViewController(server: server)
        case .logs:
            return LogsViewController(server: server)
        case .files:
            return FilesViewController(server: server)
        case .monitoring:
            return ServerMonitoringViewController(server: server)
        case .actions:
            return ServerActionsViewController(server: server)
        case .git:
            return GitViewController(server: server)
        case .health:
            return HealthChecksViewController(server: server)
        }
    }
}

extension Notification.Name {
    static let serverSnapshotUpdated = Notification.Name("MaosDevOps.serverSnapshotUpdated")
}
