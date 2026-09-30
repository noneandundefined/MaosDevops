import Cocoa

final class ServerEditorViewController: NSViewController {
    var onSave: (() -> Void)?

    private var existing: Server?
    private let nameField = NSTextField(string: "")
    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "22")
    private let userField = NSTextField(string: "")
    private let authPopup = NSPopUpButton()
    private let secretField = NSSecureTextField(string: "")
    private let keyPathField = NSTextField(string: "")
    private let groupPopup = NSPopUpButton()
    private let favoriteButton = NSButton(checkboxWithTitle: "Favorite", target: nil, action: nil)
    private let notesField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init(server: Server?) {
        self.existing = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 460))

        authPopup.removeAllItems()
        authPopup.addItems(withTitles: ["Password", "SSH Key"])
        groupPopup.removeAllItems()
        groupPopup.addItems(withTitles: ServerGroup.allCases.map(\.rawValue))

        if let s = existing {
            nameField.stringValue = s.name
            hostField.stringValue = s.host
            portField.stringValue = "\(s.port)"
            userField.stringValue = s.username
            authPopup.selectItem(at: s.authType == .password ? 0 : 1)
            keyPathField.stringValue = s.privateKeyPath ?? ""
            groupPopup.selectItem(withTitle: s.group.rawValue)
            favoriteButton.state = s.isFavorite ? .on : .off
            notesField.stringValue = s.notes
            secretField.placeholderString = "Leave blank to keep existing secret"
        } else {
            secretField.placeholderString = "Password or key passphrase"
        }

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false

        func labeled(_ title: String, _ field: NSView) -> NSView {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
            if let tf = field as? NSControl {
                tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
            }
            row.addArrangedSubview(label)
            row.addArrangedSubview(field)
            return row
        }

        form.addArrangedSubview(labeled("Name", nameField))
        form.addArrangedSubview(labeled("Host / IP", hostField))
        form.addArrangedSubview(labeled("SSH Port", portField))
        form.addArrangedSubview(labeled("Username", userField))
        form.addArrangedSubview(labeled("Auth Type", authPopup))
        form.addArrangedSubview(labeled("Password / Passphrase (Keychain)", secretField))
        form.addArrangedSubview(labeled("Private Key Path", keyPathField))
        form.addArrangedSubview(labeled("Group", groupPopup))
        form.addArrangedSubview(favoriteButton)
        form.addArrangedSubview(labeled("Notes", notesField))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)

        let testBtn = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.keyEquivalent = "\r"

        let buttons = NSStackView(views: [testBtn, NSView(), cancelBtn, saveBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(form)
        root.addSubview(statusLabel)
        root.addSubview(buttons)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: form.trailingAnchor),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        view = root
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portField.stringValue) ?? 22
        guard !name.isEmpty, !host.isEmpty, !user.isEmpty else {
            statusLabel.stringValue = "Name, host and username are required."
            return
        }
        guard (1...65_535).contains(port), !host.contains(where: { $0.isWhitespace }),
              !user.contains(where: { $0.isWhitespace }), !user.hasPrefix("-") else {
            statusLabel.stringValue = "Check host, username and port (1–65535)."
            return
        }

        var server = existing ?? Server(name: name, host: host, username: user)
        server.name = name
        server.host = host
        server.port = port
        server.username = user
        server.authType = authPopup.indexOfSelectedItem == 0 ? .password : .sshKey
        server.privateKeyPath = keyPathField.stringValue.isEmpty ? nil : keyPathField.stringValue
        if server.authType == .sshKey && server.privateKeyPath == nil {
            statusLabel.stringValue = "Private key path is required for SSH Key auth."
            return
        }
        server.group = ServerGroup(rawValue: groupPopup.titleOfSelectedItem ?? "") ?? .personal
        server.isFavorite = favoriteButton.state == .on
        server.notes = notesField.stringValue
        server.updatedAt = Date()

        let secret = secretField.stringValue
        if existing == nil && secret.isEmpty && server.authType == .password {
            statusLabel.stringValue = "Password is required for new password auth."
            return
        }

        do {
            if !secret.isEmpty {
                try AppServices.shared.keychain.saveSecret(account: server.secretId, secret: secret)
            } else if existing == nil {
                try AppServices.shared.keychain.saveSecret(account: server.secretId, secret: "")
            }
            try AppServices.shared.storage.saveServer(server)
            onSave?()
            dismiss(nil)
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func testConnection() {
        // Build temporary server from form
        let name = nameField.stringValue.isEmpty ? "test" : nameField.stringValue
        var server = existing ?? Server(name: name, host: hostField.stringValue, username: userField.stringValue)
        server.host = hostField.stringValue
        server.port = Int(portField.stringValue) ?? 22
        server.username = userField.stringValue
        server.authType = authPopup.indexOfSelectedItem == 0 ? .password : .sshKey
        server.privateKeyPath = keyPathField.stringValue.isEmpty ? nil : keyPathField.stringValue

        let secret = secretField.stringValue
        if !secret.isEmpty {
            try? AppServices.shared.keychain.saveSecret(account: server.secretId, secret: secret)
        }

        statusLabel.stringValue = "Connecting…"
        AppServices.shared.sshManager.testConnection(server: server) { [weak self] result in
            switch result {
            case .success(let info):
                self?.statusLabel.stringValue = "OK: \(info)"
            case .failure(let error):
                self?.statusLabel.stringValue = error.localizedDescription
            }
        }
    }
}
