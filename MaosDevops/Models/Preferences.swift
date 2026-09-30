import Foundation

struct AppPreferences: Codable, Equatable {
    var cpuRamPollSeconds: Int = 5
    var diskPollSeconds: Int = 30
    var dockerPollSeconds: Int = 8
    var logBufferMaxLines: Int = 10_000
    var monitoringHistoryHours: Int = 24
    var maxConcurrentSSHCommands: Int = 4
    var selectedSidebarItem: String = "servers"
}
