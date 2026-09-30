import Foundation

enum ActionType: String, CaseIterable, Codable {
    case command
    case poll
    case stream
    case check
    case group
}

enum ActionDisplayType: String, CaseIterable, Codable {
    case output
    case status
    case none
}

struct CustomAction: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var serverId: UUID?
    var command: String
    var type: ActionType
    /// Seconds; used by poll / check
    var intervalSeconds: Int
    var workingDirectory: String?
    var environment: [String: String]
    var confirmationRequired: Bool
    var displayType: ActionDisplayType
    var stopOnError: Bool
    /// Ordered child action IDs when type == .group
    var childActionIds: [UUID]
    var isPinnedQuickAction: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        serverId: UUID? = nil,
        command: String = "",
        type: ActionType = .command,
        intervalSeconds: Int = 30,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        confirmationRequired: Bool = false,
        displayType: ActionDisplayType = .output,
        stopOnError: Bool = true,
        childActionIds: [UUID] = [],
        isPinnedQuickAction: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.serverId = serverId
        self.command = command
        self.type = type
        self.intervalSeconds = intervalSeconds
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.confirmationRequired = confirmationRequired
        self.displayType = displayType
        self.stopOnError = stopOnError
        self.childActionIds = childActionIds
        self.isPinnedQuickAction = isPinnedQuickAction
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Project: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var serverIds: [UUID]
    var actionIds: [UUID]
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        serverIds: [UUID] = [],
        actionIds: [UUID] = [],
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.serverIds = serverIds
        self.actionIds = actionIds
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct DeployWorkflow: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    var serverId: UUID
    var projectId: UUID?
    var workingDirectory: String?
    var stepCommands: [String]
    var stopOnError: Bool
    var confirmationRequired: Bool
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, serverId: UUID, projectId: UUID? = nil,
         workingDirectory: String? = nil,
         stepCommands: [String], stopOnError: Bool = true, confirmationRequired: Bool = true,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.serverId = serverId
        self.projectId = projectId
        self.workingDirectory = workingDirectory
        self.stepCommands = stepCommands
        self.stopOnError = stopOnError
        self.confirmationRequired = confirmationRequired
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
