import Foundation

final class ActionRunner {
    private let sshManager: SSHConnectionManager
    private let storage: StorageService
    private var pollTimers: [UUID: DispatchSourceTimer] = [:]
    private var streamTasks: [UUID: SSHStream] = [:]
    private var pollsInFlight: Set<UUID> = []
    private let queue = DispatchQueue(label: "com.maosdevops.actions", qos: .userInitiated)

    init(sshManager: SSHConnectionManager, storage: StorageService) {
        self.sshManager = sshManager
        self.storage = storage
    }

    func stopAll() {
        pollTimers.values.forEach { $0.cancel() }
        pollTimers.removeAll()
        streamTasks.values.forEach { $0.cancel() }
        streamTasks.removeAll()
    }

    func run(
        _ action: CustomAction,
        server: Server,
        onOutput: ((String) -> Void)? = nil,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        switch action.type {
        case .command:
            runOnce(action, server: server, completion: completion)
        case .poll, .check:
            startPoll(action, server: server, onOutput: onOutput, completion: completion)
        case .stream:
            startStream(action, server: server, onOutput: onOutput, completion: completion)
        case .group:
            runGroup(action, server: server, onOutput: onOutput, completion: completion)
        }
    }

    func stop(actionId: UUID) {
        pollTimers[actionId]?.cancel()
        pollTimers[actionId] = nil
        streamTasks[actionId]?.cancel()
        streamTasks[actionId] = nil
    }

    private func runOnce(
        _ action: CustomAction,
        server: Server,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        sshManager.execute(
            on: server,
            command: action.command,
            workingDirectory: action.workingDirectory,
            environment: action.environment,
            completion: completion
        )
    }

    private func startPoll(
        _ action: CustomAction,
        server: Server,
        onOutput: ((String) -> Void)?,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        stop(actionId: action.id)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(2, action.intervalSeconds)
        timer.schedule(deadline: .now(), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.pollsInFlight.contains(action.id) else { return }
            self.pollsInFlight.insert(action.id)
            self.runOnce(action, server: server) { result in
                self.queue.async {
                    self.pollsInFlight.remove(action.id)
                    DispatchQueue.main.async {
                        if case .success(let r) = result {
                            onOutput?(r.stdout)
                        }
                        completion(result)
                    }
                }
            }
        }
        pollTimers[action.id] = timer
        timer.resume()
    }

    private func startStream(
        _ action: CustomAction,
        server: Server,
        onOutput: ((String) -> Void)?,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        stop(actionId: action.id)
        let stream = sshManager.stream(
            on: server,
            command: action.command,
            workingDirectory: action.workingDirectory,
            environment: action.environment,
            onOutput: { chunk in onOutput?(chunk) },
            completion: { [weak self] result in
                self?.streamTasks[action.id] = nil
                completion(result)
            }
        )
        streamTasks[action.id] = stream
    }

    private func runGroup(
        _ action: CustomAction,
        server: Server,
        onOutput: ((String) -> Void)?,
        completion: @escaping (Result<SSHCommandResult, Error>) -> Void
    ) {
        let all = (try? storage.allActions()) ?? []
        let children = action.childActionIds.compactMap { id in all.first(where: { $0.id == id }) }
        let commands: [String]
        if children.isEmpty {
            commands = action.command.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            commands = children.map(\.command)
        }

        queue.async {
            var combinedOut = ""
            var combinedErr = ""
            var lastCode: Int32 = 0
            for cmd in commands {
                let step = CustomAction(name: cmd, serverId: server.id, command: cmd, type: .command,
                                        workingDirectory: action.workingDirectory, environment: action.environment)
                let sem = DispatchSemaphore(value: 0)
                var stepResult: Result<SSHCommandResult, Error>!
                self.runOnce(step, server: server) { result in
                    stepResult = result
                    sem.signal()
                }
                sem.wait()
                switch stepResult! {
                case .success(let r):
                    combinedOut += "$ \(cmd)\n\(r.stdout)\n"
                    combinedErr += r.stderr
                    lastCode = r.exitCode
                    DispatchQueue.main.async { onOutput?("$ \(cmd)\n\(r.stdout)") }
                    if r.exitCode != 0 && action.stopOnError {
                        DispatchQueue.main.async {
                            completion(.success(SSHCommandResult(exitCode: lastCode, stdout: combinedOut, stderr: combinedErr)))
                        }
                        return
                    }
                case .failure(let error):
                    if action.stopOnError {
                        DispatchQueue.main.async { completion(.failure(error)) }
                        return
                    }
                }
            }
            DispatchQueue.main.async {
                completion(.success(SSHCommandResult(exitCode: lastCode, stdout: combinedOut, stderr: combinedErr)))
            }
        }
    }
}
