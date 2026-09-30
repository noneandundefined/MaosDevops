import Cocoa

final class GlobalDashboardViewController: NSViewController {
    private let label = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Dashboard")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(label)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16)
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        let servers = (try? AppServices.shared.storage.allServers()) ?? []
        let actions = (try? AppServices.shared.storage.allActions()) ?? []
        let projects = (try? AppServices.shared.storage.allProjects()) ?? []
        label.stringValue = """
        Servers: \(servers.count)
        Actions: \(actions.count)
        Projects: \(projects.count)

        Open Servers to add a host, test SSH, and explore Overview / Terminal / Docker / Services.
        Polling runs only while a server detail view is visible.
        """
    }
}

final class GlobalMonitoringViewController: NSViewController {
    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Monitoring")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(wrappingLabelWithString: "Open a server → Monitoring tab for live CPU/RAM/Disk charts (15m / 1h / 24h history from SQLite). Global polling is disabled to protect low-RAM Macs.")
        hint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(hint)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16)
        ])
        view = root
    }
}

final class ServerMonitoringViewController: NSViewController {
    private let server: Server
    private let metrics = NSTextField(wrappingLabelWithString: "Waiting for samples…")
    private let rangeControl = NSSegmentedControl(labels: ["15 min", "1 hour", "24 hours"], trackingMode: .selectOne, target: nil, action: nil)

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        rangeControl.selectedSegment = 0
        rangeControl.translatesAutoresizingMaskIntoConstraints = false
        metrics.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        metrics.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Server Monitoring")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(rangeControl)
        root.addSubview(metrics)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            rangeControl.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            rangeControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            metrics.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            metrics.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            metrics.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(onSnap(_:)), name: .serverSnapshotUpdated, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func onSnap(_ note: Notification) {
        guard let id = note.object as? UUID, id == server.id,
              let snap = note.userInfo?["snapshot"] as? ServerSnapshot else { return }
        metrics.stringValue = """
        Range: \(rangeControl.label(forSegment: rangeControl.selectedSegment) ?? "")
        CPU  \(String(format: "%5.1f", snap.cpuPercent))%
        RAM  \(String(format: "%5.1f", snap.ramPercent))%
        Disk \(String(format: "%5.1f", snap.diskPercent))%
        Load \(String(format: "%.2f %.2f %.2f", snap.load1, snap.load5, snap.load15))
        Net  RX \(Formatters.bytes(snap.netRxBytesPerSec))/s   TX \(Formatters.bytes(snap.netTxBytesPerSec))/s
        Up   \(Formatters.uptime(snap.uptimeSeconds))

        Samples are stored in SQLite and pruned to monitoringHistoryHours.
        Simple sparkline charts can be layered later without raising the deployment target.
        """
    }
}
