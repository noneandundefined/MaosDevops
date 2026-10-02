import Cocoa

/// Git operations and repository discovery via the existing SSH connection.
enum GitService {
    static func discoverRepositories(
        server: Server,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let command = """
        for root in "$HOME" /home /srv /opt /var/www /var/lib; do
          [ -d "$root" ] || continue
          find "$root" -maxdepth 5 \\( -type d -o -type f \\) -name .git -print 2>/dev/null
        done | sed 's#/.git$##' | awk '!seen[$0]++' | head -100
        """
        AppServices.shared.sshManager.execute(on: server, command: command) { result in
            switch result {
            case .success(let value) where value.exitCode == 0:
                let paths = value.stdout.split(separator: "\n")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                completion(.success(paths))
            case .success(let value):
                completion(.failure(SSHError.commandFailed(value.exitCode, value.stderr)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    static func status(server: Server, path: String, completion: @escaping (Result<String, Error>) -> Void) {
        let cmd = """
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo 'The selected path is not a Git repository.' >&2; exit 64; }
        echo BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        echo COMMIT=$(git log -1 --oneline 2>/dev/null)
        echo AHEAD_BEHIND=$(git rev-list --left-right --count @{upstream}...HEAD 2>/dev/null)
        echo ---STATUS---
        git status --porcelain
        """
        AppServices.shared.sshManager.execute(on: server, command: cmd, workingDirectory: path) { result in
            switch result {
            case .success(let value) where value.exitCode == 0:
                completion(.success(value.stdout))
            case .success(let value):
                let details = value.stderr.isEmpty ? value.stdout : value.stderr
                completion(.failure(SSHError.commandFailed(value.exitCode, details)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    static func run(
        server: Server,
        path: String,
        arguments: String,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        AppServices.shared.sshManager.execute(
            on: server,
            command: "git \(arguments)",
            workingDirectory: path,
            completion: completion
        )
    }
}

final class GitViewController: NSViewController {
    private let server: Server
    private let repositoryPopup = NSPopUpButton()
    private let pathField = NSTextField(string: "")
    private let summary = NSTextField(wrappingLabelWithString: "Repositories will be detected automatically.")
    private let output = NSTextView()
    private var hasScanned = false

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let help = NSTextField(wrappingLabelWithString:
            "Maos DevOps searches common server folders for Git repositories. Select one below, or enter a path manually.")
        help.textColor = .secondaryLabelColor
        help.translatesAutoresizingMaskIntoConstraints = false

        repositoryPopup.addItem(withTitle: "Searching repositories…")
        repositoryPopup.target = self
        repositoryPopup.action = #selector(repositoryChanged)
        repositoryPopup.translatesAutoresizingMaskIntoConstraints = false

        let scan = NSButton(title: "Scan", target: self, action: #selector(scanRepositories))
        scan.translatesAutoresizingMaskIntoConstraints = false

        pathField.placeholderString = "/absolute/path/to/repository"
        pathField.target = self
        pathField.action = #selector(refreshStatus)
        pathField.translatesAutoresizingMaskIntoConstraints = false

        let status = NSButton(title: "Status", target: self, action: #selector(refreshStatus))
        let branch = NSButton(title: "Branches", target: self, action: #selector(showBranches))
        let log = NSButton(title: "History", target: self, action: #selector(showLog))
        let diff = NSButton(title: "Changes", target: self, action: #selector(showDiff))
        let fetch = NSButton(title: "Fetch", target: self, action: #selector(fetchRepo))
        let pull = NSButton(title: "Pull", target: self, action: #selector(pullRepo))
        let bar = NSStackView(views: [status, branch, log, diff, fetch, pull])
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        summary.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        summary.translatesAutoresizingMaskIntoConstraints = false

        output.isEditable = false
        output.isRichText = false
        output.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        output.frame = NSRect(x: 0, y: 0, width: 680, height: 360)
        output.autoresizingMask = [.width, .height]
        let scroll = NSScrollView()
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        [help, repositoryPopup, scan, pathField, bar, summary, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            help.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            help.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            repositoryPopup.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 8),
            repositoryPopup.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            repositoryPopup.trailingAnchor.constraint(equalTo: scan.leadingAnchor, constant: -8),
            scan.centerYAnchor.constraint(equalTo: repositoryPopup.centerYAnchor),
            scan.trailingAnchor.constraint(equalTo: help.trailingAnchor),

            pathField.topAnchor.constraint(equalTo: repositoryPopup.bottomAnchor, constant: 8),
            pathField.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: help.trailingAnchor),

            bar.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: help.leadingAnchor),

            summary.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            summary.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: help.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        L10n.apply(to: root)
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if !hasScanned { scanRepositories() }
    }

    @objc private func scanRepositories() {
        hasScanned = true
        repositoryPopup.removeAllItems()
        repositoryPopup.addItem(withTitle: L10n.text("Searching repositories…"))
        repositoryPopup.isEnabled = false
        summary.stringValue = L10n.text("Searching common folders on the server…")

        GitService.discoverRepositories(server: server) { [weak self] result in
            guard let self = self else { return }
            self.repositoryPopup.removeAllItems()
            self.repositoryPopup.isEnabled = true
            switch result {
            case .success(let paths) where !paths.isEmpty:
                self.repositoryPopup.addItems(withTitles: paths)
                self.repositoryPopup.selectItem(at: 0)
                self.pathField.stringValue = paths[0]
                self.refreshStatus()
            case .success:
                self.repositoryPopup.addItem(withTitle: L10n.text("No repositories found — enter a path below"))
                self.repositoryPopup.isEnabled = false
                self.summary.stringValue = "No Git repositories were found in home, /home, /srv, /opt, /var/www or /var/lib."
                self.output.string = L10n.text("Enter an absolute repository path in the field above, then press Status.")
            case .failure(let error):
                self.repositoryPopup.addItem(withTitle: L10n.text("Repository scan failed"))
                self.repositoryPopup.isEnabled = false
                self.summary.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func repositoryChanged() {
        guard repositoryPopup.isEnabled, let path = repositoryPopup.titleOfSelectedItem else { return }
        pathField.stringValue = path
        refreshStatus()
    }

    @objc private func refreshStatus() {
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            summary.stringValue = L10n.text("Select a repository or enter its absolute path.")
            return
        }
        summary.stringValue = "Loading…"
        GitService.status(server: server, path: path) { [weak self] result in
            switch result {
            case .success(let text):
                let sections = text.components(separatedBy: "---STATUS---\n")
                self?.summary.stringValue = sections.first ?? ""
                self?.output.string = sections.count > 1 && !sections[1].isEmpty
                    ? sections[1] : L10n.text("Working tree clean")
            case .failure(let error):
                self?.summary.stringValue = error.localizedDescription
                self?.output.string = L10n.text("Check the selected repository path and SSH permissions.")
            }
        }
    }

    @objc private func showBranches() { run("branch -vv --no-color") }
    @objc private func showLog() { run("log --oneline --decorate --graph -n 100") }
    @objc private func showDiff() { run("diff --no-color") }
    @objc private func fetchRepo() { run("fetch --all --prune") }
    @objc private func pullRepo() { run("pull --ff-only") }

    private func run(_ arguments: String) {
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            output.string = L10n.text("Select a repository first.")
            return
        }
        output.string = "Running git \(arguments)…\n"
        GitService.run(server: server, path: path, arguments: arguments) { [weak self] result in
            switch result {
            case .success(let value):
                self?.output.string = value.stdout + value.stderr + "\n[exit \(value.exitCode)]"
                if arguments == "fetch --all --prune" || arguments == "pull --ff-only" {
                    self?.refreshStatus()
                }
            case .failure(let error):
                self?.output.string = error.localizedDescription
            }
        }
    }
}
