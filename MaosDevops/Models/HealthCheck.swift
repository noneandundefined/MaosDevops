import Cocoa
import Network

struct HealthCheck: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case http, tcp, shell }
    var id: UUID
    var name: String
    var serverId: UUID?
    var kind: Kind
    var target: String
    var intervalSeconds: Int

    init(id: UUID = UUID(), name: String, serverId: UUID? = nil, kind: Kind,
         target: String, intervalSeconds: Int = 30) {
        self.id = id
        self.name = name
        self.serverId = serverId
        self.kind = kind
        self.target = target
        self.intervalSeconds = intervalSeconds
    }
}

struct HealthCheckResult {
    let healthy: Bool
    let summary: String
    let durationMilliseconds: Int
    let checkedAt: Date
}

final class HealthCheckRunner {
    private let sshManager: SSHConnectionManager

    init(sshManager: SSHConnectionManager) {
        self.sshManager = sshManager
    }

    func run(_ check: HealthCheck, server: Server?, completion: @escaping (HealthCheckResult) -> Void) {
        let started = Date()
        let finish: (Bool, String) -> Void = { healthy, summary in
            let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1_000))
            DispatchQueue.main.async {
                completion(HealthCheckResult(healthy: healthy, summary: summary,
                                             durationMilliseconds: elapsed, checkedAt: Date()))
            }
        }

        switch check.kind {
        case .http:
            guard let url = URL(string: check.target), let scheme = url.scheme,
                  scheme == "http" || scheme == "https" else {
                finish(false, "Invalid HTTP URL")
                return
            }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 12
            let session = URLSession(configuration: config)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            session.dataTask(with: request) { _, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let error = error {
                    finish(false, error.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    finish(false, "No HTTP response")
                    return
                }
                finish((200..<400).contains(http.statusCode), "HTTP \(http.statusCode)")
            }.resume()

        case .tcp:
            guard let endpoint = Self.parseTCP(check.target),
                  let port = NWEndpoint.Port(rawValue: endpoint.port) else {
                finish(false, "Use host:port")
                return
            }
            let gate = HealthCompletionGate(finish)
            let queue = DispatchQueue(label: "com.maosdevops.health.tcp", qos: .utility)
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.complete(true, "Connected")
                    connection.cancel()
                case .failed(let error):
                    gate.complete(false, error.localizedDescription)
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) {
                gate.complete(false, "TCP timeout")
                connection.cancel()
            }

        case .shell:
            guard let server = server else {
                finish(false, "Server is required")
                return
            }
            sshManager.execute(on: server, command: check.target) { result in
                switch result {
                case .success(let value):
                    let message = value.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(value.exitCode == 0, message.isEmpty ? "Exit \(value.exitCode)" : String(message.prefix(160)))
                case .failure(let error):
                    finish(false, error.localizedDescription)
                }
            }
        }
    }

    private static func parseTCP(_ value: String) -> (host: String, port: UInt16)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.first == ":", let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = trimmed.lastIndex(of: ":"), let port = UInt16(trimmed[trimmed.index(after: colon)...]) else { return nil }
        return (String(trimmed[..<colon]), port)
    }
}

private final class HealthCompletionGate {
    private let lock = NSLock()
    private var completed = false
    private let handler: (Bool, String) -> Void

    init(_ handler: @escaping (Bool, String) -> Void) { self.handler = handler }

    func complete(_ healthy: Bool, _ summary: String) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        handler(healthy, summary)
    }
}
