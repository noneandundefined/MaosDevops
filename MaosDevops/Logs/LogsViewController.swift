import Cocoa

final class LogsViewController: NSViewController {
    private let server: Server
    private let sourcePopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let targetField = NSTextField(string: "")
    private let filterPopup = NSPopUpButton()
    private let searchField = NSSearchField()
    private var streamVC: LogStreamViewController?
    private var discoveredSources: [Int: [String]] = [:]
    private var hasScanned = false

    init(server: Server) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        sourcePopup.addItems(withTitles: ["systemd", "Docker", "File", "Command"])
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        targetPopup.addItem(withTitle: L10n.text("Searching log sources…"))
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        filterPopup.addItems(withTitles: ["ALL", "ERROR", "WARN", "INFO"])
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        targetField.placeholderString = "Selected source or a custom value"
        sourcePopup.translatesAutoresizingMaskIntoConstraints = false
        targetPopup.translatesAutoresizingMaskIntoConstraints = false
        targetField.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let help = NSTextField(wrappingLabelWithString:
            "Log sources are detected automatically. Choose a type and an item, or enter a custom service, container, file path or command.")
        help.textColor = .secondaryLabelColor
        help.translatesAutoresizingMaskIntoConstraints = false
        let scan = NSButton(title: "Scan", target: self, action: #selector(scanSources))
        let start = NSButton(title: "Start", target: self, action: #selector(start))
        let live = NSButton(title: "Live", target: self, action: #selector(startLive))
        scan.translatesAutoresizingMaskIntoConstraints = false
        start.translatesAutoresizingMaskIntoConstraints = false
        live.translatesAutoresizingMaskIntoConstraints = false
        let controls = NSStackView(views: [filterPopup, searchField, start, live])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false

        let child = LogStreamViewController(server: server, title: "Logs", command: "echo 'Select a source and press Start'")
        streamVC = child
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false

        [help, sourcePopup, targetPopup, scan, targetField, controls, child.view].forEach(root.addSubview)

        NSLayoutConstraint.activate([
            help.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            help.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            help.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            sourcePopup.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 7),
            sourcePopup.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            targetPopup.centerYAnchor.constraint(equalTo: sourcePopup.centerYAnchor),
            targetPopup.leadingAnchor.constraint(equalTo: sourcePopup.trailingAnchor, constant: 8),
            targetPopup.trailingAnchor.constraint(equalTo: scan.leadingAnchor, constant: -8),
            scan.centerYAnchor.constraint(equalTo: sourcePopup.centerYAnchor),
            scan.trailingAnchor.constraint(equalTo: help.trailingAnchor),

            targetField.topAnchor.constraint(equalTo: sourcePopup.bottomAnchor, constant: 7),
            targetField.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            targetField.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            controls.topAnchor.constraint(equalTo: targetField.bottomAnchor, constant: 6),
            controls.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: help.trailingAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            child.view.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            child.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        L10n.apply(to: root)
        view = root
        searchField.delegate = self
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if !hasScanned { scanSources() }
    }

    @objc private func scanSources() {
        hasScanned = true
        targetPopup.removeAllItems()
        targetPopup.addItem(withTitle: L10n.text("Searching log sources…"))
        targetPopup.isEnabled = false

        let command = """
        printf '__SYSTEMD__\n'
        if command -v systemctl >/dev/null 2>&1; then
          systemctl list-units --type=service --all --no-legend --plain 2>/dev/null | awk '{print $1}' | head -200
        fi
        printf '__DOCKER__\n'
        if command -v docker >/dev/null 2>&1; then
          docker ps -a --format '{{.Names}}' 2>/dev/null | head -200
        fi
        printf '__FILES__\n'
        # Project logs are often nested deeper than /root/<project>/.../logs/<date>/file.
        # Scan common roots with a bounded depth and also include extensionless files
        # that live inside a directory named "logs".
        for root in "$HOME/neosync" /var/log "$HOME"; do
          [ -d "$root" ] || continue
          find "$root" -maxdepth 8 -type f -readable \\( \
            -name '*.log' -o -name '*.log.*' -o -name syslog -o -name messages -o -path '*/logs/*' \
          \\) -print 2>/dev/null
        done | awk '!seen[$0]++' | head -400
        """
        AppServices.shared.sshManager.execute(on: server, command: command) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let value):
                self.discoveredSources = Self.parseSources(value.stdout)
            case .failure:
                self.discoveredSources = [:]
            }
            self.sourceChanged()
        }
    }

    static func parseSources(_ output: String) -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        var section: Int?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            switch line {
            case "__SYSTEMD__": section = 0
            case "__DOCKER__": section = 1
            case "__FILES__": section = 2
            default:
                if let section = section, !line.isEmpty, !(result[section] ?? []).contains(line) {
                    result[section, default: []].append(line)
                }
            }
        }
        return result
    }

    @objc private func sourceChanged() {
        let index = sourcePopup.indexOfSelectedItem
        let values = discoveredSources[index] ?? []
        targetPopup.removeAllItems()
        if index == 3 {
            targetPopup.addItem(withTitle: L10n.text("Enter a command below"))
            targetPopup.isEnabled = false
            targetField.stringValue = ""
        } else if values.isEmpty {
            targetPopup.addItem(withTitle: L10n.text("No sources found — enter one below"))
            targetPopup.isEnabled = false
            targetField.stringValue = ""
        } else {
            targetPopup.addItems(withTitles: values)
            targetPopup.isEnabled = true
            targetPopup.selectItem(at: 0)
            targetField.stringValue = values[0]
        }
    }

    @objc private func targetChanged() {
        guard targetPopup.isEnabled, let value = targetPopup.titleOfSelectedItem else { return }
        targetField.stringValue = value
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
            if target.isEmpty {
                cmd = live ? "journalctl -f -n 100 --no-pager" : "journalctl -n 300 --no-pager"
            } else {
                let unit = shellQuote(target)
                cmd = live ? "journalctl -fu \(unit) -n 100 --no-pager" : "journalctl -u \(unit) -n 300 --no-pager"
            }
        case 1:
            guard !target.isEmpty else {
                streamVC?.restart(command: "printf '%s\\n' 'Select a Docker container first.'", streaming: false,
                                  levelFilter: "ALL", search: "")
                return
            }
            let name = shellQuote(target)
            cmd = live ? "docker logs -f --tail 100 \(name)" : "docker logs --tail 300 \(name)"
        case 2:
            guard !target.isEmpty else {
                streamVC?.restart(command: "printf '%s\\n' 'Select a log file first.'", streaming: false,
                                  levelFilter: "ALL", search: "")
                return
            }
            let path = shellQuote(target)
            // Never read a large log from the beginning. Live starts with a small
            // tail window and then receives only newly appended data.
            cmd = live ? "tail -n 100 -F -- \(path)" : "tail -n 300 -- \(path)"
        default:
            cmd = target.isEmpty ? "dmesg | tail -n 100" : target
        }
        streamVC?.restart(command: cmd, streaming: live, levelFilter: filterPopup.titleOfSelectedItem ?? "ALL", search: searchField.stringValue)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    private var bufferedCharacters = 0
    private let maxBufferedCharacters = 2_000_000
    private let maxLineCharacters = 64_000
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
        textView.frame = NSRect(x: 0, y: 0, width: 680, height: 360)
        textView.autoresizingMask = [.width, .height]
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
        L10n.apply(to: root)
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
        // A malformed log can contain a gigantic line without a newline. Keep the
        // unfinished chunk bounded as well so a multi-GB file cannot grow RAM usage.
        if pendingChunk.count > maxBufferedCharacters {
            pendingChunk = String(pendingChunk.suffix(maxBufferedCharacters))
        }

        var parts = pendingChunk.components(separatedBy: "\n")
        if flush {
            pendingChunk = ""
        } else {
            pendingChunk = parts.popLast() ?? ""
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        if flush, parts.last == "" { parts.removeLast() }
        for part in parts {
            let clipped = part.count > maxLineCharacters ? String(part.suffix(maxLineCharacters)) : part
            let line = "[\(stamp)] \(clipped)"
            lines.append(line)
            bufferedCharacters += line.count
        }

        while lines.count > maxLines || bufferedCharacters > maxBufferedCharacters {
            guard !lines.isEmpty else { break }
            bufferedCharacters -= lines.removeFirst().count
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
    @objc private func clear() {
        lines.removeAll(keepingCapacity: true)
        pendingChunk = ""
        bufferedCharacters = 0
        textView.string = ""
    }
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
