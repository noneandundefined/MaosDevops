import Cocoa

final class ServersListViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var servers: [Server] = []
    private var snapshots: [UUID: ServerSnapshot] = [:]
    private let groups = ServerGroup.allCases.sorted { $0.sortOrder < $1.sortOrder }

    private let toolbar = NSStackView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

        let title = NSTextField(labelWithString: "Servers")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "Add Server", target: self, action: #selector(addServer))
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(reload))
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.addArrangedSubview(addButton)
        toolbar.addArrangedSubview(refreshButton)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        outline.headerView = nil
        outline.rowHeight = 26
        outline.allowsMultipleSelection = false
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.doubleAction = #selector(openSelected)
        outline.target = self

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        col.title = "Server"
        col.width = 700
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(toolbar)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            toolbar.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: .appServicesDidBootstrap,
            object: nil
        )
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Lazy: only refresh when visible
        reload()
    }

    @objc private func reload() {
        servers = (try? AppServices.shared.storage.allServers()) ?? []
        snapshots = (try? AppServices.shared.storage.latestMonitoringSnapshots()) ?? [:]
        outline.reloadData()
        for group in groups {
            outline.expandItem(group)
        }
        if let fav = outline.child(0, ofItem: nil) as? String, fav == "Favorites" {
            outline.expandItem(fav)
        }
    }

    @objc private func addServer() {
        presentEditor(server: nil)
    }

    @objc private func openSelected() {
        guard let server = selectedServer() else { return }
        let detail = ServerDetailViewController(server: server)
        if let container = parent as? ContentContainerViewController {
            container.embed(detail)
        } else if let window = view.window,
                  let split = window.contentViewController as? NSSplitViewController,
                  let content = split.splitViewItems.last?.viewController as? ContentContainerViewController {
            content.embed(detail)
        }
    }

    private func selectedServer() -> Server? {
        let item = outline.item(atRow: outline.selectedRow)
        return item as? Server
    }

    private func presentEditor(server: Server?) {
        let editor = ServerEditorViewController(server: server)
        editor.onSave = { [weak self] in
            self?.reload()
        }
        presentAsSheet(editor)
    }

    private func servers(in group: ServerGroup) -> [Server] {
        servers.filter { $0.group == group }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var favoriteServers: [Server] {
        servers.filter(\.isFavorite).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return 1 + groups.count // Favorites + groups
        }
        if let title = item as? String, title == "Favorites" {
            return favoriteServers.count
        }
        if let group = item as? ServerGroup {
            return servers(in: group).count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ServerGroup || (item as? String) == "Favorites"
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if index == 0 { return "Favorites" }
            return groups[index - 1]
        }
        if let title = item as? String, title == "Favorites" {
            return favoriteServers[index]
        }
        if let group = item as? ServerGroup {
            return servers(in: group)[index]
        }
        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ServerRow")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            c.addSubview(label)
            c.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor)
            ])
            return c
        }()

        if let title = item as? String {
            cell.textField?.stringValue = title
            cell.textField?.font = NSFont.boldSystemFont(ofSize: 12)
        } else if let group = item as? ServerGroup {
            cell.textField?.stringValue = group.rawValue
            cell.textField?.font = NSFont.boldSystemFont(ofSize: 12)
        } else if let server = item as? Server {
            let snap = snapshots[server.id]
            let status = snap?.status ?? .unknown
            let dot: String
            switch status {
            case .online: dot = "●"
            case .offline: dot = "○"
            case .connecting: dot = "◌"
            case .unknown: dot = "•"
            }
            if status == .offline {
                cell.textField?.stringValue = "\(dot) \(server.name)     Offline"
            } else if let snap = snap, snap.updatedAt != nil {
                cell.textField?.stringValue = String(
                    format: "%@ %@     CPU %.0f%%   RAM %.0f%%   Disk %.0f%%",
                    dot, server.name, snap.cpuPercent, snap.ramPercent, snap.diskPercent
                )
            } else {
                let star = server.isFavorite ? "★ " : ""
                cell.textField?.stringValue = "\(dot) \(star)\(server.name)  \(server.username)@\(server.host)"
            }
            cell.textField?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        return cell
    }

    override func rightMouseDown(with event: NSEvent) {
        let local = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: local)
        guard row >= 0, let server = outline.item(atRow: row) as? Server else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openSelected), keyEquivalent: "")
        menu.addItem(withTitle: "Edit…", action: #selector(editSelected), keyEquivalent: "")
        menu.addItem(withTitle: "Test Connection", action: #selector(testSelected), keyEquivalent: "")
        menu.addItem(withTitle: server.isFavorite ? "Remove from Favorites" : "Add to Favorites", action: #selector(toggleFavorite), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: outline)
        _ = server
    }

    @objc private func editSelected() {
        guard let server = selectedServer() else { return }
        presentEditor(server: server)
    }

    @objc private func toggleFavorite() {
        guard var server = selectedServer() else { return }
        server.isFavorite.toggle()
        server.updatedAt = Date()
        try? AppServices.shared.storage.saveServer(server)
        reload()
    }

    @objc private func deleteSelected() {
        guard let server = selectedServer() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(server.name)?"
        alert.informativeText = "This removes the server from the local list. Keychain secret will also be deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppServices.shared.sshManager.disconnect(serverId: server.id)
        try? AppServices.shared.keychain.deleteSecret(account: server.secretId)
        try? AppServices.shared.storage.deleteServer(id: server.id)
        reload()
    }

    @objc private func testSelected() {
        guard let server = selectedServer() else { return }
        let alert = NSAlert()
        alert.messageText = "Testing connection…"
        alert.informativeText = "\(server.username)@\(server.host):\(server.port)"
        alert.addButton(withTitle: "Cancel")
        // Non-blocking: fire and update via async
        AppServices.shared.sshManager.testConnection(server: server) { result in
            let done = NSAlert()
            switch result {
            case .success(let info):
                done.messageText = "Connected"
                done.informativeText = info
            case .failure(let error):
                done.messageText = "Connection failed"
                done.informativeText = error.localizedDescription
            }
            done.runModal()
        }
    }
}
