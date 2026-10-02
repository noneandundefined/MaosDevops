import Cocoa

enum SidebarItem: String, CaseIterable {
    case dashboard
    case servers
    case projects
    case actions
    case monitoring

    var title: String {
        switch self {
        case .dashboard: return L10n.text("Dashboard")
        case .servers: return L10n.text("Servers")
        case .projects: return L10n.text("Projects")
        case .actions: return L10n.text("Actions")
        case .monitoring: return L10n.text("Monitoring")
        }
    }
}

enum ServerDetailTab: String, CaseIterable {
    case overview, terminal, docker, services, logs, files, monitoring, actions, git, health

    var title: String {
        switch self {
        case .overview: return L10n.text("Overview")
        case .terminal: return L10n.text("Terminal")
        case .docker: return "Docker"
        case .services: return L10n.text("Services")
        case .logs: return L10n.text("Logs")
        case .files: return L10n.text("Files")
        case .monitoring: return L10n.text("Monitoring")
        case .actions: return L10n.text("Actions")
        case .git: return "Git"
        case .health: return L10n.text("Health")
        }
    }
}

final class MainWindowController: NSWindowController {
    private let splitViewController = NSSplitViewController()
    private let sidebarController = SidebarViewController()
    private let contentController = ContentContainerViewController()
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 940, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Maos DevOps"
        window.minSize = NSSize(width: 760, height: 420)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.alphaValue = 1.0
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.center()
        super.init(window: window)

        sidebarController.delegate = self

        // Regular split items — NOT sidebarWithViewController.
        // The sidebar-style item has caused empty/invisible windows on Catalina.
        let sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 155
        sidebarItem.maximumThickness = 220
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 580

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin

        window.contentViewController = splitViewController

        // Embed default page after the hierarchy exists.
        contentController.embed(ServersListViewController())

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func forcePresent() {
        guard let window = window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
    }

    func embed(_ child: NSViewController) {
        if let embedded = embedded {
            embedded.view.removeFromSuperview()
            embedded.removeFromParent()
        }
        addChild(child)
        L10n.apply(to: child.view)
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
