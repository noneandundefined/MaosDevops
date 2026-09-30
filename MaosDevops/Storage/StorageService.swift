import Foundation
import SQLite3

enum StorageError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case notOpen

    var errorDescription: String? {
        switch self {
        case .openFailed(let m), .prepareFailed(let m), .stepFailed(let m):
            return m
        case .notOpen:
            return "Database is not open"
        }
    }
}

/// Lightweight SQLite wrapper (no ORM). Secrets are never stored here.
final class StorageService {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.maosdevops.storage", qos: .utility)
    private(set) var preferences = AppPreferences()

    private var dbURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MaosDevOps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("maosdevops.sqlite")
    }

    func open() throws {
        try queue.sync {
            if db != nil { return }
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            if sqlite3_open_v2(dbURL.path, &handle, flags, nil) != SQLITE_OK {
                let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw StorageError.openFailed(msg)
            }
            db = handle
            try execLocked("PRAGMA journal_mode=WAL;")
            try execLocked("PRAGMA foreign_keys=ON;")
        }
    }

    func close() {
        queue.sync {
            if let db = db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    func migrateIfNeeded() throws {
        try queue.sync {
            try execLocked("""
            CREATE TABLE IF NOT EXISTS servers (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL,
                username TEXT NOT NULL,
                auth_type TEXT NOT NULL,
                secret_id TEXT NOT NULL,
                private_key_path TEXT,
                group_name TEXT NOT NULL,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                notes TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
            try execLocked("""
            CREATE TABLE IF NOT EXISTS actions (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                server_id TEXT,
                command TEXT NOT NULL,
                type TEXT NOT NULL,
                interval_seconds INTEGER NOT NULL,
                working_directory TEXT,
                environment_json TEXT NOT NULL,
                confirmation_required INTEGER NOT NULL,
                display_type TEXT NOT NULL,
                stop_on_error INTEGER NOT NULL,
                child_action_ids_json TEXT NOT NULL,
                is_pinned_quick_action INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
            try execLocked("""
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                server_ids_json TEXT NOT NULL,
                action_ids_json TEXT NOT NULL,
                notes TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
            try execLocked("""
            CREATE TABLE IF NOT EXISTS preferences (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
            try execLocked("""
            CREATE TABLE IF NOT EXISTS monitoring_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                server_id TEXT NOT NULL,
                ts REAL NOT NULL,
                cpu REAL,
                ram REAL,
                disk REAL,
                load1 REAL,
                net_rx REAL,
                net_tx REAL
            );
            """)
            try execLocked("""
            CREATE TABLE IF NOT EXISTS health_checks (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                server_id TEXT,
                kind TEXT NOT NULL,
                target TEXT NOT NULL,
                interval_seconds INTEGER NOT NULL
            );
            """)
            try execLocked("""
            CREATE TABLE IF NOT EXISTS deploy_workflows (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                server_id TEXT NOT NULL,
                project_id TEXT,
                working_directory TEXT,
                step_commands_json TEXT NOT NULL,
                stop_on_error INTEGER NOT NULL,
                confirmation_required INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """)
            try? execLocked("ALTER TABLE deploy_workflows ADD COLUMN working_directory TEXT;")
            try execLocked("CREATE INDEX IF NOT EXISTS idx_mon_server_ts ON monitoring_samples(server_id, ts);")
            loadPreferencesLocked()
        }
    }

    // MARK: - Servers

    func allServers() throws -> [Server] {
        try queue.sync {
            let sql = "SELECT id,name,host,port,username,auth_type,secret_id,private_key_path,group_name,is_favorite,notes,created_at,updated_at FROM servers ORDER BY group_name, name;"
            let stmt = try prepareLocked(sql)
            defer { sqlite3_finalize(stmt) }
            var result: [Server] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(serverFromRow(stmt))
            }
            return result
        }
    }

    func saveServer(_ server: Server) throws {
        try queue.sync {
            let sql = """
            INSERT INTO servers (id,name,host,port,username,auth_type,secret_id,private_key_path,group_name,is_favorite,notes,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name, host=excluded.host, port=excluded.port, username=excluded.username,
              auth_type=excluded.auth_type, secret_id=excluded.secret_id, private_key_path=excluded.private_key_path,
              group_name=excluded.group_name, is_favorite=excluded.is_favorite, notes=excluded.notes, updated_at=excluded.updated_at;
            """
            let stmt = try prepareLocked(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, server.id.uuidString)
            bindText(stmt, 2, server.name)
            bindText(stmt, 3, server.host)
            sqlite3_bind_int(stmt, 4, Int32(server.port))
            bindText(stmt, 5, server.username)
            bindText(stmt, 6, server.authType.rawValue)
            bindText(stmt, 7, server.secretId)
            if let path = server.privateKeyPath {
                bindText(stmt, 8, path)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            bindText(stmt, 9, server.group.rawValue)
            sqlite3_bind_int(stmt, 10, server.isFavorite ? 1 : 0)
            bindText(stmt, 11, server.notes)
            sqlite3_bind_double(stmt, 12, server.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 13, server.updatedAt.timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    func deleteServer(id: UUID) throws {
        try queue.sync {
            let stmt = try prepareLocked("DELETE FROM servers WHERE id=?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            try stepDone(stmt)
            let mon = try prepareLocked("DELETE FROM monitoring_samples WHERE server_id=?;")
            defer { sqlite3_finalize(mon) }
            bindText(mon, 1, id.uuidString)
            try stepDone(mon)
            for sql in ["DELETE FROM health_checks WHERE server_id=?;",
                        "DELETE FROM deploy_workflows WHERE server_id=?;",
                        "DELETE FROM actions WHERE server_id=?;"] {
                let related = try prepareLocked(sql)
                defer { sqlite3_finalize(related) }
                bindText(related, 1, id.uuidString)
                try stepDone(related)
            }
        }
    }

    // MARK: - Actions

    func allActions() throws -> [CustomAction] {
        try queue.sync {
            let sql = """
            SELECT id,name,server_id,command,type,interval_seconds,working_directory,environment_json,
                   confirmation_required,display_type,stop_on_error,child_action_ids_json,is_pinned_quick_action,created_at,updated_at
            FROM actions ORDER BY name;
            """
            let stmt = try prepareLocked(sql)
            defer { sqlite3_finalize(stmt) }
            var result: [CustomAction] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(actionFromRow(stmt))
            }
            return result
        }
    }

    func saveAction(_ action: CustomAction) throws {
        try queue.sync {
            let envData = (try? JSONEncoder().encode(action.environment)) ?? Data("{}".utf8)
            let envJSON = String(data: envData, encoding: .utf8) ?? "{}"
            let childJSON = (try? String(data: JSONEncoder().encode(action.childActionIds.map(\.uuidString)), encoding: .utf8)) ?? "[]"
            let sql = """
            INSERT INTO actions (id,name,server_id,command,type,interval_seconds,working_directory,environment_json,
              confirmation_required,display_type,stop_on_error,child_action_ids_json,is_pinned_quick_action,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name, server_id=excluded.server_id, command=excluded.command, type=excluded.type,
              interval_seconds=excluded.interval_seconds, working_directory=excluded.working_directory,
              environment_json=excluded.environment_json, confirmation_required=excluded.confirmation_required,
              display_type=excluded.display_type, stop_on_error=excluded.stop_on_error,
              child_action_ids_json=excluded.child_action_ids_json, is_pinned_quick_action=excluded.is_pinned_quick_action,
              updated_at=excluded.updated_at;
            """
            let stmt = try prepareLocked(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, action.id.uuidString)
            bindText(stmt, 2, action.name)
            if let sid = action.serverId {
                bindText(stmt, 3, sid.uuidString)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            bindText(stmt, 4, action.command)
            bindText(stmt, 5, action.type.rawValue)
            sqlite3_bind_int(stmt, 6, Int32(action.intervalSeconds))
            if let wd = action.workingDirectory {
                bindText(stmt, 7, wd)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            bindText(stmt, 8, envJSON)
            sqlite3_bind_int(stmt, 9, action.confirmationRequired ? 1 : 0)
            bindText(stmt, 10, action.displayType.rawValue)
            sqlite3_bind_int(stmt, 11, action.stopOnError ? 1 : 0)
            bindText(stmt, 12, childJSON)
            sqlite3_bind_int(stmt, 13, action.isPinnedQuickAction ? 1 : 0)
            sqlite3_bind_double(stmt, 14, action.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 15, action.updatedAt.timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    func deleteAction(id: UUID) throws {
        try queue.sync {
            let stmt = try prepareLocked("DELETE FROM actions WHERE id=?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            try stepDone(stmt)
        }
    }

    // MARK: - Projects

    func allProjects() throws -> [Project] {
        try queue.sync {
            let stmt = try prepareLocked("SELECT id,name,server_ids_json,action_ids_json,notes,created_at,updated_at FROM projects ORDER BY name;")
            defer { sqlite3_finalize(stmt) }
            var result: [Project] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: text(stmt, 0) ?? "") ?? UUID()
                let name = text(stmt, 1) ?? ""
                let servers = decodeUUIDArray(text(stmt, 2))
                let actions = decodeUUIDArray(text(stmt, 3))
                let notes = text(stmt, 4) ?? ""
                let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                let updated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                result.append(Project(id: id, name: name, serverIds: servers, actionIds: actions, notes: notes, createdAt: created, updatedAt: updated))
            }
            return result
        }
    }

    func saveProject(_ project: Project) throws {
        try queue.sync {
            let servers = encodeUUIDArray(project.serverIds)
            let actions = encodeUUIDArray(project.actionIds)
            let sql = """
            INSERT INTO projects (id,name,server_ids_json,action_ids_json,notes,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name, server_ids_json=excluded.server_ids_json, action_ids_json=excluded.action_ids_json,
              notes=excluded.notes, updated_at=excluded.updated_at;
            """
            let stmt = try prepareLocked(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, project.id.uuidString)
            bindText(stmt, 2, project.name)
            bindText(stmt, 3, servers)
            bindText(stmt, 4, actions)
            bindText(stmt, 5, project.notes)
            sqlite3_bind_double(stmt, 6, project.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 7, project.updatedAt.timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    func deleteProject(id: UUID) throws {
        try queue.sync {
            let stmt = try prepareLocked("DELETE FROM projects WHERE id=?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            try stepDone(stmt)
            let workflows = try prepareLocked("DELETE FROM deploy_workflows WHERE project_id=?;")
            defer { sqlite3_finalize(workflows) }
            bindText(workflows, 1, id.uuidString)
            try stepDone(workflows)
        }
    }

    // MARK: - Health checks

    func allHealthChecks(serverId: UUID? = nil) throws -> [HealthCheck] {
        try queue.sync {
            let sql: String
            if serverId == nil {
                sql = "SELECT id,name,server_id,kind,target,interval_seconds FROM health_checks ORDER BY name;"
            } else {
                sql = "SELECT id,name,server_id,kind,target,interval_seconds FROM health_checks WHERE server_id=? ORDER BY name;"
            }
            let stmt = try prepareLocked(sql)
            defer { sqlite3_finalize(stmt) }
            if let serverId = serverId { bindText(stmt, 1, serverId.uuidString) }
            var result: [HealthCheck] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(HealthCheck(
                    id: UUID(uuidString: text(stmt, 0) ?? "") ?? UUID(),
                    name: text(stmt, 1) ?? "",
                    serverId: text(stmt, 2).flatMap(UUID.init(uuidString:)),
                    kind: HealthCheck.Kind(rawValue: text(stmt, 3) ?? "") ?? .shell,
                    target: text(stmt, 4) ?? "",
                    intervalSeconds: Int(sqlite3_column_int(stmt, 5))
                ))
            }
            return result
        }
    }

    func saveHealthCheck(_ check: HealthCheck) throws {
        try queue.sync {
            let stmt = try prepareLocked("""
            INSERT INTO health_checks(id,name,server_id,kind,target,interval_seconds) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name,server_id=excluded.server_id,
              kind=excluded.kind,target=excluded.target,interval_seconds=excluded.interval_seconds;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, check.id.uuidString)
            bindText(stmt, 2, check.name)
            if let serverId = check.serverId { bindText(stmt, 3, serverId.uuidString) } else { sqlite3_bind_null(stmt, 3) }
            bindText(stmt, 4, check.kind.rawValue)
            bindText(stmt, 5, check.target)
            sqlite3_bind_int(stmt, 6, Int32(check.intervalSeconds))
            try stepDone(stmt)
        }
    }

    func deleteHealthCheck(id: UUID) throws {
        try queue.sync {
            let stmt = try prepareLocked("DELETE FROM health_checks WHERE id=?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            try stepDone(stmt)
        }
    }

    // MARK: - Deploy workflows

    func allDeployWorkflows(projectId: UUID? = nil) throws -> [DeployWorkflow] {
        try queue.sync {
            let sql = projectId == nil
                ? "SELECT id,name,server_id,project_id,working_directory,step_commands_json,stop_on_error,confirmation_required,created_at,updated_at FROM deploy_workflows ORDER BY name;"
                : "SELECT id,name,server_id,project_id,working_directory,step_commands_json,stop_on_error,confirmation_required,created_at,updated_at FROM deploy_workflows WHERE project_id=? ORDER BY name;"
            let stmt = try prepareLocked(sql)
            defer { sqlite3_finalize(stmt) }
            if let projectId = projectId { bindText(stmt, 1, projectId.uuidString) }
            var result: [DeployWorkflow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let json = text(stmt, 5) ?? "[]"
                let commands = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
                result.append(DeployWorkflow(
                    id: UUID(uuidString: text(stmt, 0) ?? "") ?? UUID(),
                    name: text(stmt, 1) ?? "",
                    serverId: UUID(uuidString: text(stmt, 2) ?? "") ?? UUID(),
                    projectId: text(stmt, 3).flatMap(UUID.init(uuidString:)),
                    workingDirectory: text(stmt, 4),
                    stepCommands: commands,
                    stopOnError: sqlite3_column_int(stmt, 6) != 0,
                    confirmationRequired: sqlite3_column_int(stmt, 7) != 0,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
                ))
            }
            return result
        }
    }

    func saveDeployWorkflow(_ workflow: DeployWorkflow) throws {
        try queue.sync {
            let commands = String(data: (try? JSONEncoder().encode(workflow.stepCommands)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            let stmt = try prepareLocked("""
            INSERT INTO deploy_workflows(id,name,server_id,project_id,working_directory,step_commands_json,stop_on_error,confirmation_required,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,server_id=excluded.server_id,
              project_id=excluded.project_id,working_directory=excluded.working_directory,step_commands_json=excluded.step_commands_json,stop_on_error=excluded.stop_on_error,
              confirmation_required=excluded.confirmation_required,updated_at=excluded.updated_at;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, workflow.id.uuidString)
            bindText(stmt, 2, workflow.name)
            bindText(stmt, 3, workflow.serverId.uuidString)
            if let projectId = workflow.projectId { bindText(stmt, 4, projectId.uuidString) } else { sqlite3_bind_null(stmt, 4) }
            if let directory = workflow.workingDirectory { bindText(stmt, 5, directory) } else { sqlite3_bind_null(stmt, 5) }
            bindText(stmt, 6, commands)
            sqlite3_bind_int(stmt, 7, workflow.stopOnError ? 1 : 0)
            sqlite3_bind_int(stmt, 8, workflow.confirmationRequired ? 1 : 0)
            sqlite3_bind_double(stmt, 9, workflow.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 10, workflow.updatedAt.timeIntervalSince1970)
            try stepDone(stmt)
        }
    }

    func deleteDeployWorkflow(id: UUID) throws {
        try queue.sync {
            let stmt = try prepareLocked("DELETE FROM deploy_workflows WHERE id=?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            try stepDone(stmt)
        }
    }

    // MARK: - Preferences / monitoring

    func savePreferences(_ prefs: AppPreferences) throws {
        try queue.sync {
            preferences = prefs
            if let data = try? JSONEncoder().encode(prefs), let json = String(data: data, encoding: .utf8) {
                try upsertPreferenceLocked(key: "app", value: json)
            }
        }
    }

    func insertMonitoringSample(serverId: UUID, snapshot: ServerSnapshot) throws {
        try queue.sync {
            let stmt = try prepareLocked("""
            INSERT INTO monitoring_samples (server_id,ts,cpu,ram,disk,load1,net_rx,net_tx)
            VALUES (?,?,?,?,?,?,?,?);
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, serverId.uuidString)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, snapshot.cpuPercent)
            sqlite3_bind_double(stmt, 4, snapshot.ramPercent)
            sqlite3_bind_double(stmt, 5, snapshot.diskPercent)
            sqlite3_bind_double(stmt, 6, snapshot.load1)
            sqlite3_bind_double(stmt, 7, snapshot.netRxBytesPerSec)
            sqlite3_bind_double(stmt, 8, snapshot.netTxBytesPerSec)
            try stepDone(stmt)

            // Cap history: keep ~24h at 5s = ~17280 rows/server; prune older
            let cutoff = Date().timeIntervalSince1970 - Double(preferences.monitoringHistoryHours * 3600)
            let prune = try prepareLocked("DELETE FROM monitoring_samples WHERE server_id=? AND ts<?;")
            defer { sqlite3_finalize(prune) }
            bindText(prune, 1, serverId.uuidString)
            sqlite3_bind_double(prune, 2, cutoff)
            try stepDone(prune)
        }
    }

    func monitoringSamples(serverId: UUID, since: Date) throws -> [MonitoringSample] {
        try queue.sync {
            let stmt = try prepareLocked("""
            SELECT ts,cpu,ram,disk,load1,net_rx,net_tx
            FROM monitoring_samples WHERE server_id=? AND ts>=? ORDER BY ts ASC;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, serverId.uuidString)
            sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
            var result: [MonitoringSample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(MonitoringSample(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    cpu: sqlite3_column_double(stmt, 1),
                    ram: sqlite3_column_double(stmt, 2),
                    disk: sqlite3_column_double(stmt, 3),
                    load1: sqlite3_column_double(stmt, 4),
                    netRx: sqlite3_column_double(stmt, 5),
                    netTx: sqlite3_column_double(stmt, 6)
                ))
            }
            return result
        }
    }

    func latestMonitoringSnapshots() throws -> [UUID: ServerSnapshot] {
        try queue.sync {
            let stmt = try prepareLocked("""
            SELECT m.server_id,m.ts,m.cpu,m.ram,m.disk,m.load1,m.net_rx,m.net_tx
            FROM monitoring_samples m
            INNER JOIN (SELECT server_id,MAX(ts) AS newest FROM monitoring_samples GROUP BY server_id) latest
              ON latest.server_id=m.server_id AND latest.newest=m.ts;
            """)
            defer { sqlite3_finalize(stmt) }
            var result: [UUID: ServerSnapshot] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(stmt, 0) ?? "") else { continue }
                let date = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                var snapshot = ServerSnapshot()
                snapshot.status = Date().timeIntervalSince(date) < 90 ? .online : .unknown
                snapshot.updatedAt = date
                snapshot.cpuPercent = sqlite3_column_double(stmt, 2)
                snapshot.ramPercent = sqlite3_column_double(stmt, 3)
                snapshot.diskPercent = sqlite3_column_double(stmt, 4)
                snapshot.load1 = sqlite3_column_double(stmt, 5)
                snapshot.netRxBytesPerSec = sqlite3_column_double(stmt, 6)
                snapshot.netTxBytesPerSec = sqlite3_column_double(stmt, 7)
                result[id] = snapshot
            }
            return result
        }
    }

    // MARK: - Helpers

    private func loadPreferencesLocked() {
        guard let stmt = try? prepareLocked("SELECT value FROM preferences WHERE key='app';") else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, let json = text(stmt, 0), let data = json.data(using: .utf8),
           let prefs = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            preferences = prefs
        }
    }

    private func upsertPreferenceLocked(key: String, value: String) throws {
        let stmt = try prepareLocked("INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, value)
        try stepDone(stmt)
    }

    private func serverFromRow(_ stmt: OpaquePointer?) -> Server {
        let id = UUID(uuidString: text(stmt, 0) ?? "") ?? UUID()
        let name = text(stmt, 1) ?? ""
        let host = text(stmt, 2) ?? ""
        let port = Int(sqlite3_column_int(stmt, 3))
        let username = text(stmt, 4) ?? ""
        let auth = AuthType(rawValue: text(stmt, 5) ?? "") ?? .password
        let secretId = text(stmt, 6) ?? UUID().uuidString
        let keyPath = text(stmt, 7)
        let group = ServerGroup(rawValue: text(stmt, 8) ?? "") ?? .personal
        let favorite = sqlite3_column_int(stmt, 9) != 0
        let notes = text(stmt, 10) ?? ""
        let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        let updated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        return Server(id: id, name: name, host: host, port: port, username: username, authType: auth,
                      secretId: secretId, privateKeyPath: keyPath, group: group, isFavorite: favorite,
                      notes: notes, createdAt: created, updatedAt: updated)
    }

    private func actionFromRow(_ stmt: OpaquePointer?) -> CustomAction {
        let id = UUID(uuidString: text(stmt, 0) ?? "") ?? UUID()
        let name = text(stmt, 1) ?? ""
        let serverId = text(stmt, 2).flatMap(UUID.init(uuidString:))
        let command = text(stmt, 3) ?? ""
        let type = ActionType(rawValue: text(stmt, 4) ?? "") ?? .command
        let interval = Int(sqlite3_column_int(stmt, 5))
        let wd = text(stmt, 6)
        let envJSON = text(stmt, 7) ?? "{}"
        let env = (try? JSONDecoder().decode([String: String].self, from: Data(envJSON.utf8))) ?? [:]
        let confirm = sqlite3_column_int(stmt, 8) != 0
        let display = ActionDisplayType(rawValue: text(stmt, 9) ?? "") ?? .output
        let stop = sqlite3_column_int(stmt, 10) != 0
        let children = decodeUUIDArray(text(stmt, 11))
        let pinned = sqlite3_column_int(stmt, 12) != 0
        let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
        let updated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
        return CustomAction(id: id, name: name, serverId: serverId, command: command, type: type,
                            intervalSeconds: interval, workingDirectory: wd, environment: env,
                            confirmationRequired: confirm, displayType: display, stopOnError: stop,
                            childActionIds: children, isPinnedQuickAction: pinned,
                            createdAt: created, updatedAt: updated)
    }

    private func encodeUUIDArray(_ ids: [UUID]) -> String {
        (try? String(data: JSONEncoder().encode(ids.map(\.uuidString)), encoding: .utf8)) ?? "[]"
    }

    private func decodeUUIDArray(_ json: String?) -> [UUID] {
        guard let json = json, let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr.compactMap(UUID.init(uuidString:))
    }

    private func execLocked(_ sql: String) throws {
        guard let db = db else { throw StorageError.notOpen }
        var err: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw StorageError.prepareFailed(message)
        }
    }

    private func prepareLocked(_ sql: String) throws -> OpaquePointer? {
        guard let db = db else { throw StorageError.notOpen }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw StorageError.prepareFailed(msg)
        }
        return stmt
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed"
            throw StorageError.stepFailed(msg)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
