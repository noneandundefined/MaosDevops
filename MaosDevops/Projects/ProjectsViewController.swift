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
        let edit = NSButton(title: "Edit", target: self, action: #selector(editProject))
        let remove = NSButton(title: "Delete", target: self, action: #selector(deleteProject))
        let projectBar = NSStackView(views: [add, edit, remove])
        projectBar.spacing = 6
        projectBar.translatesAutoresizingMaskIntoConstraints = false

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

        let deploy = NSButton(title: "Deploy Workflows…", target: self, action: #selector(runDeploy))
        deploy.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(projectBar)
        root.addSubview(scroll)
        root.addSubview(deploy)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            projectBar.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            projectBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
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
        presentProjectEditor(nil)
    }

    @objc private func editProject() {
        guard let project = outline.item(atRow: outline.selectedRow) as? Project else { return }
        presentProjectEditor(project)
    }

    @objc private func deleteProject() {
        guard let project = outline.item(atRow: outline.selectedRow) as? Project else { return }
        let alert = NSAlert()
        alert.messageText = "Delete project \(project.name)?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? AppServices.shared.storage.deleteProject(id: project.id)
        reload()
    }

    private func presentProjectEditor(_ project: Project?) {
        let servers = (try? AppServices.shared.storage.allServers()) ?? []
        let actions = (try? AppServices.shared.storage.allActions()) ?? []
        presentAsSheet(ProjectEditorViewController(project: project, servers: servers, actions: actions) { [weak self] in self?.reload() })
    }

    @objc private func runDeploy() {
        guard let project = outline.item(atRow: outline.selectedRow) as? Project else {
            let alert = NSAlert()
            alert.messageText = "Select a project"
            alert.runModal()
            return
        }
        presentAsSheet(DeployWorkflowsViewController(project: project, serversById: serversById))
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

private final class ProjectEditorViewController: NSViewController {
    private var project: Project?
    private let servers: [Server]
    private let actions: [CustomAction]
    private let onSave: () -> Void
    private let nameField = NSTextField(string: "")
    private let notesField = NSTextField(string: "")
    private var serverButtons: [NSButton] = []
    private var actionButtons: [NSButton] = []

    init(project: Project?, servers: [Server], actions: [CustomAction], onSave: @escaping () -> Void) {
        self.project = project
        self.servers = servers
        self.actions = actions
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))
        nameField.stringValue = project?.name ?? ""
        notesField.stringValue = project?.notes ?? ""
        let nameLabel = NSTextField(labelWithString: "Project name")
        let notesLabel = NSTextField(labelWithString: "Notes")
        [nameLabel, notesLabel, nameField, notesField].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let serverStack = NSStackView()
        serverStack.orientation = .vertical
        serverStack.alignment = .leading
        serverStack.spacing = 4
        serverButtons = servers.enumerated().map { index, server in
            let button = NSButton(checkboxWithTitle: server.name, target: nil, action: nil)
            button.tag = index
            button.state = project?.serverIds.contains(server.id) == true ? .on : .off
            serverStack.addArrangedSubview(button)
            return button
        }
        let actionStack = NSStackView()
        actionStack.orientation = .vertical
        actionStack.alignment = .leading
        actionStack.spacing = 4
        actionButtons = actions.enumerated().map { index, action in
            let button = NSButton(checkboxWithTitle: action.name, target: nil, action: nil)
            button.tag = index
            button.state = project?.actionIds.contains(action.id) == true ? .on : .off
            actionStack.addArrangedSubview(button)
            return button
        }
        serverStack.frame = NSRect(x: 0, y: 0, width: 270, height: max(260, serverStack.fittingSize.height))
        actionStack.frame = NSRect(x: 0, y: 0, width: 270, height: max(260, actionStack.fittingSize.height))
        let serverScroll = Self.scroll(serverStack)
        let actionScroll = Self.scroll(actionStack)
        let serversLabel = NSTextField(labelWithString: "Servers")
        let actionsLabel = NSTextField(labelWithString: "Actions")
        [serverScroll, actionScroll, serversLabel, actionsLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEdit))
        let save = NSButton(title: "Save", target: self, action: #selector(saveEdit))
        let buttons = NSStackView(views: [cancel, save])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        [nameLabel, nameField, notesLabel, notesField, serversLabel, serverScroll, actionsLabel, actionScroll, buttons].forEach { root.addSubview($0) }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3), nameField.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            notesLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 9), notesLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            notesField.topAnchor.constraint(equalTo: notesLabel.bottomAnchor, constant: 3), notesField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), notesField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            serversLabel.topAnchor.constraint(equalTo: notesField.bottomAnchor, constant: 12), serversLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            actionsLabel.topAnchor.constraint(equalTo: notesField.bottomAnchor, constant: 12), actionsLabel.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: 6),
            serverScroll.topAnchor.constraint(equalTo: serversLabel.bottomAnchor, constant: 4), serverScroll.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), serverScroll.trailingAnchor.constraint(equalTo: root.centerXAnchor, constant: -6), serverScroll.heightAnchor.constraint(equalToConstant: 260),
            actionScroll.topAnchor.constraint(equalTo: actionsLabel.bottomAnchor, constant: 4), actionScroll.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: 6), actionScroll.trailingAnchor.constraint(equalTo: nameField.trailingAnchor), actionScroll.heightAnchor.constraint(equalToConstant: 260),
            buttons.trailingAnchor.constraint(equalTo: nameField.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        view = root
    }

    private static func scroll(_ document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    @objc private func cancelEdit() { dismiss(nil) }
    @objc private func saveEdit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var value = project ?? Project(name: name)
        value.name = name
        value.notes = notesField.stringValue
        value.serverIds = serverButtons.filter { $0.state == .on }.map { servers[$0.tag].id }
        value.actionIds = actionButtons.filter { $0.state == .on }.map { actions[$0.tag].id }
        value.updatedAt = Date()
        try? AppServices.shared.storage.saveProject(value)
        onSave()
        dismiss(nil)
    }
}

final class DeployWorkflowsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let project: Project
    private let serversById: [UUID: Server]
    private let table = NSTableView()
    private var workflows: [DeployWorkflow] = []

    init(project: Project, serversById: [UUID: Server]) {
        self.project = project
        self.serversById = serversById
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 430))
        let title = NSTextField(labelWithString: "Deploy — \(project.name)")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: "Add", target: self, action: #selector(addWorkflow))
        let edit = NSButton(title: "Edit", target: self, action: #selector(editWorkflow))
        let remove = NSButton(title: "Delete", target: self, action: #selector(deleteWorkflow))
        let run = NSButton(title: "Run", target: self, action: #selector(runWorkflow))
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        let bar = NSStackView(views: [add, edit, remove, run, close])
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        for (id, label, width) in [("name", "Workflow", 190), ("server", "Server", 150),
                                   ("steps", "Steps", 60), ("flags", "Options", 190)] as [(String, String, CGFloat)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(bar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            bar.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        view = root
        reload()
    }

    private func reload() {
        workflows = (try? AppServices.shared.storage.allDeployWorkflows(projectId: project.id)) ?? []
        table.reloadData()
    }

    private func selected() -> DeployWorkflow? {
        let row = table.selectedRow
        guard row >= 0, row < workflows.count else { return nil }
        return workflows[row]
    }

    @objc private func closeSheet() { dismiss(nil) }
    @objc private func addWorkflow() { showEditor(nil) }
    @objc private func editWorkflow() { if let workflow = selected() { showEditor(workflow) } }
    @objc private func deleteWorkflow() {
        guard let workflow = selected() else { return }
        try? AppServices.shared.storage.deleteDeployWorkflow(id: workflow.id)
        reload()
    }
    @objc private func runWorkflow() {
        guard let workflow = selected(), let server = serversById[workflow.serverId] else { return }
        presentAsSheet(DeployViewController(server: server, workflow: workflow))
    }

    private func showEditor(_ workflow: DeployWorkflow?) {
        let servers = project.serverIds.compactMap { serversById[$0] }
        guard !servers.isEmpty else { return }
        presentAsSheet(DeployWorkflowEditorViewController(project: project, servers: servers, workflow: workflow) { [weak self] in
            self?.reload()
        })
    }

    func numberOfRows(in tableView: NSTableView) -> Int { workflows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let workflow = workflows[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = workflow.name
        case "server": value = serversById[workflow.serverId]?.name ?? "Missing server"
        case "steps": value = "\(workflow.stepCommands.count)"
        case "flags": value = "\(workflow.stopOnError ? "stop on error" : "continue")\(workflow.confirmationRequired ? ", confirm" : "")"
        default: value = ""
        }
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: value)
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                                     field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}

private final class DeployWorkflowEditorViewController: NSViewController {
    private let project: Project
    private let servers: [Server]
    private var workflow: DeployWorkflow?
    private let onSave: () -> Void
    private let nameField = NSTextField(string: "")
    private let serverPopup = NSPopUpButton()
    private let directoryField = NSTextField(string: "")
    private let stepsView = NSTextView()
    private let stopButton = NSButton(checkboxWithTitle: "Stop on error", target: nil, action: nil)
    private let confirmButton = NSButton(checkboxWithTitle: "Confirmation required", target: nil, action: nil)

    init(project: Project, servers: [Server], workflow: DeployWorkflow?, onSave: @escaping () -> Void) {
        self.project = project
        self.servers = servers
        self.workflow = workflow
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
        serverPopup.addItems(withTitles: servers.map(\.name))
        stopButton.state = .on
        confirmButton.state = .on
        if let workflow = workflow {
            nameField.stringValue = workflow.name
            if let index = servers.firstIndex(where: { $0.id == workflow.serverId }) { serverPopup.selectItem(at: index) }
            stepsView.string = workflow.stepCommands.joined(separator: "\n")
            directoryField.stringValue = workflow.workingDirectory ?? ""
            stopButton.state = workflow.stopOnError ? .on : .off
            confirmButton.state = workflow.confirmationRequired ? .on : .off
        } else {
            nameField.stringValue = project.name
            stepsView.string = "git pull\ndocker compose pull\ndocker compose up -d\ndocker compose ps"
        }
        let nameLabel = NSTextField(labelWithString: "Name")
        let serverLabel = NSTextField(labelWithString: "Server")
        let stepsLabel = NSTextField(labelWithString: "Steps — one command per line")
        let directoryLabel = NSTextField(labelWithString: "Working directory")
        [nameLabel, serverLabel, directoryLabel, stepsLabel, nameField, serverPopup, directoryField].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        stepsView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = stepsView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEdit))
        let save = NSButton(title: "Save", target: self, action: #selector(saveEdit))
        let buttons = NSStackView(views: [cancel, save])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        [nameLabel, nameField, serverLabel, serverPopup, directoryLabel, directoryField, stepsLabel, scroll, stopButton, confirmButton, buttons].forEach { root.addSubview($0) }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3), nameField.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), nameField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            serverLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10), serverLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            serverPopup.topAnchor.constraint(equalTo: serverLabel.bottomAnchor, constant: 3), serverPopup.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            directoryLabel.topAnchor.constraint(equalTo: serverPopup.bottomAnchor, constant: 10), directoryLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            directoryField.topAnchor.constraint(equalTo: directoryLabel.bottomAnchor, constant: 3), directoryField.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), directoryField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            stepsLabel.topAnchor.constraint(equalTo: directoryField.bottomAnchor, constant: 10), stepsLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: stepsLabel.bottomAnchor, constant: 3), scroll.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: nameField.trailingAnchor), scroll.heightAnchor.constraint(equalToConstant: 190),
            stopButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8), stopButton.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            confirmButton.centerYAnchor.constraint(equalTo: stopButton.centerYAnchor), confirmButton.leadingAnchor.constraint(equalTo: stopButton.trailingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: nameField.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        view = root
    }

    @objc private func cancelEdit() { dismiss(nil) }
    @objc private func saveEdit() {
        guard !servers.isEmpty else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = stepsView.string.split(separator: "\n").map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !name.isEmpty, !steps.isEmpty else { return }
        var value = workflow ?? DeployWorkflow(name: name, serverId: servers[serverPopup.indexOfSelectedItem].id,
                                                projectId: project.id, stepCommands: steps)
        value.name = name
        value.serverId = servers[max(0, serverPopup.indexOfSelectedItem)].id
        value.projectId = project.id
        value.workingDirectory = directoryField.stringValue.isEmpty ? nil : directoryField.stringValue
        value.stepCommands = steps
        value.stopOnError = stopButton.state == .on
        value.confirmationRequired = confirmButton.state == .on
        value.updatedAt = Date()
        try? AppServices.shared.storage.saveDeployWorkflow(value)
        onSave()
        dismiss(nil)
    }
}

final class DeployViewController: NSViewController {
    private let server: Server
    private let workflow: DeployWorkflow
    private let stepsLabel = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextView()
    private var steps: [String] { workflow.stepCommands }
    private var stepStates: [String] = []

    init(server: Server, workflow: DeployWorkflow) {
        self.server = server
        self.workflow = workflow
        super.init(nibName: nil, bundle: nil)
        stepStates = Array(repeating: "○", count: steps.count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let title = NSTextField(labelWithString: "Deploy — \(workflow.name)")
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
        if workflow.confirmationRequired {
            let alert = NSAlert()
            alert.messageText = "Confirm deploy to \(server.name)?"
            alert.informativeText = steps.joined(separator: "\n")
            alert.addButton(withTitle: "Deploy")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
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
                AppServices.shared.sshManager.execute(on: self.server, command: cmd,
                                                      workingDirectory: self.workflow.workingDirectory) { result in
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
                    var combined = self.output.string + "$ \(cmd)\n\(text)\n\n"
                    if combined.count > 200_000 { combined = String(combined.suffix(200_000)) }
                    self.output.string = combined
                    self.output.scrollToEndOfDocument(nil)
                }
                if !ok && self.workflow.stopOnError { break }
            }
        }
    }
}
