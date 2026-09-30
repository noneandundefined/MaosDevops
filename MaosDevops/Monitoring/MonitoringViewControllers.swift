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
    private let cpuField = NSTextField(string: "5")
    private let diskField = NSTextField(string: "30")
    private let dockerField = NSTextField(string: "8")
    private let bufferField = NSTextField(string: "10000")
    private let historyField = NSTextField(string: "24")
    private let status = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Monitoring")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(wrappingLabelWithString: "Polling runs only while a server screen is visible. Values below are deliberately conservative for Intel Macs with 4 GB RAM.")
        hint.translatesAutoresizingMaskIntoConstraints = false
        let prefs = AppServices.shared.storage.preferences
        cpuField.stringValue = "\(prefs.cpuRamPollSeconds)"
        diskField.stringValue = "\(prefs.diskPollSeconds)"
        dockerField.stringValue = "\(prefs.dockerPollSeconds)"
        bufferField.stringValue = "\(prefs.logBufferMaxLines)"
        historyField.stringValue = "\(prefs.monitoringHistoryHours)"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "CPU / RAM interval, sec"), cpuField],
            [NSTextField(labelWithString: "Disk interval, sec"), diskField],
            [NSTextField(labelWithString: "Docker interval, sec"), dockerField],
            [NSTextField(labelWithString: "Maximum log lines"), bufferField],
            [NSTextField(labelWithString: "History, hours"), historyField]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        let save = NSButton(title: "Save Settings", target: self, action: #selector(saveSettings))
        save.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(hint)
        root.addSubview(grid)
        root.addSubview(save)
        root.addSubview(status)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            save.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            save.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: save.trailingAnchor, constant: 10)
        ])
        view = root
    }

    @objc private func saveSettings() {
        var prefs = AppServices.shared.storage.preferences
        prefs.cpuRamPollSeconds = max(2, Int(cpuField.stringValue) ?? 5)
        prefs.diskPollSeconds = max(10, Int(diskField.stringValue) ?? 30)
        prefs.dockerPollSeconds = max(5, Int(dockerField.stringValue) ?? 8)
        prefs.logBufferMaxLines = min(20_000, max(5_000, Int(bufferField.stringValue) ?? 10_000))
        prefs.monitoringHistoryHours = min(168, max(1, Int(historyField.stringValue) ?? 24))
        do {
            try AppServices.shared.storage.savePreferences(prefs)
            status.stringValue = "Saved"
        } catch {
            status.stringValue = error.localizedDescription
        }
    }
}

final class ServerMonitoringViewController: NSViewController {
    private let server: Server
    private let metrics = NSTextField(wrappingLabelWithString: "Waiting for samples…")
    private let rangeControl = NSSegmentedControl(labels: ["15 min", "1 hour", "24 hours"], trackingMode: .selectOne, target: nil, action: nil)
    private let cpuChart = HistoryChartView(title: "CPU", color: .systemBlue)
    private let ramChart = HistoryChartView(title: "RAM", color: .systemGreen)
    private let diskChart = HistoryChartView(title: "Disk", color: .systemOrange)

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        rangeControl.selectedSegment = 0
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged)
        rangeControl.translatesAutoresizingMaskIntoConstraints = false
        metrics.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        metrics.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Server Monitoring")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(rangeControl)
        root.addSubview(metrics)
        let charts = NSStackView(views: [cpuChart, ramChart, diskChart])
        charts.orientation = .vertical
        charts.spacing = 8
        charts.distribution = .fillEqually
        charts.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(charts)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            rangeControl.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            rangeControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            metrics.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            metrics.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            metrics.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            charts.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 12),
            charts.leadingAnchor.constraint(equalTo: metrics.leadingAnchor),
            charts.trailingAnchor.constraint(equalTo: metrics.trailingAnchor),
            charts.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(onSnap(_:)), name: .serverSnapshotUpdated, object: nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadHistory()
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
        """
        loadHistory()
    }

    @objc private func rangeChanged() { loadHistory() }

    private func loadHistory() {
        let seconds: TimeInterval
        switch rangeControl.selectedSegment {
        case 1: seconds = 3_600
        case 2: seconds = 86_400
        default: seconds = 900
        }
        let values = (try? AppServices.shared.storage.monitoringSamples(
            serverId: server.id, since: Date().addingTimeInterval(-seconds))) ?? []
        let reduced = downsample(values, maximum: 700)
        cpuChart.values = reduced.map(\.cpu)
        ramChart.values = reduced.map(\.ram)
        diskChart.values = reduced.map(\.disk)
    }

    private func downsample(_ samples: [MonitoringSample], maximum: Int) -> [MonitoringSample] {
        guard samples.count > maximum else { return samples }
        let stride = Double(samples.count) / Double(maximum)
        return (0..<maximum).map { samples[min(samples.count - 1, Int(Double($0) * stride))] }
    }
}

private final class HistoryChartView: NSView {
    let title: String
    let color: NSColor
    var values: [Double] = [] { didSet { needsDisplay = true } }

    init(title: String, color: NSColor) {
        self.title = title
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        let label = "\(title)  \(values.last.map { String(format: "%.0f%%", $0) } ?? "—")"
        label.draw(at: NSPoint(x: 8, y: bounds.height - 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ])
        guard values.count > 1 else { return }
        let plot = bounds.insetBy(dx: 8, dy: 8)
        let top = plot.maxY - 18
        let height = max(1, top - plot.minY)
        let path = NSBezierPath()
        path.lineWidth = 1.5
        for (index, raw) in values.enumerated() {
            let x = plot.minX + CGFloat(index) / CGFloat(values.count - 1) * plot.width
            let normalized = min(100, max(0, raw)) / 100
            let point = NSPoint(x: x, y: plot.minY + CGFloat(normalized) * height)
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        color.setStroke()
        path.stroke()
    }
}
