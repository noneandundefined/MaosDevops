import Cocoa

final class FilesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let server: Server
    private let pathField = NSTextField(string: "~")
    private let table = NSTableView()
    private var entries: [RemoteFileEntry] = []

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let openBtn = NSButton(title: "Open", target: self, action: #selector(openPath))
        let upBtn = NSButton(title: "Up", target: self, action: #selector(goUp))
        let mkdirBtn = NSButton(title: "New Folder", target: self, action: #selector(mkdir))
        let uploadBtn = NSButton(title: "Upload…", target: self, action: #selector(upload))
        let downloadBtn = NSButton(title: "Download…", target: self, action: #selector(download))
        let renameBtn = NSButton(title: "Rename", target: self, action: #selector(rename))
        let deleteBtn = NSButton(title: "Delete", target: self, action: #selector(deleteEntry))
        let editBtn = NSButton(title: "Edit", target: self, action: #selector(editFile))

        pathField.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSStackView(views: [openBtn, upBtn, mkdirBtn, uploadBtn, downloadBtn, renameBtn, deleteBtn, editBtn])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(doubleClick)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Name"
        col.width = 500
        table.addTableColumn(col)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(pathField)
        root.addSubview(bar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            pathField.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            pathField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            pathField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        openPath()
    }

    @objc private func openPath() {
        let path = pathField.stringValue
        // SFTP via SSH + ls (no direct docker socket; sftp binary through ssh)
        let cmd = "ls -la --time-style=long-iso \(shellEscape(path)) 2>/dev/null | tail -n +2"
        AppServices.shared.sshManager.execute(on: server, command: cmd) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let r):
                self.entries = r.stdout.split(separator: "\n").compactMap { line in
                    let s = String(line)
                    guard s.count > 10 else { return nil }
                    let isDir = s.hasPrefix("d")
                    let name = s.split(separator: " ").last.map(String.init) ?? s
                    guard name != "." && name != ".." else { return nil }
                    return RemoteFileEntry(name: name, isDirectory: isDir, listing: s)
                }
                self.table.reloadData()
            case .failure(let e):
                let alert = NSAlert()
                alert.messageText = "Files"
                alert.informativeText = e.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func goUp() {
        let path = pathField.stringValue
        if path == "~" || path == "/" { return }
        pathField.stringValue = (path as NSString).deletingLastPathComponent
        if pathField.stringValue.isEmpty { pathField.stringValue = "/" }
        openPath()
    }

    @objc private func doubleClick() {
        guard let e = selected() else { return }
        if e.isDirectory {
            let base = pathField.stringValue
            pathField.stringValue = (base as NSString).appendingPathComponent(e.name)
            openPath()
        } else {
            editFile()
        }
    }

    private func selected() -> RemoteFileEntry? {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    @objc private func mkdir() {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        let field = NSTextField(string: "new-folder")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let full = (pathField.stringValue as NSString).appendingPathComponent(field.stringValue)
        AppServices.shared.sshManager.execute(on: server, command: "mkdir -p \(shellEscape(full))") { [weak self] _ in
            self?.openPath()
        }
    }

    @objc private func deleteEntry() {
        guard let e = selected() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(e.name)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let full = (pathField.stringValue as NSString).appendingPathComponent(e.name)
        let cmd = e.isDirectory ? "rm -rf \(shellEscape(full))" : "rm -f \(shellEscape(full))"
        AppServices.shared.sshManager.execute(on: server, command: cmd) { [weak self] _ in self?.openPath() }
    }

    @objc private func rename() {
        guard let e = selected() else { return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        let field = NSTextField(string: e.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let from = (pathField.stringValue as NSString).appendingPathComponent(e.name)
        let to = (pathField.stringValue as NSString).appendingPathComponent(field.stringValue)
        AppServices.shared.sshManager.execute(on: server, command: "mv \(shellEscape(from)) \(shellEscape(to))") { [weak self] _ in
            self?.openPath()
        }
    }

    @objc private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let remote = (pathField.stringValue as NSString).appendingPathComponent(url.lastPathComponent)
        runSFTP(command: "put \(sftpQuote(url.path)) \(sftpQuote(remote))") { [weak self] success in
            if success { self?.openPath() }
        }
    }

    @objc private func download() {
        guard let e = selected(), !e.isDirectory else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = e.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let remote = (pathField.stringValue as NSString).appendingPathComponent(e.name)
        runSFTP(command: "get \(sftpQuote(remote)) \(sftpQuote(url.path))")
    }

    @objc private func editFile() {
        guard let e = selected(), !e.isDirectory else { return }
        let full = (pathField.stringValue as NSString).appendingPathComponent(e.name)
        let ext = (e.name as NSString).pathExtension.lowercased()
        let allowed = ["env", "yml", "yaml", "json", "conf", "service", "txt", ""]
        guard allowed.contains(ext) || e.name.hasPrefix(".env") else {
            let alert = NSAlert()
            alert.messageText = "Only simple text files (.env, yml, yaml, json, conf, service, txt) are editable."
            alert.runModal()
            return
        }
        AppServices.shared.sshManager.execute(on: server, command: "wc -c < \(shellEscape(full)); echo '---'; head -c 512000 \(shellEscape(full))") { [weak self] result in
            guard let self = self, case .success(let r) = result else { return }
            let parts = r.stdout.components(separatedBy: "\n---\n")
            let body = parts.count > 1 ? parts[1] : r.stdout
            self.presentAsSheet(SimpleTextEditorViewController(server: self.server, path: full, content: body))
        }
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func sftpQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func runSFTP(command: String, completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let process = try AppServices.shared.sshManager.session(for: self.server).makeSFTPProcess()
                let input = Pipe()
                let error = Pipe()
                process.standardInput = input
                process.standardError = error
                try process.run()
                input.fileHandleForWriting.write(Data((command + "\n").utf8))
                input.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    let success = process.terminationStatus == 0
                    if !success {
                        let alert = NSAlert()
                        alert.messageText = "SFTP failed"
                        alert.informativeText = message.isEmpty ? "Exit code \(process.terminationStatus)" : message
                        alert.runModal()
                    }
                    completion?(success)
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "SFTP failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                    completion?(false)
                }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "\(e.isDirectory ? "📁" : "📄") \(e.name)")
        // Avoid emoji if preferred — use plain markers for Catalina perf
        label.stringValue = "\(e.isDirectory ? "[dir]" : "     ") \(e.name)"
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

struct RemoteFileEntry {
    let name: String
    let isDirectory: Bool
    let listing: String
}

final class SimpleTextEditorViewController: NSViewController {
    private let server: Server
    private let path: String
    private let textView = NSTextView()

    init(server: Server, path: String, content: String) {
        self.server = server
        self.path = path
        super.init(nibName: nil, bundle: nil)
        textView.string = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let title = NSTextField(labelWithString: path)
        title.translatesAutoresizingMaskIntoConstraints = false
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        let bar = NSStackView(views: [save, close])
        bar.translatesAutoresizingMaskIntoConstraints = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(bar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
    }

    @objc private func closeSheet() { dismiss(nil) }

    @objc private func save() {
        // Write via SSH heredoc — keep files modest
        let b64 = Data(textView.string.utf8).base64EncodedString()
        let escapedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let cmd = "printf '%s' '\(b64)' | base64 --decode > \(escapedPath)"
        AppServices.shared.sshManager.execute(on: server, command: cmd) { [weak self] result in
            if case .failure(let e) = result {
                let alert = NSAlert()
                alert.messageText = "Save failed"
                alert.informativeText = e.localizedDescription
                alert.runModal()
            } else {
                self?.dismiss(nil)
            }
        }
    }
}
