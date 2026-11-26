import AppKit

// The main window (app/Program.cs, MainWindow): the devices in a sidebar, one page per device, and Settings and Logs at its bottom,
// in a list of their own so they stay put while devices come and go.
final class MainWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Row: Equatable {
        case heading(String), device(String), settings, logs
    }

    private let table = NSTableView(), appTable = NSTableView()
    private let appRows: [Row] = [.heading("G-Lite"), .settings, .logs]
    private let detail = NSViewController()
    private let split = NSSplitViewController()
    private var rows: [Row] = []
    private var devices: [String: FoundDevice] = [:]
    private var pages: [String: NSViewController] = [:]
    private let settings = SettingsPage(), logs = LogsPage()
    private let empty: EmptyPage
    private let makePage: (FoundDevice) -> NSViewController
    private var selected: Row = .settings
    private var games: GamesWindow?
    var closed: (() -> Void)?

    init(makePage: @escaping (FoundDevice) -> NSViewController, rescan: @escaping () -> Void) {
        self.makePage = makePage
        empty = EmptyPage(rescan: rescan)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 868, height: 730),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "G-Lite"
        window.minSize = NSSize(width: 760, height: 620)
        window.setFrameAutosaveName("main")
        super.init(window: window)
        window.delegate = self

        let scroll = NSScrollView(), appScroll = NSScrollView()
        for (list, holder) in [(table, scroll), (appTable, appScroll)] {
            list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
            list.headerView = nil
            list.style = .sourceList
            list.rowSizeStyle = .large
            list.dataSource = self
            list.delegate = self
            holder.documentView = list
            holder.drawsBackground = false
            holder.translatesAutoresizingMaskIntoConstraints = false
        }
        appScroll.hasVerticalScroller = false
        appScroll.verticalScrollElasticity = .none
        appScroll.automaticallyAdjustsContentInsets = false
        appTable.reloadData()
        let sidebar = NSViewController()
        sidebar.view = NSView()
        sidebar.view.addSubview(scroll)
        sidebar.view.addSubview(appScroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sidebar.view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: appScroll.topAnchor),
            appScroll.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            appScroll.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            appScroll.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor, constant: -10),
            appScroll.heightAnchor.constraint(equalToConstant: appTable.rect(ofRow: appRows.count - 1).maxY + 4),
        ])
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = false
        detail.view = NSView()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        window.contentViewController = split
        // Windows' size at 100%, 868 × 730: the pages with a picture need its height.
        window.setContentSize(NSSize(width: 868, height: 730))
        show(devices: [], scanning: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    // After each scan: keeps each device's page (and what it was doing), drops the pages of devices that are gone.
    func show(devices found: [FoundDevice], scanning: Bool) {
        devices = Dictionary(found.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for key in pages.keys where devices[key] == nil { pages[key] = nil }
        for device in found {
            if let page = pages[device.key] as? DevicePage {
                // A device that woke up or fell asleep gets another screen.
                if page.device.asleep != device.asleep || page.device.name != device.name { pages[device.key] = nil }
                else { page.update(device); page.scanned() }
            }
        }
        rows = found.isEmpty ? [] : [.heading("Devices")] + found.map { .device($0.key) }
        empty.show(scanning: scanning, refused: Devices.refused)
        table.reloadData()
        if case .device(let key) = selected, devices[key] != nil { select(selected) }
        else if let first = found.first { select(.device(first.key)) }
        else if found.isEmpty && selected != .logs { select(.settings, emptyInstead: true) }
        else { select(selected) }
    }

    func scanStarted() { empty.show(scanning: true) }

    func refreshBatteries() {
        for (key, device) in devices { (pages[key] as? DevicePage)?.update(device) }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: [0])
    }

    func select(_ row: Row, emptyInstead: Bool = false) {
        selected = row
        let page: NSViewController
        switch row {
        case .device(let key):
            guard let device = devices[key] else { return }
            if pages[key] == nil { pages[key] = makePage(device) }
            page = pages[key]!
        case .settings: page = emptyInstead && devices.isEmpty ? empty : settings
        case .logs: page = logs
        case .heading: return
        }
        let list = appRows.contains(row) ? appTable : table, other = list === table ? appTable : table
        if let index = self.rows(list).firstIndex(of: row), list.selectedRow != index {
            list.selectRowIndexes([index], byExtendingSelection: false)
        }
        other.deselectAll(nil)
        if detail.children.first !== page {
            detail.children.first?.view.removeFromSuperview()
            detail.children.first?.removeFromParent()
            detail.addChild(page)
            page.view.frame = detail.view.bounds
            page.view.autoresizingMask = [.width, .height]
            detail.view.addSubview(page.view)
        }
    }

    func selectDevice(_ key: String) { select(.device(key)) }

    func page(_ key: String) -> NSViewController? { pages[key] }

    // Makes these devices' screens now, so they load (and send what they keep) without being shown.
    func preload(_ found: [FoundDevice]) {
        for device in found where pages[device.key] == nil {
            let page = makePage(device)
            pages[device.key] = page
            _ = page.view
        }
    }

    // Every page that holds the keys gives them back (at quit).
    func giveBack() { for page in pages.values { (page as? DevicePage)?.giveBack() } }

    private func rows(_ tableView: NSTableView) -> [Row] { tableView === appTable ? appRows : rows }

    func numberOfRows(in tableView: NSTableView) -> Int { rows(tableView).count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = rows(tableView)[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let list = notification.object as? NSTableView, list.selectedRow >= 0, rows(list)[list.selectedRow] != selected else { return }
        select(rows(list)[list.selectedRow])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows(tableView)[row] {
        case .heading(let title):
            let text = NSTextField(labelWithString: title)
            text.font = .systemFont(ofSize: 11, weight: .semibold)
            text.textColor = .secondaryLabelColor
            // The games' easter egg, as Windows' G-Lite title: nothing shows it can be clicked, on purpose.
            if tableView === appTable { text.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleGames))) }
            return text
        case .device(let key):
            guard let device = devices[key] else { return nil }
            return cell(device.shortName, Ui.symbol(device), value: device.asleep ? "asleep" : device.batteryText)
        case .settings: return cell("Settings", "gearshape")
        case .logs: return cell("Logs", "doc.text")
        }
    }

    private func cell(_ title: String, _ symbol: String, value: String = "") -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        // A fixed column, centred: the symbols aren't all as wide, and the names should start at the same place.
        icon.imageAlignment = .alignCenter
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let name = NSTextField(labelWithString: title)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detailText = NSTextField(labelWithString: value)
        detailText.textColor = .secondaryLabelColor
        detailText.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let stack = NSStackView(views: [icon, name, NSView(), detailText])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 8)
        return stack
    }

    @objc private func toggleGames() {
        if games == nil { games = GamesWindow.make() }
        games?.toggle(beside: window)
    }

    func windowWillClose(_ notification: Notification) { closed?() }
}
