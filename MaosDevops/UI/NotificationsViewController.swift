import Cocoa
import UserNotifications

enum NotificationRuleSource: String, CaseIterable, Codable {
    case monitoring
    case health
    case action
    case custom

    var title: String {
        switch self {
        case .monitoring: return L10n.text("Monitoring")
        case .health: return L10n.text("Health Checks")
        case .action: return L10n.text("Actions")
        case .custom: return L10n.text("Custom command")
        }
    }
}

enum MonitoringNotificationMetric: String, CaseIterable, Codable {
    case serverOffline, cpu, ram, disk, load1

    var title: String {
        switch self {
        case .serverOffline: return L10n.text("Server offline")
        case .cpu: return "CPU ≥"
        case .ram: return "RAM ≥"
        case .disk: return L10n.text("Disk") + " ≥"
        case .load1: return "Load 1m ≥"
        }
    }
}

enum NotificationResultMode: String, CaseIterable, Codable {
    case failed, succeeded, any

    var title: String {
        switch self {
        case .failed: return L10n.text("Failed")
        case .succeeded: return L10n.text("Succeeded")
        case .any: return L10n.text("Any result")
        }
    }
}

struct NotificationRule: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var enabled: Bool
    var serverId: UUID
    var source: NotificationRuleSource
    var monitoringMetric: MonitoringNotificationMetric
    var threshold: Double
    var healthCheckId: UUID?
    var actionId: UUID?
    var resultMode: NotificationResultMode
    var customType: String
    var customCommand: String
    var message: String
    var intervalSeconds: Int
    var cooldownSeconds: Int
    var notifyRecovery: Bool

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        serverId: UUID,
        source: NotificationRuleSource = .monitoring,
        monitoringMetric: MonitoringNotificationMetric = .serverOffline,
        threshold: Double = 90,
        healthCheckId: UUID? = nil,
        actionId: UUID? = nil,
        resultMode: NotificationResultMode = .failed,
        customType: String = "",
        customCommand: String = "",
        message: String = "",
        intervalSeconds: Int = 30,
        cooldownSeconds: Int = 300,
        notifyRecovery: Bool = true
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.serverId = serverId
        self.source = source
        self.monitoringMetric = monitoringMetric
        self.threshold = threshold
        self.healthCheckId = healthCheckId
        self.actionId = actionId
        self.resultMode = resultMode
        self.customType = customType
        self.customCommand = customCommand
        self.message = message
        self.intervalSeconds = intervalSeconds
        self.cooldownSeconds = cooldownSeconds
        self.notifyRecovery = notifyRecovery
    }
}

extension Notification.Name {
    static let maosActionDidFinish = Notification.Name("MaosDevOps.actionDidFinish")
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let storage: StorageService
    private let sshManager: SSHConnectionManager
    private let monitoring: MonitoringService
    private let healthChecks: HealthCheckRunner
    private let defaultsKey = "MaosDevOps.notificationRules.v1"
    private let lock = NSLock()
    private var storedRules: [NotificationRule] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.maosdevops.notifications", qos: .utility)
    private var lastRun: [UUID: Date] = [:]
    private var active: [UUID: Bool] = [:]
    private var lastNotification: [UUID: Date] = [:]
    private var observer: NSObjectProtocol?

    init(storage: StorageService, sshManager: SSHConnectionManager,
         monitoring: MonitoringService, healthChecks: HealthCheckRunner) {
        self.storage = storage
        self.sshManager = sshManager
        self.monitoring = monitoring
        self.healthChecks = healthChecks
        super.init()
        load()
    }

    var rules: [NotificationRule] {
        lock.lock()
        defer { lock.unlock() }
        return storedRules
    }

    func save(_ rule: NotificationRule) {
        lock.lock()
        if let index = storedRules.firstIndex(where: { $0.id == rule.id }) {
            storedRules[index] = rule
        } else {
            storedRules.append(rule)
        }
        let snapshot = storedRules
        lock.unlock()
        persist(snapshot)
        queue.async { [weak self] in
            self?.lastRun[rule.id] = nil
            self?.active[rule.id] = nil
            self?.lastNotification[rule.id] = nil
        }
    }

    func delete(id: UUID) {
        lock.lock()
        storedRules.removeAll { $0.id == id }
        let snapshot = storedRules
        lock.unlock()
        persist(snapshot)
        queue.async { [weak self] in
            self?.lastRun[id] = nil
            self?.active[id] = nil
            self?.lastNotification[id] = nil
        }
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("[MaosDevOps] Notification permission error: %@", error.localizedDescription)
            } else {
                NSLog("[MaosDevOps] Notification permission granted=%@", granted ? "yes" : "no")
            }
        }

        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .maosActionDidFinish,
                object: nil,
                queue: nil
            ) { [weak self] note in
                self?.handleActionEvent(note)
            }
        }

        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 2, repeating: .seconds(5))
            source.setEventHandler { [weak self] in self?.evaluateDueRules() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func sendTestNotification() {
        deliver(title: "Maos DevOps", body: L10n.text("Test notification"), identifier: "test-\(UUID().uuidString)")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([NotificationRule].self, from: data) else {
            storedRules = []
            return
        }
        storedRules = decoded
    }

    private func persist(_ rules: [NotificationRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func evaluateDueRules() {
        let now = Date()
        for rule in rules where rule.enabled && rule.source != .action {
            let interval = Double(max(5, rule.intervalSeconds))
            let due = lastRun[rule.id].map { now.timeIntervalSince($0) >= interval } ?? true
            guard due else { continue }
            lastRun[rule.id] = now
            evaluate(rule)
        }
    }

    private func evaluate(_ rule: NotificationRule) {
        guard let server = (try? storage.allServers())?.first(where: { $0.id == rule.serverId }) else {
            return
        }

        switch rule.source {
        case .monitoring:
            monitoring.fetchOnce(server: server) { [weak self] result in
                guard let self = self else { return }
                self.queue.async {
                    switch result {
                    case .success(let snapshot):
                        let condition = self.monitoringCondition(rule, snapshot: snapshot)
                        self.process(rule: rule, triggered: condition.triggered,
                                     detail: condition.detail, recovery: condition.recovery,
                                     serverName: server.name)
                    case .failure:
                        let triggered = rule.monitoringMetric == .serverOffline
                        self.process(rule: rule, triggered: triggered,
                                     detail: L10n.text("Server is not reachable"),
                                     recovery: L10n.text("Server is reachable again"),
                                     serverName: server.name)
                    }
                }
            }

        case .health:
            guard let checkId = rule.healthCheckId,
                  let check = (try? storage.allHealthChecks(serverId: server.id))?.first(where: { $0.id == checkId }) else {
                return
            }
            healthChecks.run(check, server: server) { [weak self] result in
                self?.queue.async {
                    self?.process(rule: rule, triggered: !result.healthy,
                                  detail: "\(check.name): \(result.summary)",
                                  recovery: "\(check.name): " + L10n.text("available again"),
                                  serverName: server.name)
                }
            }

        case .custom:
            let command = rule.customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return }
            sshManager.execute(on: server, command: command) { [weak self] result in
                self?.queue.async {
                    let success: Bool
                    let detail: String
                    switch result {
                    case .success(let value):
                        success = value.exitCode == 0
                        let output = (value.stderr.isEmpty ? value.stdout : value.stderr)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        detail = output.isEmpty ? "Exit \(value.exitCode)" : String(output.prefix(180))
                    case .failure(let error):
                        success = false
                        detail = error.localizedDescription
                    }
                    let triggered = self?.matches(rule.resultMode, success: success) ?? false
                    self?.process(rule: rule, triggered: triggered, detail: detail,
                                  recovery: L10n.text("Condition returned to normal"),
                                  serverName: server.name)
                }
            }

        case .action:
            break
        }
    }

    private func monitoringCondition(_ rule: NotificationRule, snapshot: ServerSnapshot)
        -> (triggered: Bool, detail: String, recovery: String) {
        switch rule.monitoringMetric {
        case .serverOffline:
            let down = snapshot.status == .offline
            return (down, L10n.text("Server is not reachable"), L10n.text("Server is reachable again"))
        case .cpu:
            return (snapshot.cpuPercent >= rule.threshold,
                    String(format: "CPU %.1f%% ≥ %.1f%%", snapshot.cpuPercent, rule.threshold),
                    String(format: "CPU %.1f%%", snapshot.cpuPercent))
        case .ram:
            return (snapshot.ramPercent >= rule.threshold,
                    String(format: "RAM %.1f%% ≥ %.1f%%", snapshot.ramPercent, rule.threshold),
                    String(format: "RAM %.1f%%", snapshot.ramPercent))
        case .disk:
            return (snapshot.diskPercent >= rule.threshold,
                    String(format: "%@ %.1f%% ≥ %.1f%%", L10n.text("Disk"), snapshot.diskPercent, rule.threshold),
                    String(format: "%@ %.1f%%", L10n.text("Disk"), snapshot.diskPercent))
        case .load1:
            return (snapshot.load1 >= rule.threshold,
                    String(format: "Load 1m %.2f ≥ %.2f", snapshot.load1, rule.threshold),
                    String(format: "Load 1m %.2f", snapshot.load1))
        }
    }

    private func handleActionEvent(_ note: Notification) {
        guard let actionIdText = note.userInfo?["actionId"] as? String,
              let actionId = UUID(uuidString: actionIdText),
              let serverIdText = note.userInfo?["serverId"] as? String,
              let serverId = UUID(uuidString: serverIdText),
              let success = note.userInfo?["success"] as? Bool else { return }

        let summary = note.userInfo?["summary"] as? String ?? ""
        let serverName = (try? storage.allServers())?.first(where: { $0.id == serverId })?.name ?? "Server"
        for rule in rules where rule.enabled && rule.source == .action &&
            rule.serverId == serverId && rule.actionId == actionId {
            let triggered = matches(rule.resultMode, success: success)
            queue.async { [weak self] in
                self?.process(rule: rule, triggered: triggered, detail: summary,
                              recovery: L10n.text("Action completed successfully"),
                              serverName: serverName)
            }
        }
    }

    private func matches(_ mode: NotificationResultMode, success: Bool) -> Bool {
        switch mode {
        case .failed: return !success
        case .succeeded: return success
        case .any: return true
        }
    }

    private func process(rule: NotificationRule, triggered: Bool, detail: String,
                         recovery: String, serverName: String) {
        let wasActive = active[rule.id] ?? false
        active[rule.id] = triggered

        if triggered {
            let now = Date()
            let cooldown = Double(max(0, rule.cooldownSeconds))
            let mayNotify = !wasActive || lastNotification[rule.id].map { now.timeIntervalSince($0) >= cooldown } ?? true
            guard mayNotify else { return }
            lastNotification[rule.id] = now
            let title = rule.customType.isEmpty ? rule.name : rule.customType
            let body = rule.message.isEmpty ? "\(serverName): \(detail)" : rule.message
            deliver(title: title, body: body, identifier: "rule-\(rule.id.uuidString)")
        } else if wasActive && rule.notifyRecovery {
            let title = rule.customType.isEmpty ? rule.name : rule.customType
            deliver(title: title, body: "\(serverName): \(recovery)",
                    identifier: "recovery-\(rule.id.uuidString)-\(Int(Date().timeIntervalSince1970))")
        }
    }

    private func deliver(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Maos DevOps" : title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[MaosDevOps] Failed to deliver notification: %@", error.localizedDescription)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound])
    }
}

final class NotificationsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var rules: [NotificationRule] = []
    private var servers: [Server] = []

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Notifications")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString:
            "Create macOS notifications for server monitoring, health checks, actions, or a custom SSH command.")
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: "Add", target: self, action: #selector(addRule))
        let edit = NSButton(title: "Edit", target: self, action: #selector(editRule))
        let remove = NSButton(title: "Delete", target: self, action: #selector(deleteRule))
        let test = NSButton(title: "Test notification", target: self, action: #selector(testNotification))
        let buttons = NSStackView(views: [add, edit, remove, test])
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        table.target = self
        table.doubleAction = #selector(editRuleByDoubleClick)
        for (id, label, width) in [
            ("enabled", "On", 42), ("name", "Name", 170), ("server", "Server", 170),
            ("type", "Type", 110), ("condition", "Condition", 260)
        ] as [(String, String, CGFloat)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = label
            col.width = width
            table.addTableColumn(col)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(hint)
        root.addSubview(buttons)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        L10n.apply(to: root)
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        servers = (try? AppServices.shared.storage.allServers()) ?? []
        rules = AppServices.shared.notifications.rules.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        table.reloadData()
    }

    private func selectedRule() -> NotificationRule? {
        let row = table.selectedRow
        return row >= 0 && row < rules.count ? rules[row] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = rules[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let value: String
        switch id {
        case "enabled": value = rule.enabled ? "✓" : "—"
        case "name": value = rule.name
        case "server": value = servers.first(where: { $0.id == rule.serverId })?.name ?? "—"
        case "type": value = rule.source.title
        case "condition": value = conditionText(rule)
        default: value = ""
        }
        let field = NSTextField(labelWithString: value)
        field.font = NSFont.systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = value
        let cell = NSTableCellView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func conditionText(_ rule: NotificationRule) -> String {
        switch rule.source {
        case .monitoring:
            if rule.monitoringMetric == .serverOffline { return rule.monitoringMetric.title }
            return "\(rule.monitoringMetric.title) \(String(format: "%.1f", rule.threshold))"
        case .health:
            let name = (try? AppServices.shared.storage.allHealthChecks(serverId: rule.serverId))?
                .first(where: { $0.id == rule.healthCheckId })?.name
            return name ?? L10n.text("Health check unavailable")
        case .action:
            let name = (try? AppServices.shared.storage.allActions())?
                .first(where: { $0.id == rule.actionId })?.name ?? L10n.text("Action unavailable")
            return "\(name) — \(rule.resultMode.title)"
        case .custom:
            return rule.customType.isEmpty ? rule.resultMode.title : "\(rule.customType) — \(rule.resultMode.title)"
        }
    }

    @objc private func addRule() {
        guard !servers.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.text("Add a server first")
            alert.runModal()
            return
        }
        presentAsSheet(NotificationRuleEditorViewController(rule: nil) { [weak self] in self?.reload() })
    }

    @objc private func editRule() {
        guard let rule = selectedRule() else { return }
        presentAsSheet(NotificationRuleEditorViewController(rule: rule) { [weak self] in self?.reload() })
    }

    @objc private func editRuleByDoubleClick() {
        guard table.clickedRow >= 0, table.clickedRow < rules.count else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        editRule()
    }

    @objc private func deleteRule() {
        guard let rule = selectedRule() else { return }
        AppServices.shared.notifications.delete(id: rule.id)
        reload()
    }

    @objc private func testNotification() {
        AppServices.shared.notifications.sendTestNotification()
    }
}

private final class NotificationRuleEditorViewController: NSViewController {
    private var rule: NotificationRule?
    private let onSave: () -> Void
    private var servers: [Server] = []
    private var checks: [HealthCheck] = []
    private var actions: [CustomAction] = []

    private let nameField = NSTextField(string: "")
    private let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let serverPopup = NSPopUpButton()
    private let sourcePopup = NSPopUpButton()
    private let metricPopup = NSPopUpButton()
    private let thresholdField = NSTextField(string: "90")
    private let itemPopup = NSPopUpButton()
    private let resultPopup = NSPopUpButton()
    private let customTypeField = NSTextField(string: "")
    private let commandField = NSTextField(string: "")
    private let messageField = NSTextField(string: "")
    private let intervalField = NSTextField(string: "30")
    private let cooldownField = NSTextField(string: "300")
    private let recoveryButton = NSButton(checkboxWithTitle: "Notify when recovered", target: nil, action: nil)

    private let thresholdLabel = NSTextField(labelWithString: "Threshold")
    private let itemLabel = NSTextField(labelWithString: "Check / action")
    private let resultLabel = NSTextField(labelWithString: "Trigger result")
    private let customTypeLabel = NSTextField(labelWithString: "Custom type")
    private let commandLabel = NSTextField(labelWithString: "Trigger command")

    init(rule: NotificationRule?, onSave: @escaping () -> Void) {
        self.rule = rule
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        servers = (try? AppServices.shared.storage.allServers()) ?? []
        actions = (try? AppServices.shared.storage.allActions()) ?? []

        sourcePopup.addItems(withTitles: NotificationRuleSource.allCases.map { $0.title })
        metricPopup.addItems(withTitles: MonitoringNotificationMetric.allCases.map { $0.title })
        resultPopup.addItems(withTitles: NotificationResultMode.allCases.map { $0.title })

        serverPopup.target = self
        serverPopup.action = #selector(serverChanged)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        metricPopup.target = self
        metricPopup.action = #selector(metricChanged)

        reloadServers()

        if let rule = rule {
            nameField.stringValue = rule.name
            enabledButton.state = rule.enabled ? .on : .off
            selectServer(rule.serverId)
            sourcePopup.selectItem(at: NotificationRuleSource.allCases.firstIndex(of: rule.source) ?? 0)
            metricPopup.selectItem(at: MonitoringNotificationMetric.allCases.firstIndex(of: rule.monitoringMetric) ?? 0)
            thresholdField.stringValue = String(format: "%.1f", rule.threshold)
            resultPopup.selectItem(at: NotificationResultMode.allCases.firstIndex(of: rule.resultMode) ?? 0)
            customTypeField.stringValue = rule.customType
            commandField.stringValue = rule.customCommand
            messageField.stringValue = rule.message
            intervalField.stringValue = "\(rule.intervalSeconds)"
            cooldownField.stringValue = "\(rule.cooldownSeconds)"
            recoveryButton.state = rule.notifyRecovery ? .on : .off
        } else {
            enabledButton.state = .on
            recoveryButton.state = .on
        }

        reloadItems()

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Server"), serverPopup],
            [NSTextField(labelWithString: "Type"), sourcePopup],
            [NSTextField(labelWithString: "Monitoring event"), metricPopup],
            [thresholdLabel, thresholdField],
            [itemLabel, itemPopup],
            [resultLabel, resultPopup],
            [customTypeLabel, customTypeField],
            [commandLabel, commandField],
            [NSTextField(labelWithString: "Notification text"), messageField],
            [NSTextField(labelWithString: "Interval, sec"), intervalField],
            [NSTextField(labelWithString: "Cooldown, sec"), cooldownField],
            [NSTextField(labelWithString: ""), enabledButton],
            [NSTextField(labelWithString: ""), recoveryButton]
        ])
        form.rowSpacing = 7
        form.columnSpacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEdit))
        let save = NSButton(title: "Save", target: self, action: #selector(saveEdit))
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 590, height: 500))
        root.addSubview(form)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 310),
            buttons.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        L10n.apply(to: root)
        view = root
        updateVisibility()
    }

    private func reloadServers() {
        serverPopup.removeAllItems()
        for server in servers {
            serverPopup.addItem(withTitle: server.name)
            serverPopup.lastItem?.representedObject = server.id.uuidString
        }
    }

    private func selectServer(_ id: UUID) {
        for (index, item) in serverPopup.itemArray.enumerated() {
            if item.representedObject as? String == id.uuidString {
                serverPopup.selectItem(at: index)
                return
            }
        }
    }

    private var selectedServerId: UUID? {
        guard let text = serverPopup.selectedItem?.representedObject as? String else { return nil }
        return UUID(uuidString: text)
    }

    private var selectedSource: NotificationRuleSource {
        let index = max(0, sourcePopup.indexOfSelectedItem)
        return NotificationRuleSource.allCases[min(index, NotificationRuleSource.allCases.count - 1)]
    }

    private var selectedMetric: MonitoringNotificationMetric {
        let index = max(0, metricPopup.indexOfSelectedItem)
        return MonitoringNotificationMetric.allCases[min(index, MonitoringNotificationMetric.allCases.count - 1)]
    }

    private var selectedResult: NotificationResultMode {
        let index = max(0, resultPopup.indexOfSelectedItem)
        return NotificationResultMode.allCases[min(index, NotificationResultMode.allCases.count - 1)]
    }

    @objc private func serverChanged() {
        reloadItems()
        updateVisibility()
    }

    @objc private func sourceChanged() {
        reloadItems()
        updateVisibility()
    }

    @objc private func metricChanged() { updateVisibility() }

    private func reloadItems() {
        let previousId: UUID? = {
            if selectedSource == .health { return rule?.healthCheckId }
            if selectedSource == .action { return rule?.actionId }
            return nil
        }()

        itemPopup.removeAllItems()
        guard let sid = selectedServerId else { return }

        if selectedSource == .health {
            checks = (try? AppServices.shared.storage.allHealthChecks(serverId: sid)) ?? []
            for check in checks {
                itemPopup.addItem(withTitle: "\(check.name) — \(check.target)")
                itemPopup.lastItem?.representedObject = check.id.uuidString
            }
        } else if selectedSource == .action {
            actions = ((try? AppServices.shared.storage.allActions()) ?? []).filter {
                $0.serverId == nil || $0.serverId == sid
            }
            for action in actions {
                itemPopup.addItem(withTitle: action.name)
                itemPopup.lastItem?.representedObject = action.id.uuidString
            }
        }

        if let previousId = previousId {
            for (index, item) in itemPopup.itemArray.enumerated() {
                if item.representedObject as? String == previousId.uuidString {
                    itemPopup.selectItem(at: index)
                    break
                }
            }
        }
    }

    private func updateVisibility() {
        let source = selectedSource
        metricPopup.isHidden = source != .monitoring
        thresholdLabel.isHidden = source != .monitoring || selectedMetric == .serverOffline
        thresholdField.isHidden = thresholdLabel.isHidden
        itemLabel.isHidden = source != .health && source != .action
        itemPopup.isHidden = itemLabel.isHidden
        resultLabel.isHidden = source != .action && source != .custom
        resultPopup.isHidden = resultLabel.isHidden
        customTypeLabel.isHidden = source != .custom
        customTypeField.isHidden = source != .custom
        commandLabel.isHidden = source != .custom
        commandField.isHidden = source != .custom
    }

    @objc private func cancelEdit() { dismiss(nil) }

    @objc private func saveEdit() {
        guard let serverId = selectedServerId else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let source = selectedSource
        let selectedItemId = (itemPopup.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:))
        if (source == .health || source == .action) && selectedItemId == nil { return }
        if source == .custom && commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }

        var value = rule ?? NotificationRule(name: name, serverId: serverId)
        value.name = name
        value.enabled = enabledButton.state == .on
        value.serverId = serverId
        value.source = source
        value.monitoringMetric = selectedMetric
        value.threshold = Double(thresholdField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 90
        value.healthCheckId = source == .health ? selectedItemId : nil
        value.actionId = source == .action ? selectedItemId : nil
        value.resultMode = selectedResult
        value.customType = customTypeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.customCommand = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.intervalSeconds = max(5, Int(intervalField.stringValue) ?? 30)
        value.cooldownSeconds = max(0, Int(cooldownField.stringValue) ?? 300)
        value.notifyRecovery = recoveryButton.state == .on

        AppServices.shared.notifications.save(value)
        onSave()
        dismiss(nil)
    }
}
