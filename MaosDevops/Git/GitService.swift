import Cocoa

/// Minimal git status via SSH CLI (no libgit2).
enum GitService {
    static func status(server: Server, path: String, completion: @escaping (Result<String, Error>) -> Void) {
        let cmd = """
        echo BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        echo COMMIT=$(git log -1 --oneline 2>/dev/null)
        echo AHEAD_BEHIND=$(git rev-list --left-right --count @{upstream}...HEAD 2>/dev/null)
        echo ---STATUS---
        git status --porcelain 2>/dev/null
        """
        AppServices.shared.sshManager.execute(on: server, command: cmd, workingDirectory: path, completion: { result in
            switch result {
            case .success(let r) where r.exitCode == 0:
                completion(.success(r.stdout))
            case .success(let r):
                completion(.failure(SSHError.commandFailed(r.exitCode, r.stderr)))
            case .failure(let e):
                completion(.failure(e))
            }
        })
    }

    static func run(server: Server, path: String, arguments: String,
                    completion: @escaping (Result<SSHCommandResult, Error>) -> Void) {
        AppServices.shared.sshManager.execute(on: server, command: "git \(arguments)",
                                              workingDirectory: path, completion: completion)
    }
}

final class GitViewController: NSViewController {
    private let server: Server
    private let pathField = NSTextField(string: "~")
    private let summary = NSTextField(wrappingLabelWithString: "Choose a repository path and press Status.")
    private let output = NSTextView()

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        pathField.placeholderString = "Remote repository path"
        pathField.translatesAutoresizingMaskIntoConstraints = false
        let status = NSButton(title: "Status", target: self, action: #selector(refreshStatus))
        let branch = NSButton(title: "Branches", target: self, action: #selector(showBranches))
        let log = NSButton(title: "Log", target: self, action: #selector(showLog))
        let diff = NSButton(title: "Diff", target: self, action: #selector(showDiff))
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
        let scroll = NSScrollView()
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(pathField)
        root.addSubview(bar)
        root.addSubview(summary)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            pathField.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            pathField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            pathField.widthAnchor.constraint(equalToConstant: 320),
            bar.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: pathField.trailingAnchor, constant: 10),
            summary.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 12),
            summary.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
    }

    @objc private func refreshStatus() {
        summary.stringValue = "Loading…"
        GitService.status(server: server, path: pathField.stringValue) { [weak self] result in
            switch result {
            case .success(let text):
                let sections = text.components(separatedBy: "---STATUS---\n")
                self?.summary.stringValue = sections.first ?? ""
                self?.output.string = sections.count > 1 && !sections[1].isEmpty ? sections[1] : "Working tree clean"
            case .failure(let error):
                self?.summary.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func showBranches() { run("branch -vv --no-color") }
    @objc private func showLog() { run("log --oneline --decorate --graph -n 100") }
    @objc private func showDiff() { run("diff --no-color") }
    @objc private func fetchRepo() { run("fetch --all --prune") }
    @objc private func pullRepo() { run("pull --ff-only") }

    private func run(_ arguments: String) {
        output.string = "Running git \(arguments)…\n"
        GitService.run(server: server, path: pathField.stringValue, arguments: arguments) { [weak self] result in
            switch result {
            case .success(let value):
                self?.output.string = value.stdout + value.stderr + "\n[exit \(value.exitCode)]"
                if arguments == "fetch --all --prune" || arguments == "pull --ff-only" { self?.refreshStatus() }
            case .failure(let error):
                self?.output.string = error.localizedDescription
            }
        }
    }
}
