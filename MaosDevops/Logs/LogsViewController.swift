import Cocoa

final class LogsViewController: NSViewController {
    private let server: Server
    private let sourcePopup = NSPopUpButton()
    private let targetField = NSTextField(string: "")
    private let filterPopup = NSPopUpButton()
    private let searchField = NSSearchField()
    private var streamVC: LogStreamViewController?

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        sourcePopup.addItems(withTitles: ["systemd", "Docker", "File", "Command"])
        filterPopup.addItems(withTitles: ["ALL", "ERROR", "WARN", "INFO"])
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        targetField.placeholderString = "service / container / path / command"
        sourcePopup.translatesAutoresizingMaskIntoConstraints = false
        targetField.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let start = NSButton(title: "Start", target: self, action: #selector(start))
        let live = NSButton(title: "Live", target: self, action: #selector(startLive))
        start.translatesAutoresizingMaskIntoConstraints = false
        live.translatesAutoresizingMaskIntoConstraints = false

        let child = LogStreamViewController(server: server, title: "Logs", command: "echo 'Select a source and press Start'")
        streamVC = child
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sourcePopup)
        root.addSubview(targetField)
        root.addSubview(filterPopup)
        root.addSubview(searchField)
        root.addSubview(start)
        root.addSubview(live)
        root.addSubview(child.view)

        NSLayoutConstraint.activate([
            sourcePopup.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            sourcePopup.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            targetField.centerYAnchor.constraint(equalTo: sourcePopup.centerYAnchor),
            targetField.leadingAnchor.constraint(equalTo: sourcePopup.trailingAnchor, constant: 8),
            targetField.widthAnchor.constraint(equalToConstant: 260),
            filterPopup.centerYAnchor.constraint(equalTo: sourcePopup.centerYAnchor),
            filterPopup.leadingAnchor.constraint(equalTo: targetField.trailingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: sourcePopup.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: filterPopup.trailingAnchor, constant: 8),
            searchField.widthAnchor.constraint(equalToConstant: 160),
            start.centerYAnchor.constraint(equalTo: sourcePopup.centerYAnchor),
            start.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            live.centerYAnchor.constraint(equalTo: sourcePopup.centerYAnchor),
            live.leadingAnchor.constraint(equalTo: start.trailingAnchor, constant: 6),
            child.view.topAnchor.constraint(equalTo: sourcePopup.bottomAnchor, constant: 8),
            child.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
        searchField.delegate = self
    }

    @objc private func start() { run(live: false) }
    @objc private func startLive() { run(live: true) }
    @objc private func filterChanged() {
        streamVC?.applyFilter(level: filterPopup.titleOfSelectedItem ?? "ALL", search: searchField.stringValue)
    }

    private func run(live: Bool) {
        let target = targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd: String
        switch sourcePopup.indexOfSelectedItem {
        case 0:
            let unit = target.isEmpty ? "*" : target
            cmd = live ? "journalctl -fu \(unit) -n 100 --no-pager" : "journalctl -u \(unit) -n 300 --no-pager"
        case 1:
            let name = target.isEmpty ? "$(docker ps -q | head -1)" : target
            cmd = live ? "docker logs -f --tail 100 \(name)" : "docker logs --tail 300 \(name)"
        case 2:
            let path = target.isEmpty ? "/var/log/syslog" : target
            cmd = live ? "tail -n 100 -F \(path)" : "tail -n 300 \(path)"
        default:
            cmd = target.isEmpty ? "dmesg | tail -n 100" : target
        }
        streamVC?.restart(command: cmd, streaming: live, levelFilter: filterPopup.titleOfSelectedItem ?? "ALL", search: searchField.stringValue)
    }
}

extension LogsViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        streamVC?.applyFilter(level: filterPopup.titleOfSelectedItem ?? "ALL", search: searchField.stringValue)
    }
}

/// Bounded log viewer (5k–20k lines). No infinite stdout in RAM.
final class LogStreamViewController: NSViewController {
    private let server: Server
    private var titleText: String
    private var command: String
    private var streaming: Bool
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var lines: [String] = []
    private let maxLines: Int
    private var paused = false
    private var autoScroll = true
    private var levelFilter = "ALL"
    private var searchText = ""
    private var pendingChunk = ""
    private var streamHandle: SSHStream?

    init(server: Server, title: String, command: String, streaming: Bool = false) {
        self.server = server
        self.titleText = title
        self.command = command
        self.streaming = streaming
        self.maxLines = AppServices.shared.storage.preferences.logBufferMaxLines
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let pauseBtn = NSButton(title: "Pause", target: self, action: #selector(togglePause(_:)))
        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clear))
        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyAll))
        let autoScrollBtn = NSButton(checkboxWithTitle: "Auto-scroll", target: self, action: #selector(toggleAutoScroll(_:)))
        autoScrollBtn.state = .on
        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        let bar = NSStackView(views: [pauseBtn, clearBtn, copyBtn, autoScrollBtn, closeBtn])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titleLabel)
        root.addSubview(bar)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        fetch()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        streamHandle?.cancel()
        streamHandle = nil
    }

    deinit {
        streamHandle?.cancel()
    }

    func restart(command: String, streaming: Bool, levelFilter: String, search: String) {
        streamHandle?.cancel()
        streamHandle = nil
        self.command = command
        self.streaming = streaming
        self.levelFilter = levelFilter
        self.searchText = search
        pendingChunk = ""
        clear()
        fetch()
    }

    func applyFilter(level: String, search: String) {
        levelFilter = level
        searchText = search
        render()
    }

    private func fetch() {
        if streaming {
            streamHandle = AppServices.shared.sshManager.stream(
                on: server,
                command: command,
                onOutput: { [weak self] chunk in self?.ingest(chunk) },
                completion: { [weak self] result in
                    guard let self = self else { return }
                    self.streamHandle = nil
                    if case .failure(let error) = result {
                        if let sshError = error as? SSHError, case .cancelled = sshError { return }
                        self.ingest(error.localizedDescription, flush: true)
                    } else {
                        self.ingest("", flush: true)
                    }
                }
            )
            return
        }
        AppServices.shared.sshManager.execute(on: server, command: command) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let r):
                self.ingest(r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr), flush: true)
            case .failure(let e):
                self.ingest(e.localizedDescription, flush: true)
            }
        }
    }

    private func ingest(_ text: String, flush: Bool = false) {
        pendingChunk += text
        var parts = pendingChunk.components(separatedBy: "\n")
        if flush {
            pendingChunk = ""
        } else {
            pendingChunk = parts.popLast() ?? ""
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        if flush, parts.last == "" { parts.removeLast() }
        lines.append(contentsOf: parts.map { "[\(stamp)] \($0)" })
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        if !paused { render() }
    }

    private func render() {
        let filtered = lines.filter { line in
            if levelFilter != "ALL" {
                let upper = line.uppercased()
                if !upper.contains(levelFilter) { return false }
            }
            if !searchText.isEmpty && !line.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            return true
        }
        // Avoid huge NSTextView strings: join filtered window only
        textView.string = filtered.suffix(maxLines).joined(separator: "\n")
        if autoScroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func togglePause(_ sender: NSButton) {
        paused.toggle()
        sender.title = paused ? "Resume" : "Pause"
        if !paused { render() }
    }
    @objc private func clear() { lines.removeAll(keepingCapacity: true); pendingChunk = ""; textView.string = "" }
    @objc private func toggleAutoScroll(_ sender: NSButton) {
        autoScroll = sender.state == .on
        if autoScroll { textView.scrollToEndOfDocument(nil) }
    }
    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }
    @objc private func closeSheet() { dismiss(nil) }
}
