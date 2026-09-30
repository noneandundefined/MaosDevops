import Foundation

/// Central composition root. Keeps services alive for app lifetime.
final class AppServices {
    static let shared = AppServices()

    let storage: StorageService
    let keychain: KeychainService
    let sshManager: SSHConnectionManager
    let actions: ActionRunner
    let monitoring: MonitoringService
    let healthChecks: HealthCheckRunner

    private init() {
        storage = StorageService()
        keychain = KeychainService(service: "com.maosdevops.secrets")
        sshManager = SSHConnectionManager(keychain: keychain)
        actions = ActionRunner(sshManager: sshManager, storage: storage)
        monitoring = MonitoringService(sshManager: sshManager, storage: storage)
        healthChecks = HealthCheckRunner(sshManager: sshManager)
    }

    func bootstrap() {
        do {
            try storage.open()
            try storage.migrateIfNeeded()
        } catch {
            NSLog("[MaosDevOps] Storage bootstrap failed: \(error)")
        }
    }

    func shutdown() {
        monitoring.stopAll()
        actions.stopAll()
        sshManager.disconnectAll()
        storage.close()
    }
}
