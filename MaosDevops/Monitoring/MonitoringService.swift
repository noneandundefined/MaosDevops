import Foundation

struct MonitoringSample {
    let timestamp: Date
    let cpu: Double
    let ram: Double
    let disk: Double
    let load1: Double
    let netRx: Double
    let netTx: Double
}

/// Polls server metrics over SSH. Stops when UI is not visible.
final class MonitoringService {
    private let sshManager: SSHConnectionManager
    private let storage: StorageService
    private var timers: [UUID: DispatchSourceTimer] = [:]
    private var lastNet: [UUID: (rx: Double, tx: Double, at: Date)] = [:]
    private let queue = DispatchQueue(label: "com.maosdevops.monitoring", qos: .utility)
    private var handlers: [UUID: (ServerSnapshot) -> Void] = [:]
    private var lastSnapshots: [UUID: ServerSnapshot] = [:]
    private var lastDiskPoll: [UUID: Date] = [:]
    private var lastDockerPoll: [UUID: Date] = [:]

    init(sshManager: SSHConnectionManager, storage: StorageService) {
        self.sshManager = sshManager
        self.storage = storage
    }

    func start(for server: Server, onUpdate: @escaping (ServerSnapshot) -> Void) {
        stop(serverId: server.id)
        handlers[server.id] = onUpdate
        let prefs = storage.preferences
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(prefs.cpuRamPollSeconds))
        timer.setEventHandler { [weak self] in
            self?.poll(server: server)
        }
        timers[server.id] = timer
        timer.resume()
    }

    func stop(serverId: UUID) {
        timers[serverId]?.cancel()
        timers[serverId] = nil
        handlers[serverId] = nil
    }

    func stopAll() {
        timers.keys.forEach(stop)
    }

    func fetchOnce(server: Server, completion: @escaping (Result<ServerSnapshot, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let snap = try self.collect(server: server)
                DispatchQueue.main.async { completion(.success(snap)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func poll(server: Server) {
        do {
            let snap = try collect(server: server)
            try? storage.insertMonitoringSample(serverId: server.id, snapshot: snap)
            let handler = handlers[server.id]
            DispatchQueue.main.async { handler?(snap) }
        } catch {
            var offline = ServerSnapshot()
            offline.status = .offline
            let handler = handlers[server.id]
            DispatchQueue.main.async { handler?(offline) }
        }
    }

    /// Single SSH round-trip script — minimizes channel churn on weak machines.
    private func collect(server: Server) throws -> ServerSnapshot {
        let now = Date()
        let preferences = storage.preferences
        let needDisk = lastDiskPoll[server.id].map { now.timeIntervalSince($0) >= Double(preferences.diskPollSeconds) } ?? true
        let needDocker = lastDockerPoll[server.id].map { now.timeIntervalSince($0) >= Double(preferences.dockerPollSeconds) } ?? true
        let diskCommand = needDisk ? "DISK=$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,\"\",$5); print $5}')" : "DISK="
        let capabilityCommands = needDocker
            ? "DOCKER=0; command -v docker >/dev/null 2>&1 && DOCKER=1; SYSTEMD=0; command -v systemctl >/dev/null 2>&1 && SYSTEMD=1"
            : "DOCKER=; SYSTEMD="
        let script = """
        set +e
        HOSTNAME=$(hostname 2>/dev/null)
        OS=$(uname -srm 2>/dev/null)
        UPTIME=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
        # CPU: 1-second sample from /proc/stat
        read -r _ u1 n1 s1 i1 rest < /proc/stat
        sleep 1
        read -r _ u2 n2 s2 i2 rest < /proc/stat
        TOTAL1=$((u1+n1+s1+i1)); TOTAL2=$((u2+n2+s2+i2))
        IDLE1=$i1; IDLE2=$i2
        DIFF_TOTAL=$((TOTAL2-TOTAL1)); DIFF_IDLE=$((IDLE2-IDLE1))
        if [ "$DIFF_TOTAL" -gt 0 ]; then CPU=$(awk -v t=$DIFF_TOTAL -v i=$DIFF_IDLE 'BEGIN{printf "%.1f", (1-i/t)*100}'); else CPU=0; fi
        # RAM
        MEM=$(free -b 2>/dev/null | awk '/Mem:/ {if($2>0) printf "%.1f", ($2-$7)/$2*100}')
        # Disk root (lower cadence than CPU/RAM)
        \(diskCommand)
        # Network totals
        NET=$(cat /proc/net/dev 2>/dev/null | awk -F'[: ]+' 'NR>2 && $1!~/lo/{rx+=$3; tx+=$11} END{print rx+0, tx+0}')
        \(capabilityCommands)
        printf 'HOST=%s\\nOS=%s\\nUP=%s\\nLOAD=%s\\nCPU=%s\\nMEM=%s\\nDISK=%s\\nNET=%s\\nDOCKER=%s\\nSYSTEMD=%s\\n' \
          "$HOSTNAME" "$OS" "$UPTIME" "$LOAD" "$CPU" "$MEM" "$DISK" "$NET" "$DOCKER" "$SYSTEMD"
        """

        let session = sshManager.session(for: server)
        let result = try session.executeSync(script, timeout: 20)
        guard result.exitCode == 0 || !result.stdout.isEmpty else {
            throw SSHError.commandFailed(result.exitCode, result.stderr)
        }

        var snap = lastSnapshots[server.id] ?? ServerSnapshot()
        snap.status = .online
        snap.updatedAt = Date()
        var netRxTotal: Double = 0
        var netTxTotal: Double = 0

        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "HOST": snap.hostname = parts[1]
            case "OS": snap.osName = parts[1]
            case "UP": snap.uptimeSeconds = Int(parts[1]) ?? 0
            case "LOAD":
                let loads = parts[1].split(separator: " ").compactMap { Double($0) }
                if loads.count >= 3 {
                    snap.load1 = loads[0]; snap.load5 = loads[1]; snap.load15 = loads[2]
                }
            case "CPU": snap.cpuPercent = Double(parts[1]) ?? 0
            case "MEM": snap.ramPercent = Double(parts[1]) ?? 0
            case "DISK": if !parts[1].isEmpty { snap.diskPercent = Double(parts[1]) ?? snap.diskPercent }
            case "NET":
                let n = parts[1].split(separator: " ").compactMap { Double($0) }
                if n.count >= 2 { netRxTotal = n[0]; netTxTotal = n[1] }
            case "DOCKER": if !parts[1].isEmpty { snap.dockerAvailable = parts[1] == "1" }
            case "SYSTEMD": if !parts[1].isEmpty { snap.systemdAvailable = parts[1] == "1" }
            default: break
            }
        }

        if let prev = lastNet[server.id] {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0 {
                snap.netRxBytesPerSec = max(0, (netRxTotal - prev.rx) / dt)
                snap.netTxBytesPerSec = max(0, (netTxTotal - prev.tx) / dt)
            }
        }
        lastNet[server.id] = (netRxTotal, netTxTotal, now)
        if needDisk { lastDiskPoll[server.id] = now }
        if needDocker { lastDockerPoll[server.id] = now }
        lastSnapshots[server.id] = snap
        return snap
    }
}
