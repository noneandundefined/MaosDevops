import Foundation
import Darwin

enum SSHError: Error, LocalizedError {
    case notConnected
    case authFailed(String)
    case commandFailed(Int32, String)
    case processFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH is not connected"
        case .authFailed(let m): return "Authentication failed: \(m)"
        case .commandFailed(let code, let out): return "Command exited \(code): \(out)"
        case .processFailed(let m): return m
        case .cancelled: return "Cancelled"
        }
    }
}

struct SSHCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// A cancellable remote process. Cancellation is safe before or after the
/// underlying `ssh` process has started.
final class SSHStream {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    fileprivate var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    fileprivate func attach(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    fileprivate func finish(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        process = nil
        lock.unlock()
        if running?.isRunning == true {
            running?.terminate()
        }
    }
}

/// Multiplexed SSH via system `/usr/bin/ssh` + ControlMaster.
/// Zero third-party deps, Catalina-safe, connection reuse across channels.
final class SSHSession {
    let server: Server
    private let keychain: KeychainService
    private let workQueue: DispatchQueue
    private let runtimeDirectory: String
    private let controlPath: String
    private var masterProcess: Process?
    private(set) var isConnected = false
    private var reconnectAttempt = 0

    init(server: Server, keychain: KeychainService) {
        self.server = server
        self.keychain = keychain
        self.workQueue = DispatchQueue(label: "com.maosdevops.ssh.\(server.id.uuidString)", qos: .userInitiated)

        // macOS limits Unix-domain socket paths to roughly 104 bytes and
        // OpenSSH appends a temporary suffix while creating ControlPath.
        // NSTemporaryDirectory() is already very long on Catalina, so keep
        // every SSH runtime file in a short, private and session-unique path.
        let token = UUID().uuidString.prefix(8).lowercased()
        let directory = "/tmp/md-\(ProcessInfo.processInfo.processIdentifier)-\(token)"
        self.runtimeDirectory = directory
        self.controlPath = (directory as NSString).appendingPathComponent("cm.sock")
    }

    func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.connectLocked()
                self.reconnectAttempt = 0
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func disconnect() {
        workQueue.async { [weak self] in
            self?.disconnectLocked()
        }
    }

    /// Non-blocking remote command execution. Uses ControlMaster multiplex.
    func execute(
        _ command: String,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval = 120,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                if !self.isConnected {
                    try self.connectLocked()
                }
                let result = try self.executeLocked(command, workingDirectory: workingDirectory, environment: environment, timeout: timeout)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func executeSync(_ command: String, timeout: TimeInterval = 60) throws -> SSHCommandResult {
        try workQueue.sync {
            if !isConnected {
                try connectLocked()
            }
            return try executeLocked(command, workingDirectory: nil, environment: [:], timeout: timeout)
        }
    }

    fileprivate func startStream(
        _ command: String,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        handle: SSHStream,
        onOutput: @escaping (String) -> Void,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            if handle.isCancelled {
                DispatchQueue.main.async { completion(.failure(SSHError.cancelled)) }
                return
            }

            do {
                if !self.isConnected {
                    try self.connectLocked()
                }
                let remote = self.remoteCommand(command, workingDirectory: workingDirectory, environment: environment)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = self.baseSSHArgs(includeControl: true) + [self.destination, remote]
                self.applyAuthEnvironment(to: process)

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let emit: (FileHandle) -> Void = { file in
                    let data = file.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async { onOutput(text) }
                }
                outPipe.fileHandleForReading.readabilityHandler = emit
                errPipe.fileHandleForReading.readabilityHandler = emit

                process.terminationHandler = { process in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    handle.finish(process)
                    if handle.isCancelled {
                        DispatchQueue.main.async { completion(.failure(SSHError.cancelled)) }
                    } else {
                        let result = SSHCommandResult(exitCode: process.terminationStatus, stdout: "", stderr: "")
                        DispatchQueue.main.async { completion(.success(result)) }
                    }
                }

                guard handle.attach(process) else {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.main.async { completion(.failure(SSHError.cancelled)) }
                    return
                }
                do {
                    try process.run()
                } catch {
                    handle.finish(process)
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    throw error
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Interactive SSH for terminal (own Process + PTY-like pipes).
    func makeInteractiveProcess(remoteCommand: String = "exec $SHELL -l") throws -> Process {
        try workQueue.sync {
            if !isConnected {
                try connectLocked()
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = baseSSHArgs(includeControl: true) + ["-tt", destination, remoteCommand]
        applyAuthEnvironment(to: process)
        return process
    }

    /// Creates an SFTP batch process that reuses the existing ControlMaster.
    /// The caller supplies batch commands through stdin.
    func makeSFTPProcess() throws -> Process {
        try workQueue.sync {
            if !isConnected {
                try connectLocked()
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        var args = [
            "-P", "\(server.port)",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ConnectTimeout=15"
        ]
        if server.authType == .sshKey, let path = server.privateKeyPath, !path.isEmpty {
            args += ["-i", path, "-o", "IdentitiesOnly=yes"]
        }
        args += ["-q", "-b", "-", destination]
        process.arguments = args
        applyAuthEnvironment(to: process)
        return process
    }

    // MARK: - Private

    private var destination: String {
        "\(server.username)@\(server.host)"
    }

    private func baseSSHArgs(includeControl: Bool) -> [String] {
        var args = [
            "-p", "\(server.port)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15"
        ]
        if includeControl {
            args += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=10m"
            ]
        }
        if server.authType == .sshKey, let path = server.privateKeyPath, !path.isEmpty {
            args += ["-i", path, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=no"]
        } else if server.authType == .password {
            // sshpass is not assumed; we use SSH_ASKPASS helper
            args += ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        }
        return args
    }

    private func connectLocked() throws {
        try ensureRuntimeDirectory()

        if isConnected, FileManager.default.fileExists(atPath: controlPath) {
            // Probe master
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            probe.arguments = baseSSHArgs(includeControl: true) + ["-O", "check", destination]
            applyAuthEnvironment(to: probe)
            let err = Pipe()
            probe.standardError = err
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 0 {
                isConnected = true
                return
            }
        }

        disconnectLocked()
        try ensureRuntimeDirectory()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -MNf: master, background, no remote command
        process.arguments = baseSSHArgs(includeControl: true) + ["-MNf", destination]
        applyAuthEnvironment(to: process)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SSHError.authFailed(stderr.isEmpty ? "exit \(process.terminationStatus)" : stderr)
        }
        masterProcess = process
        isConnected = true
    }

    private func disconnectLocked() {
        if FileManager.default.fileExists(atPath: controlPath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = baseSSHArgs(includeControl: true) + ["-O", "exit", destination]
            applyAuthEnvironment(to: process)
            try? process.run()
            process.waitUntilExit()
        }
        masterProcess?.terminate()
        masterProcess = nil
        isConnected = false
        try? FileManager.default.removeItem(atPath: controlPath)
        try? FileManager.default.removeItem(atPath: runtimeDirectory)
    }

    private func executeLocked(
        _ command: String,
        workingDirectory: String?,
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> SSHCommandResult {
        let remote = remoteCommand(command, workingDirectory: workingDirectory, environment: environment)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = baseSSHArgs(includeControl: true) + [destination, remote]
        applyAuthEnvironment(to: process)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Drain both pipes while the process is running. Waiting first can
        // deadlock as soon as a command fills the OS pipe buffer.
        let readGroup = DispatchGroup()
        let outputLimit = 4 * 1024 * 1024
        var stdoutData = Data()
        var stderrData = Data()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = self.readCapped(from: outPipe.fileHandleForReading, limit: outputLimit)
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = self.readCapped(from: errPipe.fileHandleForReading, limit: outputLimit)
            readGroup.leave()
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 5)
            _ = readGroup.wait(timeout: .now() + 5)
            throw SSHError.processFailed("Command timed out after \(Int(timeout))s")
        }

        readGroup.wait()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return SSHCommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func remoteCommand(
        _ command: String,
        workingDirectory: String?,
        environment: [String: String]
    ) -> String {
        var remote = command
        if let wd = workingDirectory, !wd.isEmpty {
            remote = "cd \(shellEscape(wd)) && \(command)"
        }
        if !environment.isEmpty {
            let valid = environment.filter { key, _ in
                !key.isEmpty && key.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
                }
            }
            let exports = valid.sorted { $0.key < $1.key }
                .map { "export \($0.key)=\(shellEscape($0.value))" }
                .joined(separator: "; ")
            if !exports.isEmpty {
                remote = "\(exports); \(remote)"
            }
        }
        return remote
    }

    private func readCapped(from handle: FileHandle, limit: Int) -> Data {
        var result = Data()
        while true {
            let chunk = handle.readData(ofLength: 32 * 1024)
            if chunk.isEmpty { break }
            if result.count < limit {
                result.append(contentsOf: chunk.prefix(limit - result.count))
            }
        }
        return result
    }

    private func applyAuthEnvironment(to process: Process) {
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = env["SSH_AUTH_SOCK"] ?? ""
        if server.authType == .password || (server.authType == .sshKey) {
            // The signed app executable has a tiny askpass mode in main.swift.
            // No temporary executable is created, so reconnects cannot race
            // with helper cleanup and Gatekeeper sees the already signed binary.
            if let executable = Bundle.main.executablePath {
                env["SSH_ASKPASS"] = executable
                env["MAOSDEVOPS_ASKPASS"] = "1"
                env["MAOSDEVOPS_SSH_SECRET"] = (try? keychain.readSecret(account: server.secretId)) ?? ""
                // Catalina's OpenSSH predates SSH_ASKPASS_REQUIRE. DISPLAY plus
                // the lack of a controlling terminal triggers SSH_ASKPASS.
                env["DISPLAY"] = env["DISPLAY"] ?? "maosdevops:0"
                // Prevent inheriting TTY password prompt
                env["SSH_ASKPASS_PROMPT"] = "none"
            }
        }
        process.environment = env
    }

    private func ensureRuntimeDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: runtimeDirectory
        )
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class SSHConnectionManager {
    private let keychain: KeychainService
    private var sessions: [UUID: SSHSession] = [:]
    private let lock = NSLock()
    private let commandSemaphore: DispatchSemaphore

    init(keychain: KeychainService, maxConcurrent: Int = 4) {
        self.keychain = keychain
        self.commandSemaphore = DispatchSemaphore(value: maxConcurrent)
    }

    func session(for server: Server) -> SSHSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[server.id], existing.server == server {
            return existing
        }
        sessions[server.id]?.disconnect()
        let session = SSHSession(server: server, keychain: keychain)
        sessions[server.id] = session
        return session
    }

    func execute(
        on server: Server,
        command: String,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        let session = session(for: server)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.commandSemaphore.wait()
            session.execute(command, workingDirectory: workingDirectory, environment: environment) { result in
                self?.commandSemaphore.signal()
                completion(result)
            }
        }
    }

    /// Starts a long-running remote command and delivers stdout/stderr chunks
    /// without retaining an unbounded buffer in memory.
    @discardableResult
    func stream(
        on server: Server,
        command: String,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        onOutput: @escaping (String) -> Void,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) -> SSHStream {
        let handle = SSHStream()
        let session = self.session(for: server)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.commandSemaphore.wait()
            if handle.isCancelled {
                self.commandSemaphore.signal()
                DispatchQueue.main.async { completion(.failure(SSHError.cancelled)) }
                return
            }
            session.startStream(
                command,
                workingDirectory: workingDirectory,
                environment: environment,
                handle: handle,
                onOutput: onOutput
            ) { result in
                self.commandSemaphore.signal()
                completion(result)
            }
        }
        return handle
    }

    func sftp(on server: Server, command: String,
              completion: @escaping (Result<SSHCommandResult, Error>) -> Void) {
        let session = self.session(for: server)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.commandSemaphore.wait()
            defer { self.commandSemaphore.signal() }
            do {
                let process = try session.makeSFTPProcess()
                let input = Pipe()
                let output = Pipe()
                let error = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = error
                try process.run()

                let reads = DispatchGroup()
                var stdout = Data()
                var stderr = Data()
                reads.enter()
                DispatchQueue.global(qos: .utility).async {
                    stdout = output.fileHandleForReading.readDataToEndOfFile()
                    reads.leave()
                }
                reads.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderr = error.fileHandleForReading.readDataToEndOfFile()
                    reads.leave()
                }
                input.fileHandleForWriting.write(Data((command + "\n").utf8))
                input.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                reads.wait()
                let result = SSHCommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: stdout, encoding: .utf8) ?? "",
                    stderr: String(data: stderr, encoding: .utf8) ?? ""
                )
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func testConnection(server: Server, completion: @escaping (Result<String, Error>) -> Void) {
        let session = session(for: server)
        session.connect { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                session.execute("echo ok && hostname && uname -s") { execResult in
                    switch execResult {
                    case .success(let r) where r.exitCode == 0:
                        completion(.success(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
                    case .success(let r):
                        completion(.failure(SSHError.commandFailed(r.exitCode, r.stderr)))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func disconnect(serverId: UUID) {
        lock.lock()
        let session = sessions.removeValue(forKey: serverId)
        lock.unlock()
        session?.disconnect()
    }

    func disconnectAll() {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        all.forEach { $0.disconnect() }
    }
}
