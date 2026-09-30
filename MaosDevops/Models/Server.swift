import Foundation

enum ServerGroup: String, CaseIterable, Codable {
    case production = "Production"
    case development = "Development"
    case personal = "Personal"

    var sortOrder: Int {
        switch self {
        case .production: return 0
        case .development: return 1
        case .personal: return 2
        }
    }
}

enum AuthType: String, Codable {
    case password
    case sshKey
}

struct Server: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authType: AuthType
    /// Keychain account id — never the secret itself.
    var secretId: String
    /// Absolute path to private key when authType == .sshKey
    var privateKeyPath: String?
    var group: ServerGroup
    var isFavorite: Bool
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authType: AuthType = .password,
        secretId: String = UUID().uuidString,
        privateKeyPath: String? = nil,
        group: ServerGroup = .personal,
        isFavorite: Bool = false,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.secretId = secretId
        self.privateKeyPath = privateKeyPath
        self.group = group
        self.isFavorite = isFavorite
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum ConnectionStatus: Equatable {
    case unknown
    case online
    case offline
    case connecting
}

struct ServerSnapshot: Equatable {
    var status: ConnectionStatus = .unknown
    var hostname: String = ""
    var osName: String = ""
    var uptimeSeconds: Int = 0
    var cpuPercent: Double = 0
    var ramPercent: Double = 0
    var diskPercent: Double = 0
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var netRxBytesPerSec: Double = 0
    var netTxBytesPerSec: Double = 0
    var dockerAvailable: Bool = false
    var systemdAvailable: Bool = false
    var updatedAt: Date?
}
