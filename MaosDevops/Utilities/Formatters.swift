import Foundation

enum Formatters {
    static func uptime(_ seconds: Int) -> String {
        let d = seconds / 86_400
        let h = (seconds % 86_400) / 3600
        let m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func bytes(_ value: Double) -> String {
        if value < 1024 { return String(format: "%.0f B", value) }
        if value < 1024 * 1024 { return String(format: "%.1f KB", value / 1024) }
        return String(format: "%.1f MB", value / (1024 * 1024))
    }
}

struct ProblemItem {
    enum Severity { case critical, warning }
    let severity: Severity
    let title: String
    let suggestedAction: String
    let actionCommand: String?

    init(severity: Severity, title: String, suggestedAction: String, actionCommand: String? = nil) {
        self.severity = severity
        self.title = title
        self.suggestedAction = suggestedAction
        self.actionCommand = actionCommand
    }
}

enum ProblemsDetector {
    static func detect(snapshot: ServerSnapshot) -> [ProblemItem] {
        var items: [ProblemItem] = []
        if snapshot.diskPercent >= 90 {
            items.append(ProblemItem(severity: .critical, title: "🔴 Disk usage \(Int(snapshot.diskPercent))%",
                                     suggestedAction: "Inspect", actionCommand: "df -h /"))
        } else if snapshot.diskPercent >= 80 {
            items.append(ProblemItem(severity: .warning, title: "🟠 Disk usage \(Int(snapshot.diskPercent))%",
                                     suggestedAction: "Inspect", actionCommand: "df -h /"))
        }
        if snapshot.ramPercent >= 90 {
            items.append(ProblemItem(severity: .warning, title: "🟠 RAM usage \(Int(snapshot.ramPercent))%",
                                     suggestedAction: "Inspect", actionCommand: "free -h"))
        }
        if snapshot.status == .offline {
            items.append(ProblemItem(severity: .critical, title: "🔴 Server offline", suggestedAction: "Terminal"))
        }
        return items
    }
}
