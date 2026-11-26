import AppKit
import IOKit.hid

// The app (app/Program.cs, Main): the menu bar item with the devices and their battery, and the main window. Opened from the Finder,
// Launchpad or Spotlight it shows its window and a Dock icon; closing the window leaves it in the menu bar. Started at login (--tray)
// it stays in the menu bar.
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let demo: Bool
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var devices: [FoundDevice] = []
    private var watcher: DeviceWatcher?
    private var scanning = false, rescan = false
    private var plugTimer: Timer?
    private lazy var window: MainWindow = {
        let window = MainWindow(makePage: { [unowned self] in self.page(for: $0) }, rescan: { [unowned self] in self.scan() })
        window.closed = { NSApp.setActivationPolicy(.accessory) }
        return window
    }()

    init(demo: Bool) { self.demo = demo }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.add("G-Lite", "start", "version \(App.version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
                + (demo ? ", demo" : ""))
        NSApp.mainMenu = mainMenu()
        item.button?.image = Logo.slanted()
        item.button?.toolTip = "G-Lite"
        item.menu = NSMenu()
        item.menu!.delegate = self
        rebuildMenu()
        if !CommandLine.arguments.contains("--tray") { openWindow(nil) }
        if demo {
            devices = DeviceTable.demoDevices()
            found(devices)
            if let at = CommandLine.arguments.firstIndex(of: "--snapshot"), at + 1 < CommandLine.arguments.count {
                snapshot(into: CommandLine.arguments[at + 1])
            }
            return
        }
        // Opening a receiver that is also a keyboard needs Input Monitoring.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            // Scans again once the permission is turned on, instead of waiting for Scan for devices.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
                timer.invalidate()
                self?.scan()
            }
        }
        Devices.watchPlugging { [weak self] in self?.plugged() }
        scan()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.readBatteries() }
    }

    // Opening the app again (Finder, Dock, Spotlight) while it runs shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { window.giveBack() }

    @objc func openWindow(_ sender: Any?) {
        NSApp.setActivationPolicy(.regular)
        if window.window?.isVisible != true { window.window?.center() }
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // --demo --snapshot <folder>: each screen drawn into a PNG, for checking the layout and for the site.
    private func snapshot(into folder: String) {
        // Each demo device under its key's name (demo|g515 is g515.png), then Settings and Logs.
        var screens: [(String, MainWindow.Row)] = devices.map { (String($0.key.dropFirst(5)), .device($0.key)) }
            + [("settings", .settings), ("logs", .logs)]
        // The mouse's Bindings view, the G915's G keys and the Game views too.
        screens.append(("mouse-buttons", .device("demo|g502")))
        screens.append(("g915-keys", .device("demo|g915")))
        screens.append(("g515-game", .device("demo|g515")))
        screens.append(("g915-game", .device("demo|g915")))
        screens.append(("g515-report", .device("demo|g515")))
        screens.append(("headset-equalizer", .device("demo|headset")))
        screens.append(("g510-keys", .device("demo|g510")))
        screens.append(("g510-game", .device("demo|g510")))
        var next = 0
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [unowned self] timer in
            // An open sheet (the device report) is drawn instead of the page under it.
            guard let view = self.window.window?.attachedSheet?.contentView ?? self.window.window?.contentView else { return }
            // In light mode: a cached view draws without the window's background, which loses light text in dark mode.
            self.window.window?.appearance = NSAppearance(named: .aqua)
            if next > 0, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent(screens[next - 1].0 + ".png"))
            }
            if let sheet = self.window.window?.attachedSheet { self.window.window?.endSheet(sheet) }
            if next == screens.count { timer.invalidate(); NSApp.terminate(nil); return }
            self.window.select(screens[next].1)
            if screens[next].0 == "mouse-buttons" { (self.window.page("demo|g502") as? MousePage)?.showBindings() }
            if screens[next].0 == "g915-keys" { (self.window.page("demo|g915") as? LiveKeyboardPage)?.showKeys() }
            if screens[next].0 == "g515-game" { (self.window.page("demo|g515") as? KeyboardPage)?.showGame() }
            if screens[next].0 == "g515-report" { (self.window.page("demo|g515") as? DevicePage)?.showReport() }
            if screens[next].0 == "headset-equalizer" { (self.window.page("demo|headset") as? HeadsetPage)?.showEqualizer() }
            if screens[next].0 == "g510-keys" { (self.window.page("demo|g510") as? G510Page)?.showView(1) }
            if screens[next].0 == "g510-game" { (self.window.page("demo|g510") as? G510Page)?.showView(2) }
            if screens[next].0 == "g915-game" { (self.window.page("demo|g915") as? LiveKeyboardPage)?.showGame() }
            next += 1
        }
    }

    private func page(for device: FoundDevice) -> NSViewController {
        guard let entry = DeviceTable.entry(device) else { return InfoPage(device: device, rescan: { [unowned self] in self.scan() }) }
        return entry.make(device, { [demo] in
            if demo { return entry.fake(device) }
            guard let port = device.port else { throw GLiteError.io("The device is gone") }
            return try Hidpp(port: port, index: device.index)
        })
    }

    // A plug or unplug comes as several matching calls, one per collection: one scan after they settle.
    private func plugged() {
        plugTimer?.invalidate()
        plugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.scan() }
    }

    @objc func scan() {
        if demo { return }
        if scanning { rescan = true; return }
        scanning = true
        window.scanStarted()
        rebuildMenu()
        DispatchQueue.global().async {
            let found = Devices.scan()
            DispatchQueue.main.async {
                self.scanning = false
                self.found(found)
                if self.rescan { self.rescan = false; self.scan() }
            }
        }
    }

    private func found(_ found: [FoundDevice]) {
        let before = Set(devices.map { $0.key + $0.name })
        for device in found where !before.contains(device.key + device.name) || demo {
            Log.add(device.shortName, "found", [device.link, device.models, device.firmware].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        devices = found
        watcher?.stop()
        if !demo {
            watcher = DeviceWatcher(found, linkChanged: { [weak self] in self?.plugged() },
                                    battery: { [weak self] _ in self?.batteriesChanged() },
                                    event: { [weak self] device, report in (self?.window.page(device.key) as? DevicePage)?.heard(report) })
        }
        window.show(devices: found, scanning: false)
        // What the user changed on a device is sent again at each scan, also when its screen isn't opened (as on Windows).
        window.preload(found.filter(DeviceTable.keeps))
        rebuildMenu()
    }

    private func batteriesChanged() {
        window.refreshBatteries()
        rebuildMenu()
    }

    private func readBatteries() {
        let awake = devices.filter { !$0.asleep && $0.batteryFeature != 0 }
        if awake.isEmpty { return }
        DispatchQueue.global().async {
            for device in awake { Devices.readBattery(device) }
            DispatchQueue.main.async { self.batteriesChanged() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { readBatteries() }

    // The menu bar item's menu (app/Tray.cs): the devices with their battery, Scan for devices, Settings, Quit G-Lite.
    private func rebuildMenu() {
        let menu = item.menu!
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Open G-Lite", action: #selector(openWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        if !demo && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            menu.addItem(NSMenuItem(title: "Allow Input Monitoring…", action: #selector(openPrivacy), keyEquivalent: ""))
            menu.addItem(.separator())
        }
        if devices.isEmpty {
            let none = NSMenuItem(title: scanning ? "Looking for devices…" : "No devices found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        // The values' column starts after the longest name, so a long one doesn't push its battery onto a second line.
        let column = devices.map { MenuRow.width($0.shortName) }.max().map { max(220, $0 + 70) } ?? 220
        for device in devices {
            let row = NSMenuItem(title: device.shortName, action: #selector(openDevice), keyEquivalent: "")
            row.representedObject = device.key
            row.attributedTitle = MenuRow.text(device.shortName, device.asleep ? "asleep" : device.batteryText, column: column)
            row.image = NSImage(systemSymbolName: Ui.symbol(device), accessibilityDescription: nil)
            menu.addItem(row)
        }
        menu.addItem(.separator())
        if !demo { menu.addItem(NSMenuItem(title: scanning ? "Scanning…" : "Scan for devices", action: #selector(scan), keyEquivalent: "")) }
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: demo ? "Leave Demo Mode" : "Demo Mode", action: #selector(switchDemo), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit G-Lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for row in menu.items where row.action != #selector(NSApplication.terminate(_:)) { row.target = self }
    }

    // The demo (every device Windows' --demo lists, simulated) as a relaunch with --demo, and back.
    @objc private func switchDemo() {
        // Not NSWorkspace.openApplication: its completion waits for the new copy to finish launching, which waits for this one to
        // quit, so both gave up after 5 s. Process returns once the new copy exists.
        let relaunch = Process()
        relaunch.executableURL = Bundle.main.executableURL
        relaunch.arguments = (demo ? [] : ["--demo"]) + ["--relaunched"]
        do { try relaunch.run() } catch { Log.add("G-Lite", "error", "Demo Mode didn't relaunch: \(error)"); return }
        NSApp.terminate(nil)
    }

    @objc private func openDevice(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        openWindow(nil)
        window.selectDevice(key)
    }

    @objc private func openSettings() {
        openWindow(nil)
        window.select(.settings)
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // The menus of a Mac app, for ⌘Q, ⌘W, ⌘, and copying from the log.
    private func mainMenu() -> NSMenu {
        let bar = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            holder.submenu = NSMenu(title: title)
            for item in items { holder.submenu!.addItem(item) }
            bar.addItem(holder)
        }
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let demoItem = NSMenuItem(title: demo ? "Leave Demo Mode" : "Demo Mode", action: #selector(switchDemo), keyEquivalent: "")
        demoItem.target = self
        add("G-Lite", [
            NSMenuItem(title: "About G-Lite", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(), settingsItem, demoItem, .separator(),
            NSMenuItem(title: "Hide G-Lite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            NSMenuItem(title: "Quit G-Lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        add("Edit", [
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        add("Window", [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
        ])
        return bar
    }
}

// A menu row with its value right-aligned, like the Windows tray menu's shortcut column.
enum MenuRow {
    static func width(_ name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width)
    }

    static func text(_ name: String, _ value: String, column: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: column)]
        let text = NSMutableAttributedString(string: name + (value.isEmpty ? "" : "\t" + value),
                                             attributes: [.paragraphStyle: style, .font: NSFont.menuFont(ofSize: 0)])
        if !value.isEmpty {
            text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                              range: NSRange(location: name.utf16.count + 1, length: value.utf16.count))
        }
        return text
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--selftest") { SelfTest.run(); exit(0) }
if let at = arguments.firstIndex(of: "--iconset"), at + 1 < arguments.count {
    do { try Logo.writeIconset(arguments[at + 1]); exit(0) } catch { print(error); exit(1) }
}
// Prints what the Screen and Audio effects see for two seconds: the four areas' colours and the sound's band levels.
if arguments.contains("--screen") {
    let user = NSObject()
    ScreenSource.shared.use(user)
    var loudest = [Double](repeating: 0, count: 8)
    for _ in 0..<20 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if let bands = ScreenSource.shared.bands(8) { loudest = zip(loudest, bands).map { max($0, $1) } }
    }
    let colors = ScreenSource.shared.sample(ScreenSettings.defaults().map { $0.area })
    print("screen: " + (colors.map { $0.map { String(format: "%06X", $0) }.joined(separator: " ") } ?? "no frame (\(ScreenSource.shared.failure ?? "?"))"))
    print("sound, loudest per band: " + loudest.map { String(format: "%.2f", $0) }.joined(separator: " ")
          + (ScreenSource.shared.heardAudio ? "" : " (no sound came)"))
    ScreenSource.shared.release(user)
    exit(0)
}
// Prints what a scan finds, for checking the transport from a terminal.
if arguments.contains("--scan") {
    for device in Devices.scan() {
        print([device.name, device.kind, device.link, device.models, device.firmware, device.batteryText, device.asleep ? "asleep" : "",
               device.features.map { String(format: "%04X", $0) }.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " | "))
        // What the other devices' screen would read, read only.
        if OtherDevice.supports(device), !device.asleep, let port = device.port {
            do {
                let state = try OtherDevice.read(try Hidpp(port: port, index: device.index), device)
                print("  settings: " + state.set.toText() + ", computer \(state.host + 1) of \(state.hosts)"
                      + (state.dpis.isEmpty ? "" : ", \(state.dpis.count) speeds from \(state.dpis[0]) to \(state.dpis.last!) DPI")
                      + (state.levels > 0 ? ", \(state.levels) backlight levels" : ""))
            } catch { print("  settings: \(error)") }
        }
    }
    exit(0)
}
// One G-Lite at a time; one relaunched for or out of the demo waits up to 5 s for the one before to quit.
if let me = Bundle.main.bundleIdentifier {
    func others() -> Bool { NSRunningApplication.runningApplications(withBundleIdentifier: me).contains { $0 != .current } }
    var waited = 0
    while arguments.contains("--relaunched") && others() && waited < 50 { usleep(100_000); waited += 1 }
    if others() { exit(0) }
}
let app = NSApplication.shared
if arguments.contains("--demo") {
    // The demo devices have real devices' names, so their settings and backups are kept apart, never sent to a real device.
    let demoFolder = Settings.folder.appendingPathComponent("Demo")
    try? FileManager.default.createDirectory(at: demoFolder, withIntermediateDirectories: true)
    Settings.folder = demoFolder
    Log.folder = FileManager.default.temporaryDirectory
}
let delegate = App(demo: arguments.contains("--demo"))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
