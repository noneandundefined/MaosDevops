import Cocoa

final class ProjectsViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private var projects: [Project] = []
    private var serversById: [UUID: Server] = [:]

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Projects")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: "Add Project", target: self, action: #selector(addProject))
        add.translatesAutoresizingMaskIntoConstraints = false

        outline.headerView = nil
        outline.rowHeight = 24
        outline.dataSource = self
        outline.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("p"))
        col.width = 600
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let deploy = NSButton(title: "Run Deploy Workflow…", target: self, action: #selector(runDeploy))
        deploy.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(add)
        root.addSubview(scroll)
        root.addSubview(deploy)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            add.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            add.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: deploy.topAnchor, constant: -10),
            deploy.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            deploy.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func reload() {
        projects = (try? AppServices.shared.storage.allProjects()) ?? []
        let servers = (try? AppServices.shared.storage.allServers()) ?? []
        serversById = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        outline.reloadData()
        projects.forEach { outline.expandItem($0) }
    }

    @objc private func addProject() {
        let alert = NSAlert()
        alert.messageText = "New Project"
        let field = NSTextField(string: "NeoSync")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let servers = (try? AppServices.shared.storage.allServers()) ?? []
        let project = Project(name: field.stringValue, serverIds: servers.map(\.id))
        try? AppServices.shared.storage.saveProject(project)
        reload()
    }

    @objc private func runDeploy() {
        guard let project = outline.item(atRow: outline.selectedRow) as? Project,
              let firstServerId = project.serverIds.first,
              let server = serversById[firstServerId] else {
            let alert = NSAlert()
            alert.messageText = "Select a project with at least one server"
            alert.runModal()
            return
        }
        presentAsSheet(DeployViewController(server: server, projectName: project.name))
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return projects.count }
        if let p = item as? Project { return p.serverIds.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Project
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return projects[index] }
        if let p = item as? Project {
            let id = p.serverIds[index]
            return serversById[id]?.name ?? id.uuidString
        }
        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let text: String
        if let p = item as? Project {
            text = p.name
        } else if let name = item as? String {
            text = "├── \(name)"
        } else {
            text = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.font = item is Project ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

final class DeployViewController: NSViewController {
    private let server: Server
    private let projectName: String
    private let stepsLabel = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextView()
    private let steps = [
        "git pull",
        "docker compose pull",
        "docker compose up -d",
        "docker compose ps"
    ]
    private var stepStates: [String] = []

    init(server: Server, projectName: String) {
        self.server = server
        self.projectName = projectName
        super.init(nibName: nil, bundle: nil)
        stepStates = Array(repeating: "○", count: steps.count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let title = NSTextField(labelWithString: "Deploy — \(projectName)")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        stepsLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        stepsLabel.translatesAutoresizingMaskIntoConstraints = false
        renderSteps()

        let run = NSButton(title: "Run Deploy", target: self, action: #selector(runDeploy))
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        let bar = NSStackView(views: [run, close])
        bar.translatesAutoresizingMaskIntoConstraints = false

        output.isEditable = false
        output.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(stepsLabel)
        root.addSubview(bar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stepsLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            stepsLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            stepsLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            bar.topAnchor.constraint(equalTo: stepsLabel.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        view = root
    }

    private func renderSteps() {
        stepsLabel.stringValue = zip(stepStates, steps).map { "\($0.0) \($0.1)" }.joined(separator: "\n")
    }

    @objc private func closeSheet() { dismiss(nil) }

    @objc private func runDeploy() {
        let alert = NSAlert()
        alert.messageText = "Confirm deploy to \(server.name)?"
        alert.informativeText = steps.joined(separator: "\n")
        alert.addButton(withTitle: "Deploy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let action = CustomAction(
            name: "Deploy \(projectName)",
            serverId: server.id,
            command: steps.joined(separator: "\n"),
            type: .group,
            confirmationRequired: false,
            stopOnError: true
        )
        stepStates = Array(repeating: "○", count: steps.count)
        renderSteps()
        output.string = ""

        // Run steps sequentially with UI status
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for (idx, cmd) in self.steps.enumerated() {
                DispatchQueue.main.async {
                    self.stepStates[idx] = "●"
                    self.renderSteps()
                }
                let sem = DispatchSemaphore(value: 0)
                var ok = false
                var text = ""
                AppServices.shared.sshManager.execute(on: self.server, command: cmd) { result in
                    switch result {
                    case .success(let r):
                        ok = r.exitCode == 0
                        text = r.stdout + r.stderr
                    case .failure(let e):
                        ok = false
                        text = e.localizedDescription
                    }
                    sem.signal()
                }
                sem.wait()
                DispatchQueue.main.async {
                    self.stepStates[idx] = ok ? "✓" : "✗"
                    self.renderSteps()
                    self.output.string += "$ \(cmd)\n\(text)\n\n"
                    self.output.scrollToEndOfDocument(nil)
                }
                if !ok { break }
            }
            _ = action
        }
    }
}
