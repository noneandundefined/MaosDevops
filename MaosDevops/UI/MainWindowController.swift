import Cocoa

enum SidebarItem: String, CaseIterable {
    case dashboard
    case servers
    case projects
    case actions
    case monitoring

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .servers: return "Servers"
        case .projects: return "Projects"
        case .actions: return "Actions"
        case .monitoring: return "Monitoring"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .servers: return "server.rack"
        case .projects: return "folder"
        case .actions: return "bolt"
        case .monitoring: return "chart.bar"
        }
    }
}

enum ServerDetailTab: String, CaseIterable {
    case overview
    case terminal
    case docker
    case services
    case logs
    case files
    case monitoring
    case actions
    case git
    case health

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .terminal: return "Terminal"
        case .docker: return "Docker"
        case .services: return "Services"
        case .logs: return "Logs"
        case .files: return "Files"
        case .monitoring: return "Monitoring"
        case .actions: return "Actions"
        case .git: return "Git"
        case .health: return "Health"
        }
    }
}

final class MainWindowController: NSWindowController {
    private let splitViewController = NSSplitViewController()
    private let sidebarController = SidebarViewController()
    private let contentController = ContentContainerViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MaosDevOps"
        window.minSize = NSSize(width: 900, height: 560)
        window.center()
        window.titlebarAppearsTransparent = false
        // Avoid heavy vibrancy / blur on Catalina low-RAM machines
        window.backgroundColor = NSColor.windowBackgroundColor

        super.init(window: window)

        sidebarController.delegate = self
        contentController.embed(ServersListViewController())

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
        let contentItem = NSSplitViewItem(viewController: contentController)

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        window.contentViewController = splitViewController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension MainWindowController: SidebarViewControllerDelegate {
    func sidebar(_ controller: SidebarViewController, didSelect item: SidebarItem) {
        switch item {
        case .dashboard:
            contentController.embed(GlobalDashboardViewController())
        case .servers:
            contentController.embed(ServersListViewController())
        case .projects:
            contentController.embed(ProjectsViewController())
        case .actions:
            contentController.embed(ActionsListViewController())
        case .monitoring:
            contentController.embed(GlobalMonitoringViewController())
        }
    }
}

final class ContentContainerViewController: NSViewController {
    private weak var embedded: NSViewController?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    }

    func embed(_ child: NSViewController) {
        if let embedded = embedded {
            embedded.view.removeFromSuperview()
            embedded.removeFromParent()
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        embedded = child
    }
}
