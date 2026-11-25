import AppKit

// What every device screen shares (app/Pages.cs, DevicePage): the title, the status line, and the device's work queue, so calls to one
// device run one at a time and off the main thread.
class DevicePage: NSViewController {
    private(set) var device: FoundDevice
    private let makeHidpp: (() throws -> Hidpp)?
    private var hidpp: Hidpp?
    let queue = DispatchQueue(label: "device")
    let header = PageHeader()
    let status = StatusLine()

    init(device: FoundDevice, hidpp: (() throws -> Hidpp)? = nil) {
        self.device = device
        makeHidpp = hidpp
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // After each scan, with what it read (the battery).
    func update(_ device: FoundDevice) {
        self.device = device
        if isViewLoaded { header.show(device) }
    }

    // After a scan that found the device again (a plug event, a quick off and on): for what the device forgets when it loses power.
    func scanned() {}

    // At quit: what the page holds on the device goes back.
    func giveBack() {}

    // A HID++ event from the device: `11 <index> <feature index> <fn << 4> <parameters>`.
    func heard(_ report: [UInt8]) {}

    // Opened on first use, on the queue.
    func connection() throws -> Hidpp {
        if let hidpp = hidpp { return hidpp }
        guard let makeHidpp = makeHidpp else { throw GLiteError.io("G-Lite can't talk to this device") }
        let made = try makeHidpp()
        made.deviceLabel = device.shortName
        hidpp = made
        return made
    }

    // Runs work on the device's queue, then done on the main queue; an error goes to the status line.
    func run(_ work: @escaping (Hidpp) throws -> Void, done: (() -> Void)? = nil) {
        queue.async {
            do {
                try work(try self.connection())
                DispatchQueue.main.async { done?() }
            } catch {
                DispatchQueue.main.async { self.status.show("\(error)", error: true) }
            }
        }
    }

    // The keyboard's layout code (0x4540 fn 0), -1 when it has none: above 1 the key picture is ISO's (KeyLayout.isIso).
    func layoutCode(_ hidpp: Hidpp) -> Int {
        guard device.has(0x4540), let reply = try? hidpp.call(try hidpp.featureIndex(0x4540), 0) else { return -1 }
        return Int(reply[0])
    }

    // The key picture's box, and the ISO picture once the keyboard says it's ISO.
    func pictureBox(_ picture: KeyPicture) -> NSView {
        picture.translatesAutoresizingMaskIntoConstraints = false
        let box = Ui.box("Live on the keyboard", picture)
        picture.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        return box
    }

    func applyLayout(_ picture: KeyPicture?, _ layout: KeyLayout?, _ code: Int) {
        guard let picture = picture, let layout = layout, KeyLayout.isIso(code), let iso = layout.iso() else { return }
        picture.setLayout(iso)
    }

    // ---- presets (app/Pages.cs, DevicePage) ----
    // A preset is the screen's settings as text, kept as profile.<device>.<name> in settings.txt, in the Windows text, and the picked
    // one as preset.<device> (with "=edited" once the settings moved away from it, so the next start keeps what the device has and
    // shows the dot instead of sending the preset over it). A screen takes part by giving presetText, applyPreset and presetPrefix, and
    // calls edited() on each change and loaded() after each load.

    // The screen's settings as a preset's text; nil on a screen without presets.
    func presetText() -> String? { nil }
    func applyPreset(_ text: String) {}
    // What picking – does: back to what the device had.
    func revertWithoutPreset() {}
    var presetPrefix: String { "profile." + device.settingsKey + "." }
    // Whether the settings can be kept now (a mouse without a Left click can't).
    var keepable: Bool { true }
    // A control at the right of the preset row, like the keyboards' view picker on Windows.
    var headerAccessory: NSView? { nil }

    private let presets = NSPopUpButton()
    private let updateButton = NSButton(title: "New…", target: nil, action: nil)
    private let moreButton = NSButton(title: "…", target: nil, action: nil)
    private var loadedPreset: String?, baseline: String?, rememberedPreset = ""
    private var touched = false, restoring = true, ready = false
    private var drafts: [String: (baseline: String, text: String)] = [:]
    private var presetKey: String { "preset." + device.settingsKey }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard presetText() != nil else { return }
        presets.target = self; presets.action = #selector(presetPicked)
        presets.widthAnchor.constraint(equalToConstant: 180).isActive = true
        updateButton.target = self; updateButton.action = #selector(updateClicked)
        moreButton.target = self; moreButton.action = #selector(moreClicked)
        let row = NSStackView(views: [Ui.secondary("G-Lite preset"), presets, updateButton, moreButton])
        row.spacing = 8
        header.addArrangedSubview(row)
        if let accessory = headerAccessory, let content = header.superview {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(accessory)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        header.setCustomSpacing(12, after: header.arrangedSubviews[header.arrangedSubviews.count - 2])
        loadPresets(select: nil)
    }

    private var presetNames: [String] {
        Settings.keys().filter { $0.hasPrefix(presetPrefix) }.map { String($0.dropFirst(presetPrefix.count)) }.sorted()
    }

    private func loadPresets(select: String?) {
        presets.removeAllItems()
        presets.addItem(withTitle: "–")
        for name in presetNames { presets.addItem(withTitle: name) }
        presets.selectItem(at: select.flatMap { presetNames.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        showPresets()
    }

    private var pickedName: String? { presets.indexOfSelectedItem > 0 ? presetNames[presets.indexOfSelectedItem - 1] : nil }

    private func changed() -> Bool { touched && baseline != nil && presetText() != baseline }

    private func showPresets() {
        guard presetText() != nil else { return }
        let picked = pickedName != nil, dirty = picked && changed()
        // The dot marks a preset changed since it was loaded, or one with changes left as a draft.
        for (index, name) in presetNames.enumerated() {
            presets.item(at: index + 1)?.title = name + (drafts[name] != nil || (name == loadedPreset && dirty) ? " •" : "")
        }
        updateButton.title = picked ? "Update" : "New…"
        updateButton.isEnabled = (picked ? dirty : ready) && keepable
        rememberPreset()
    }

    // Whether Revert is on: with a preset picked, while it has the dot.
    var presetUnsaved: Bool { pickedName != nil && changed() }

    // Called by every change a screen makes.
    func edited() {
        touched = true
        showPresets()
    }

    // Called after each load; once per run, the picked preset comes back after the first load: a device that saves (G515, mice)
    // comes back on its onboard settings, not the unsaved preview.
    func loaded() {
        ready = true
        showPresets()
        guard presetText() != nil, restoring else { return }
        restoring = false
        rememberedPreset = Settings.get(presetKey)
        let parts = rememberedPreset.components(separatedBy: "=")
        let edited = parts.count > 1
        guard let index = presetNames.firstIndex(of: parts[0]) else { rememberPreset(); return }
        let text = Settings.get(presetPrefix + parts[0])
        if !edited && presetText() != text { applyPreset(text) }
        presets.selectItem(at: index + 1)
        loadedPreset = parts[0]
        baseline = edited ? text : presetText()
        touched = edited
        showPresets()
    }

    private func rememberPreset() {
        if restoring { return }
        let value = loadedPreset.map { $0 + (changed() ? "=edited" : "") } ?? ""
        if value == rememberedPreset { return }
        rememberedPreset = value
        if value.isEmpty { Settings.remove(presetKey) } else { Settings.set(presetKey, value) }
    }

    // Back to –: the device shows something else now (another onboard profile).
    func dropPreset() {
        presets.selectItem(at: 0)
        loadedPreset = nil
        baseline = nil
        touched = false
        showPresets()
    }

    // Revert with a preset picked: the preset as it was loaded. Returns false when no preset is picked, and the screen reverts itself.
    func revertToPreset() -> Bool {
        guard pickedName != nil, let baseline = baseline else { return false }
        if changed() { applyPreset(baseline) }
        touched = false
        showPresets()
        return true
    }

    @objc private func presetPicked() {
        if let loaded = loadedPreset {
            if changed(), let baseline = baseline, let text = presetText() { drafts[loaded] = (baseline, text) } else { drafts[loaded] = nil }
        }
        baseline = nil
        loadedPreset = nil
        touched = false
        restoring = false
        if let name = pickedName {
            if let draft = drafts.removeValue(forKey: name) { applyPreset(draft.text); baseline = draft.baseline; touched = true }
            else { applyPreset(Settings.get(presetPrefix + name)); baseline = presetText() }
            loadedPreset = name
        } else {
            revertWithoutPreset()
        }
        showPresets()
    }

    @objc private func updateClicked() {
        guard let name = pickedName else { askName(nil); return }
        baseline = presetText()
        touched = false
        Settings.set(presetPrefix + name, baseline ?? "")
        showPresets()
        status.show("Updated the preset \(name)")
    }

    @objc private func moreClicked() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Save as new preset…", action: #selector(saveAsNew), keyEquivalent: "").target = self
        let rename = menu.addItem(withTitle: "Rename…", action: pickedName != nil ? #selector(renamePreset) : nil, keyEquivalent: "")
        rename.target = self
        let delete = menu.addItem(withTitle: "Delete", action: pickedName != nil ? #selector(deletePreset) : nil, keyEquivalent: "")
        delete.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton)
    }

    @objc private func saveAsNew() { askName(nil) }
    @objc private func renamePreset() { askName(pickedName) }

    @objc private func deletePreset() {
        guard let name = pickedName else { return }
        Settings.remove(presetPrefix + name)
        drafts[name] = nil
        baseline = nil
        loadedPreset = nil
        loadPresets(select: nil)
        revertWithoutPreset()
        showPresets()
        status.show("Deleted the preset \(name)")
    }

    // A name, in a sheet: a new preset of the settings as they are, or a new name for one.
    private func askName(_ old: String?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = old == nil ? "Save as a new preset" : "Rename the preset \(old!)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = old ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: old == nil ? "Save" : "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.saveName(field.stringValue.trimmingCharacters(in: .whitespaces), old)
        }
    }

    private func saveName(_ name: String, _ old: String?) {
        if name.isEmpty { status.show("Type a name for the preset first", error: true); return }
        if name.contains("=") { status.show("A preset name can't contain =", error: true); return }
        if name == old { return }
        if presetNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            status.show("There's already a preset called \(name). Pick it and press Update to change it.", error: true)
            return
        }
        if let old = old {
            Settings.set(presetPrefix + name, Settings.get(presetPrefix + old))
            Settings.remove(presetPrefix + old)
            if loadedPreset == old { loadedPreset = name }
            loadPresets(select: name)
            status.show("Renamed the preset to \(name)")
            return
        }
        baseline = presetText()
        touched = false
        loadedPreset = name
        restoring = false
        Settings.set(presetPrefix + name, baseline ?? "")
        loadPresets(select: name)
        status.show("Saved the preset \(name)")
    }

    // A user's action, in the log like on Windows.
    func logAction(_ text: String) { Log.add(device.shortName, "you", text) }
}

// The layout every page shares (app/Pages.cs): the title, its boxes, then a line with the status on the left and the buttons on the
// right.
enum Ui {
    static func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    static func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 520
        return label
    }

    // A card with its heading inside, like the Windows RoundedBox: every margin set here, since NSBox's own title and content
    // margins left the content unevenly placed.
    static func box(_ title: String, _ content: NSView) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.04) : NSColor.black.withAlphaComponent(0.025)
        }
        box.contentViewMargins = .zero
        let holder = NSView()
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        for view in [heading, content] { view.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: holder.topAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16),
            content.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -14),
        ])
        box.contentView = holder
        return box
    }

    static func page(header: NSView, body: [NSView], status: NSView?, buttons: [NSView]) -> NSView {
        let content = NSStackView(views: [header] + body)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        for view in body { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }

        let line = NSBox()
        line.boxType = .separator
        let footer = NSStackView(views: (status.map { [$0] } ?? []) + buttons)
        footer.distribution = .fill
        status?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The buttons keep their size; the status line takes the rest.
        for button in buttons { button.setContentHuggingPriority(.required, for: .horizontal) }
        status?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let page = NSView()
        for view in [content, line, footer] { view.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(view) }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: page.safeAreaLayoutGuide.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: line.topAnchor, constant: -16),
            line.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            footer.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -14),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        return page
    }

    static func hint(_ text: String) -> NSTextField {
        let label = secondary(text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    // The value shown right of a slider's name.
    static func value() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.alignment = .right
        return label
    }

    static func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        return stack
    }

    static func slider(_ target: AnyObject? = nil, _ action: Selector? = nil) -> NSSlider {
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: target, action: action)
        slider.isContinuous = true
        return slider
    }

    // A slider under its name, with its value on the right of the name, like the Windows boxes. Returns the row and the name.
    static func sliderRow(_ name: String, _ slider: NSSlider, _ value: NSTextField, width: CGFloat = 320) -> (NSView, NSTextField) {
        let head = secondary(name)
        let top = NSStackView(views: [head, value])
        top.distribution = .fill
        head.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = column([top, slider], spacing: 4)
        for view in [top, slider] { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return (row, head)
    }

    static func toggle(_ target: AnyObject? = nil, _ action: Selector? = nil) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = target
        toggle.action = action
        return toggle
    }

    // A switch with its name, and a note under the name.
    static func toggleRow(_ name: String, _ toggle: NSSwitch, note: String? = nil) -> NSView {
        let text = column([label(name)] + (note.map { [hint($0)] } ?? []), spacing: 2)
        let row = NSStackView(views: [toggle, text])
        row.alignment = .top
        row.spacing = 10
        return row
    }

    // A name greyed out while its control is off.
    static func dim(_ label: NSTextField?, _ off: Bool) { label?.textColor = off ? .tertiaryLabelColor : .secondaryLabelColor }

    static func number(_ value: Double) -> String {
        let format = NumberFormatter()
        format.maximumFractionDigits = 2
        format.locale = Locale(identifier: "en_US_POSIX")
        return format.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // SF Symbols for each kind of device, like the icons of the Windows device list.
    static func symbol(_ device: FoundDevice) -> String {
        if device.name.uppercased().contains("G560") { return "hifispeaker.2" }
        switch device.kind {
        case "keyboard": return "keyboard"
        case "mouse": return "computermouse"
        case "headset": return "headphones"
        case "light": return "lightbulb"
        default: return "cable.connector"
        }
    }

    static func subtitle(_ device: FoundDevice) -> String {
        [device.link, device.asleep ? "asleep" : device.batteryText].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

final class PageHeader: NSStackView {
    private let title = NSTextField(labelWithString: ""), subtitle = NSTextField(labelWithString: "")

    init(_ text: String = "") {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.stringValue = text
        subtitle.textColor = .secondaryLabelColor
        addArrangedSubview(title)
        addArrangedSubview(subtitle)
        subtitle.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ device: FoundDevice) {
        title.stringValue = device.shortName
        subtitle.stringValue = Ui.subtitle(device)
        subtitle.isHidden = subtitle.stringValue.isEmpty
    }
}

final class StatusLine: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false; isBordered = false; drawsBackground = false
        lineBreakMode = .byTruncatingTail
        textColor = .secondaryLabelColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, error: Bool = false) {
        stringValue = text
        toolTip = text.isEmpty ? nil : text
        textColor = error ? .systemRed : .secondaryLabelColor
    }
}

// For a device G-Lite for Mac can't change yet, or that is asleep (app/Pages.cs, InfoPage).
final class InfoPage: DevicePage {
    private let rescan: () -> Void
    private let state = Ui.secondary("")
    private let details = NSGridView()

    init(device: FoundDevice, rescan: @escaping () -> Void) {
        self.rescan = rescan
        super.init(device: device)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let again = NSButton(title: "Scan again", target: self, action: #selector(scanAgain))
        details.rowSpacing = 8
        details.rowAlignment = .firstBaseline
        details.columnSpacing = 16
        state.preferredMaxLayoutWidth = 520
        view = Ui.page(header: header, body: [Ui.box("Status", state), Ui.box("About this device", details)], status: nil,
                       buttons: [NSView(), again])
        update(device)
    }

    override func update(_ device: FoundDevice) {
        super.update(device)
        guard isViewLoaded else { return }
        state.stringValue = device.asleep
            ? "The device is asleep. Press a key or move it to wake it, then scan again."
            : "G-Lite for Mac can't change this device yet. It works on the Windows version."
        while details.numberOfRows > 0 { details.removeRow(at: 0) }
        let rows: [(String, String)] = [
            ("Connection", device.link), ("Battery", device.batteryText), ("Firmware", device.firmware), ("Model ids", device.models),
            ("Features", device.features.map { String(format: "%04X", $0) }.joined(separator: " ")),
        ]
        for (name, value) in rows where !value.isEmpty {
            let text = NSTextField(wrappingLabelWithString: value)
            text.isSelectable = true
            text.preferredMaxLayoutWidth = 420
            details.addRow(with: [Ui.label(name), text])
        }
        details.column(at: 0).xPlacement = .trailing
    }
}

// Shown while nothing is found (app/Pages.cs, EmptyPage).
final class EmptyPage: NSViewController {
    private let rescan: () -> Void
    private let text = Ui.secondary("")

    init(rescan: @escaping () -> Void) { self.rescan = rescan; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let again = NSButton(title: "Scan for devices", target: self, action: #selector(scanAgain))
        text.preferredMaxLayoutWidth = 520
        view = Ui.page(header: PageHeader("No devices"), body: [text], status: nil, buttons: [NSView(), again])
        show(scanning: true)
    }

    func show(scanning: Bool, refused: Bool = false) {
        text.stringValue = scanning ? "Looking for devices…"
            : refused ? "macOS doesn't let G-Lite open your Logitech devices. In System Settings, Privacy & Security, Input Monitoring, "
                + "turn G-Lite on (if it's on already, remove it with − and open G-Lite again), then scan again."
            : "G-Lite didn't find a Logitech device. Turn it on or plug it in, then scan again."
    }

    @objc private func scanAgain() { rescan() }
}

extension InfoPage { @objc fileprivate func scanAgain() { rescan() } }

final class SettingsPage: NSViewController {
    private let runAtLogin = NSButton(checkboxWithTitle: "Run G-Lite when I log in", target: nil, action: nil)

    override func loadView() {
        runAtLogin.target = self
        runAtLogin.action = #selector(toggleLogin)
        runAtLogin.state = LoginItem.on ? .on : .off
        let startup = NSStackView(views: [runAtLogin, Ui.secondary("It starts in the menu bar, without opening its window.")])
        startup.orientation = .vertical
        startup.alignment = .leading
        let folder = NSButton(title: "Show settings folder", target: self, action: #selector(showFolder))
        let version = Ui.secondary("G-Lite \(App.version) for Mac. Settings, the log and backups are in "
            + Settings.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + ".")
        let about = NSStackView(views: [version, folder])
        about.orientation = .vertical
        about.alignment = .leading
        view = Ui.page(header: PageHeader("Settings"), body: [Ui.box("Startup", startup), Ui.box("About", about)], status: nil, buttons: [])
    }

    @objc private func toggleLogin() {
        LoginItem.on = runAtLogin.state == .on
        runAtLogin.state = LoginItem.on ? .on : .off
    }

    @objc private func showFolder() { NSWorkspace.shared.activateFileViewerSelecting([Settings.location]) }
}

// Run at login, through a launch agent: it can pass --tray, so G-Lite starts without its window, like the Windows Run entry.
enum LoginItem {
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/org.g-lite.GLite.plist")
    }

    static var on: Bool {
        get { FileManager.default.fileExists(atPath: file.path) }
        set {
            if !newValue { try? FileManager.default.removeItem(at: file); return }
            guard let executable = Bundle.main.executablePath else { return }
            let agent: [String: Any] = [
                "Label": "org.g-lite.GLite", "ProgramArguments": [executable, "--tray"], "RunAtLoad": true, "ProcessType": "Interactive",
            ]
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            (agent as NSDictionary).write(to: file, atomically: true)
        }
    }
}

// log.txt, newest last, refreshed while shown (app/LogsPage.cs).
final class LogsPage: NSViewController {
    private let count = StatusLine()
    private var timer: Timer?
    private var size = -1

    override func loadView() {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(showFile))
        view = Ui.page(header: PageHeader("Logs"), body: [scroll], status: count, buttons: [reveal, clear])
        scroll.bottomAnchor.constraint(equalTo: count.topAnchor, constant: -30).isActive = true
        textViewRef = textView
    }

    private weak var textViewRef: NSTextView?

    override func viewWillAppear() {
        super.viewWillAppear()
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.render() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
        timer = nil
    }

    private func render() {
        let now = Log.size()
        if now == size { return }
        size = now
        let lines = Log.mergeRepeatedSends(Log.read())
        guard let textView = textViewRef else { return }
        let atEnd = textView.visibleRect.maxY >= textView.bounds.maxY - 20
        textView.string = lines.map(Log.format).joined(separator: "\n")
        textView.textColor = .labelColor
        count.show(lines.isEmpty ? "The log is empty" : "\(lines.count) lines, \(max(1, now / 1024)) KB")
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    @objc private func clearLog() { Log.clear(); size = -1; render() }
    @objc private func showFile() { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }
}
