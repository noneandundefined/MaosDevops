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
}

enum ServerDetailTab: String, CaseIterable {
    case overview, terminal, docker, services, logs, files, monitoring, actions, git, health

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
    /// Strong retain independent of AppKit window-controller quirks.
    private let retainedWindow: NSWindow

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MaosDevOps"
        window.minSize = NSSize(width: 800, height: 500)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.alphaValue = 1.0
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor.windowBackgroundColor
        // Avoid frame autosave restoring an off-screen rect from a previous broken run.
        window.setFrameAutosaveName("")

        retainedWindow = window
        super.init(window: window)

        sidebarController.delegate = self

        // Regular split items — NOT sidebarWithViewController.
        // The sidebar-style item has caused empty/invisible windows on Catalina.
        let sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 260
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 500

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(contentItem)
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin

        window.contentViewController = splitViewController

        // Embed default page after the hierarchy exists.
        contentController.embed(ServersListViewController())

        positionOnMainScreen()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func forcePresent() {
        positionOnMainScreen()
        let window = retainedWindow
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .normal
        window.alphaValue = 1.0
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        showWindow(nil)
    }

    private func positionOnMainScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            retainedWindow.center()
            return
        }
        let visible = screen.visibleFrame
        let width = min(1100, max(800, visible.width - 80))
        let height = min(700, max(500, visible.height - 80))
        let x = visible.origin.x + (visible.width - width) / 2
        let y = visible.origin.y + (visible.height - height) / 2
        retainedWindow.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
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
