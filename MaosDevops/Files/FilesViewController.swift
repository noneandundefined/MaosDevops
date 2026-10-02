import Cocoa

enum RemotePath {
    static func homeRelativeComponent(_ path: String) -> String? {
        if path == "~" { return "" }
        if path.hasPrefix("~/") { return String(path.dropFirst(2)) }
        return nil
    }

    static func resolving(_ path: String, home: String) -> String {
        guard let relative = homeRelativeComponent(path) else { return path }
        guard !relative.isEmpty else { return home }
        if home == "/" { return "/" + relative }
        return home.hasSuffix("/") ? home + relative : home + "/" + relative
    }
}

final class RemoteFileNode: NSObject {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let listing: String
    weak var parent: RemoteFileNode?
    var children: [RemoteFileNode] = []
    var isLoaded = false
    var isLoading = false

    init(name: String, path: String, isDirectory: Bool, size: Int64, listing: String, parent: RemoteFileNode?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.listing = listing
        self.parent = parent
    }
}

final class FilesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static let editorLimit = 10 * 1024 * 1024
    private static let binaryExtensions: Set<String> = [
        "7z", "a", "avi", "bin", "bmp", "bz2", "class", "db", "dmg", "doc", "docx",
        "dylib", "exe", "gif", "gz", "ico", "jar", "jpeg", "jpg", "mkv", "mov", "mp3",
        "mp4", "o", "pdf", "png", "ppt", "pptx", "rar", "so", "sqlite", "sqlite3",
        "tar", "tgz", "tiff", "wav", "webp", "xls", "xlsx", "xz", "zip"
    ]

    private let server: Server
    private let pathField = NSTextField(string: "/")
    private let outline = NSOutlineView()
    private let transferLabel = NSTextField(labelWithString: "")
    private let transferProgress = NSProgressIndicator()
    private var rootPath = "/"
    private var rootChildren: [RemoteFileNode] = []

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let goBtn = NSButton(title: "Go", target: self, action: #selector(openPath))
        let homeBtn = NSButton(title: "Home", target: self, action: #selector(goHome))
        let reloadBtn = NSButton(title: "Reload", target: self, action: #selector(reloadCurrent))
        let mkdirBtn = NSButton(title: "New Folder", target: self, action: #selector(mkdir))
        let uploadBtn = NSButton(title: "Upload…", target: self, action: #selector(upload))
        let downloadBtn = NSButton(title: "Download…", target: self, action: #selector(download))
        let renameBtn = NSButton(title: "Rename", target: self, action: #selector(rename))
        let deleteBtn = NSButton(title: "Delete", target: self, action: #selector(deleteEntry))
        let editBtn = NSButton(title: "Edit", target: self, action: #selector(editFile))

        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.placeholderString = "/etc/nginx"

        let bar = NSStackView(views: [
            goBtn, homeBtn, reloadBtn, mkdirBtn, uploadBtn, downloadBtn, renameBtn, deleteBtn, editBtn
        ])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        outline.rowHeight = 22
        outline.dataSource = self
        outline.delegate = self
        outline.doubleAction = #selector(doubleClick)
        outline.allowsMultipleSelection = false
        outline.indentationPerLevel = 16

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 520
        nameColumn.minWidth = 220
        outline.addTableColumn(nameColumn)
        outline.outlineTableColumn = nameColumn

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 110
        sizeColumn.minWidth = 80
        outline.addTableColumn(sizeColumn)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        transferLabel.font = NSFont.systemFont(ofSize: 11)
        transferLabel.lineBreakMode = .byTruncatingMiddle
        transferLabel.translatesAutoresizingMaskIntoConstraints = false

        transferProgress.isIndeterminate = false
        transferProgress.minValue = 0
        transferProgress.maxValue = 100
        transferProgress.doubleValue = 0
        transferProgress.translatesAutoresizingMaskIntoConstraints = false

        let transferBar = NSStackView(views: [transferLabel, transferProgress])
        transferBar.orientation = .horizontal
        transferBar.spacing = 8
        transferBar.alignment = .centerY
        transferBar.translatesAutoresizingMaskIntoConstraints = false
        transferBar.isHidden = true
        transferBar.identifier = NSUserInterfaceItemIdentifier("transferBar")

        root.addSubview(pathField)
        root.addSubview(bar)
        root.addSubview(scroll)
        root.addSubview(transferBar)

        NSLayoutConstraint.activate([
            pathField.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            pathField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            pathField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            bar.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),

            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),

            transferBar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            transferBar.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            transferBar.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            transferBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            transferProgress.widthAnchor.constraint(equalToConstant: 190)
        ])

        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if rootChildren.isEmpty {
            reloadRoot()
        }
    }

    @objc private func openPath() {
        let value = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        if RemotePath.homeRelativeComponent(value) != nil {
            openRemoteHome(path: value)
            return
        }

        rootPath = value
        reloadRoot()
    }

    @objc private func goHome() {
        openRemoteHome(path: "~")
    }

    private func openRemoteHome(path: String) {
        AppServices.shared.sshManager.execute(on: server, command: "printf '%s' \"$HOME\"") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let value) where value.exitCode == 0:
                let home = value.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard home.hasPrefix("/") else {
                    self.showError(title: "Home", message: "The server returned an invalid home directory.")
                    return
                }
                let resolvedPath = RemotePath.resolving(path, home: home)
                self.rootPath = resolvedPath
                self.pathField.stringValue = resolvedPath
                self.reloadRoot()
            case .success(let value):
                self.showError(title: "Home", message: value.stderr)
            case .failure(let error):
                self.showError(title: "Home", message: error.localizedDescription)
            }
        }
    }

    @objc private func reloadCurrent() {
        if let node = selected(), node.isDirectory {
            loadChildren(of: node, force: true, expandAfterLoad: true)
        } else if let parent = selected()?.parent {
            loadChildren(of: parent, force: true, expandAfterLoad: true)
        } else {
            reloadRoot()
        }
    }

    private func reloadRoot() {
        rootChildren.removeAll(keepingCapacity: true)
        outline.reloadData()
        setBusyTransfer("Loading \(rootPath)…")
        listDirectory(path: rootPath, parent: nil) { [weak self] result in
            guard let self = self else { return }
            self.hideTransfer()
            switch result {
            case .success(let nodes):
                self.rootChildren = nodes
                self.pathField.stringValue = self.rootPath
                self.outline.reloadData()
            case .failure(let error):
                self.showError(title: "Files", message: error.localizedDescription)
            }
        }
    }

    private func loadChildren(of node: RemoteFileNode, force: Bool = false, expandAfterLoad: Bool = false) {
        guard node.isDirectory else { return }
        if node.isLoaded && !force {
            if expandAfterLoad { outline.expandItem(node) }
            return
        }
        guard !node.isLoading else { return }

        node.isLoading = true
        listDirectory(path: node.path, parent: node) { [weak self, weak node] result in
            guard let self = self, let node = node else { return }
            node.isLoading = false
            switch result {
            case .success(let children):
                node.children = children
                node.isLoaded = true
                self.outline.reloadItem(node, reloadChildren: true)
                if expandAfterLoad {
                    self.outline.expandItem(node)
                }
            case .failure(let error):
                self.showError(title: node.path, message: error.localizedDescription)
            }
        }
    }

    private func listDirectory(
        path: String,
        parent: RemoteFileNode?,
        completion: @escaping (Result<[RemoteFileNode], Error>) -> Void
    ) {
        runSFTP(command: "ls -la \(sftpQuote(path))", showAlert: false) { result in
            switch result {
            case .success(let output):
                let nodes = output.split(separator: "\n").compactMap { line -> RemoteFileNode? in
                    let raw = String(line)
                    guard raw.count > 10,
                          raw.first == "d" || raw.first == "-" || raw.first == "l" else {
                        return nil
                    }

                    let fields = raw.split(
                        maxSplits: 8,
                        omittingEmptySubsequences: true,
                        whereSeparator: { $0 == " " || $0 == "\t" }
                    )
                    guard fields.count >= 9 else { return nil }

                    let rawName = String(fields[8])
                    let name = rawName.components(separatedBy: " -> ").first ?? rawName
                    guard name != "." && name != ".." else { return nil }

                    let isDirectory = raw.hasPrefix("d")
                    let size = Int64(fields[4]) ?? 0
                    let fullPath = FilesViewController.join(path, name)
                    return RemoteFileNode(
                        name: name,
                        path: fullPath,
                        isDirectory: isDirectory,
                        size: size,
                        listing: raw,
                        parent: parent
                    )
                }.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                completion(.success(nodes))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private static func join(_ base: String, _ name: String) -> String {
        if base == "/" { return "/" + name }
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }

    private func selected() -> RemoteFileNode? {
        let row = outline.selectedRow
        guard row >= 0 else { return nil }
        return outline.item(atRow: row) as? RemoteFileNode
    }

    private func selectedDirectory() -> (path: String, node: RemoteFileNode?) {
        if let node = selected() {
            if node.isDirectory { return (node.path, node) }
            if let parent = node.parent { return (parent.path, parent) }
        }
        return (rootPath, nil)
    }

    @objc private func doubleClick() {
        guard let node = selected() else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                loadChildren(of: node, expandAfterLoad: true)
            }
        } else {
            editFile()
        }
    }

    @objc private func mkdir() {
        let directory = selectedDirectory()
        let alert = NSAlert()
        alert.messageText = "New Folder"
        let field = NSTextField(string: "new-folder")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            showError(title: "New Folder", message: "Folder name cannot be empty or contain '/'.")
            return
        }

        let full = Self.join(directory.path, name)
        runSFTP(command: "mkdir \(sftpQuote(full))") { [weak self] result in
            if case .success = result {
                self?.refresh(directory.node)
            }
        }
    }

    @objc private func deleteEntry() {
        guard let node = selected() else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(node.name)?"
        alert.informativeText = node.isDirectory
            ? "Only an empty directory can be deleted."
            : "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let command = node.isDirectory ? "rmdir \(sftpQuote(node.path))" : "rm \(sftpQuote(node.path))"
        runSFTP(command: command) { [weak self] result in
            if case .success = result {
                self?.refresh(node.parent)
            }
        }
    }

    @objc private func rename() {
        guard let node = selected() else { return }

        let alert = NSAlert()
        alert.messageText = "Rename"
        let field = NSTextField(string: node.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, !newName.contains("/") else {
            showError(title: "Rename", message: "File name cannot be empty or contain '/'.")
            return
        }

        let parentPath = node.parent?.path ?? rootPath
        let destination = Self.join(parentPath, newName)
        runSFTP(command: "rename \(sftpQuote(node.path)) \(sftpQuote(destination))") { [weak self] result in
            if case .success = result {
                self?.refresh(node.parent)
            }
        }
    }

    @objc private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let directory = selectedDirectory()
        let remote = Self.join(directory.path, url.lastPathComponent)
        showTransfer(title: "Uploading \(url.lastPathComponent)", progress: SSHFileTransferProgress(completedBytes: 0, totalBytes: 0))

        AppServices.shared.sshManager.uploadFile(
            on: server,
            localURL: url,
            remotePath: remote,
            progress: { [weak self] snapshot in
                self?.showTransfer(title: "Uploading \(url.lastPathComponent)", progress: snapshot)
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    self.finishTransfer("Uploaded \(url.lastPathComponent)")
                    self.refresh(directory.node)
                case .failure(let error):
                    self.hideTransfer()
                    self.showError(title: "Upload failed", message: error.localizedDescription)
                }
            }
        )
    }

    @objc private func download() {
        guard let node = selected(), !node.isDirectory else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = node.name
        guard panel.runModal() == .OK, let url = panel.url else { return }

        showTransfer(title: "Downloading \(node.name)", progress: SSHFileTransferProgress(completedBytes: 0, totalBytes: node.size))

        AppServices.shared.sshManager.downloadFile(
            on: server,
            remotePath: node.path,
            localURL: url,
            progress: { [weak self] snapshot in
                self?.showTransfer(title: "Downloading \(node.name)", progress: snapshot)
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    self.finishTransfer("Downloaded \(node.name)")
                case .failure(let error):
                    self.hideTransfer()
                    self.showError(title: "Download failed", message: error.localizedDescription)
                }
            }
        )
    }

    @objc private func editFile() {
        guard let node = selected(), !node.isDirectory else { return }

        let ext = (node.name as NSString).pathExtension.lowercased()
        if Self.binaryExtensions.contains(ext) {
            showError(title: "Editor", message: "This looks like a binary file. Download it instead.")
            return
        }

        if node.size > Int64(Self.editorLimit) {
            showError(
                title: "Editor",
                message: "The built-in editor is limited to 10 MB to keep Maos DevOps responsive on older Macs."
            )
            return
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maosdevops-edit-\(UUID().uuidString)")

        showTransfer(title: "Opening \(node.name)", progress: SSHFileTransferProgress(completedBytes: 0, totalBytes: node.size))
        AppServices.shared.sshManager.downloadFile(
            on: server,
            remotePath: node.path,
            localURL: tempURL,
            progress: { [weak self] snapshot in
                self?.showTransfer(title: "Opening \(node.name)", progress: snapshot)
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                defer { try? FileManager.default.removeItem(at: tempURL) }

                switch result {
                case .failure(let error):
                    self.hideTransfer()
                    self.showError(title: "Open failed", message: error.localizedDescription)

                case .success:
                    self.hideTransfer()
                    guard let data = try? Data(contentsOf: tempURL),
                          data.count <= Self.editorLimit else {
                        self.showError(title: "Editor", message: "File is larger than 10 MB.")
                        return
                    }

                    guard let body = String(data: data, encoding: .utf8) else {
                        self.showError(
                            title: "Editor",
                            message: "The built-in editor opens UTF-8 text files. This file appears to use another encoding or contains binary data."
                        )
                        return
                    }

                    let editor = SimpleTextEditorViewController(
                        server: self.server,
                        path: node.path,
                        content: body,
                        maximumBytes: Self.editorLimit
                    )
                    self.presentAsSheet(editor)
                }
            }
        )
    }

    private func refresh(_ node: RemoteFileNode?) {
        if let node = node {
            loadChildren(of: node, force: true, expandAfterLoad: outline.isItemExpanded(node))
        } else {
            reloadRoot()
        }
    }

    private func sftpQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func runSFTP(
        command: String,
        showAlert: Bool = true,
        completion: ((Result<String, Error>) -> Void)? = nil
    ) {
        AppServices.shared.sshManager.sftp(on: server, command: command) { [weak self] result in
            switch result {
            case .success(let value) where value.exitCode == 0:
                completion?(.success(value.stdout))
            case .success(let value):
                let error = SSHError.commandFailed(value.exitCode, value.stderr)
                if showAlert {
                    self?.showError(title: "SFTP failed", message: error.localizedDescription)
                }
                completion?(.failure(error))
            case .failure(let error):
                if showAlert {
                    self?.showError(title: "SFTP failed", message: error.localizedDescription)
                }
                completion?(.failure(error))
            }
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private var transferBar: NSView? {
        view.subviews.first { $0.identifier == NSUserInterfaceItemIdentifier("transferBar") }
    }

    private func setBusyTransfer(_ title: String) {
        transferBar?.isHidden = false
        transferLabel.stringValue = title
        transferProgress.isIndeterminate = true
        transferProgress.startAnimation(nil)
    }

    private func showTransfer(title: String, progress: SSHFileTransferProgress) {
        transferBar?.isHidden = false
        transferProgress.stopAnimation(nil)
        transferProgress.isIndeterminate = false
        transferProgress.doubleValue = progress.totalBytes > 0 ? progress.fractionCompleted * 100 : 0

        let percent = progress.totalBytes > 0 ? Int(progress.fractionCompleted * 100) : 0
        if progress.totalBytes > 0 {
            transferLabel.stringValue = "\(title) — \(percent)%  \(Self.byteString(progress.completedBytes)) / \(Self.byteString(progress.totalBytes))"
        } else {
            transferLabel.stringValue = title
        }
    }

    private func finishTransfer(_ title: String) {
        transferProgress.stopAnimation(nil)
        transferProgress.isIndeterminate = false
        transferProgress.doubleValue = 100
        transferLabel.stringValue = title
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.hideTransfer()
        }
    }

    private func hideTransfer() {
        transferProgress.stopAnimation(nil)
        transferProgress.isIndeterminate = false
        transferProgress.doubleValue = 0
        transferBar?.isHidden = true
    }

    private static func byteString(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? RemoteFileNode {
            return node.children.count
        }
        return rootChildren.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? RemoteFileNode {
            return node.children[index]
        }
        return rootChildren[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? RemoteFileNode)?.isDirectory == true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? RemoteFileNode, node.isDirectory else { return false }
        if node.isLoaded { return true }
        loadChildren(of: node, expandAfterLoad: true)
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? RemoteFileNode, let tableColumn = tableColumn else { return nil }

        if tableColumn.identifier.rawValue == "size" {
            let identifier = NSUserInterfaceItemIdentifier("sizeCell")
            let cell = reusableCell(in: outlineView, identifier: identifier, alignment: .right)
            cell.textField?.stringValue = node.isDirectory ? "" : Self.byteString(node.size)
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("nameCell")
        let cell = reusableCell(in: outlineView, identifier: identifier, alignment: .left)
        cell.textField?.stringValue = node.name
        cell.textField?.toolTip = node.path
        return cell
    }

    private func reusableCell(
        in outlineView: NSOutlineView,
        identifier: NSUserInterfaceItemIdentifier,
        alignment: NSTextAlignment
    ) -> NSTableCellView {
        if let existing = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = alignment
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

final class SimpleTextEditorViewController: NSViewController {
    private let server: Server
    private let path: String
    private let maximumBytes: Int
    private let initialContent: String
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var isSaving = false

    init(server: Server, path: String, content: String, maximumBytes: Int) {
        self.server = server
        self.path = path
        self.maximumBytes = maximumBytes
        self.initialContent = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))

        let title = NSTextField(labelWithString: path)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]

        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        let bar = NSStackView(views: [save, close])
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.frame = NSRect(x: 0, y: 0, width: 720, height: 500)
        textView.autoresizingMask = [.width, .height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = initialContent

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = 0
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(bar)
        root.addSubview(scroll)
        root.addSubview(statusLabel)
        root.addSubview(progress)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: bar.leadingAnchor, constant: -12),

            bar.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            progress.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            progress.widthAnchor.constraint(equalToConstant: 190),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -8)
        ])

        L10n.apply(to: root)
        view = root
    }

    @objc private func closeSheet() {
        guard !isSaving else { return }
        dismiss(nil)
    }

    @objc private func save() {
        guard !isSaving else { return }

        let data = Data(textView.string.utf8)
        guard data.count <= maximumBytes else {
            let alert = NSAlert()
            alert.messageText = "File is too large"
            alert.informativeText = "The editor is limited to 10 MB to keep the application responsive on older Macs."
            alert.runModal()
            return
        }

        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maosdevops-save-\(UUID().uuidString)")
        do {
            try data.write(to: localURL, options: .atomic)
        } catch {
            showSaveError(error.localizedDescription)
            return
        }

        isSaving = true
        progress.isHidden = false
        progress.doubleValue = 0
        statusLabel.stringValue = "Saving…"

        AppServices.shared.sshManager.uploadFile(
            on: server,
            localURL: localURL,
            remotePath: path,
            atomic: true,
            progress: { [weak self] snapshot in
                guard let self = self else { return }
                self.progress.doubleValue = snapshot.fractionCompleted * 100
                let percent = snapshot.totalBytes > 0 ? Int(snapshot.fractionCompleted * 100) : 0
                self.statusLabel.stringValue = "Saving… \(percent)%"
            },
            completion: { [weak self] result in
                try? FileManager.default.removeItem(at: localURL)
                guard let self = self else { return }
                self.isSaving = false

                switch result {
                case .success:
                    self.progress.doubleValue = 100
                    self.statusLabel.stringValue = "Saved to server"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.progress.isHidden = true
                    }
                case .failure(let error):
                    self.progress.isHidden = true
                    self.statusLabel.stringValue = "Save failed"
                    self.showSaveError(error.localizedDescription)
                }
            }
        )
    }

    private func showSaveError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Save failed"
        alert.informativeText = message
        alert.runModal()
    }
}
