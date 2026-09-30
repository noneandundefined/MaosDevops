import Cocoa

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ controller: SidebarViewController, didSelect item: SidebarItem)
}

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: SidebarViewControllerDelegate?
    private let tableView = NSTableView()
    private let items = SidebarItem.allCases
    private var selected = SidebarItem.servers

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        tableView.headerView = nil
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 28
        // Do not use NSTableView.style (macOS 11+). Catalina uses selectionHighlightStyle.
        tableView.selectionHighlightStyle = .sourceList
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = 180
        tableView.addTableColumn(column)

        scroll.documentView = tableView
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let idx = items.firstIndex(of: selected) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.systemFont(ofSize: 13)
            c.addSubview(label)
            c.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor)
            ])
            return c
        }()
        cell.textField?.stringValue = items[row].title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        selected = items[row]
        delegate?.sidebar(self, didSelect: selected)
    }
}
