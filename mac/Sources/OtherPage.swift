import AppKit

// The screen for Logitech devices that aren't G devices (app/OtherDevicePage.cs): a section of rows per feature the device has, sent
// live; Easy-Switch is left out with one computer.
// current is on the screen, sent is on the device, stored is what was read at load, and remembered holds only what the user changed:
// it's kept as device.<device> and sent again at each load.
final class OtherPage: DevicePage {
    private var current = OtherSettings(), stored: OtherSettings?, sent = OtherSettings()
    private var remembered: OtherSettings, rememberedAtLoad: OtherSettings
    private var state: OtherDevice.State?
    private var refreshing = false, dirty = false, sequence = 0
    private var debounce: Timer?

    private var bright: NSSlider?, dpi: NSSlider?, shift: NSSlider?, level: NSSlider?
    private var brightValue = Ui.value(), dpiValue = Ui.value(), shiftValue = Ui.value(), levelValue = Ui.value()
    private var shiftRow: RowView?, autoRow: RowView?, levelRow: RowView?, delayRows: [RowView] = []
    private var effectRow: RowView?, saverRow: RowView?, mediaKeysRow: RowView?, disableRows: [RowView?] = []
    private var shiftOn: NSSwitch?, invert: NSSwitch?, thumb: NSSwitch?, light: NSSwitch?, auto: NSSwitch?, saver: NSSwitch?, mediaKeys: NSSwitch?
    private var disableToggles: [NSSwitch?] = []
    private var delays: [NSPopUpButton] = []
    private let effect = NSPopUpButton()
    private var keysSection: NSView?
    // An MX keyboard's picture, showing its backlight (OtherDevice.picture); the ISO one once 0x4540 says so.
    private lazy var picture: KeyPicture? = OtherDevice.picture(device).flatMap(KeyLayout.load).map(KeyPicture.init)
    private lazy var isoModel = OtherDevice.picture(device).flatMap(KeyLayout.load)?.iso()
    private lazy var backlightPicture = picture.map(BacklightPicture.init)
    private var isoShown = false, pageShown = false
    // Keys a stopped Logi Options+ left diverted are given back at the first read; what came of it shows on the status line.
    private var releasePending = false, releasedNote: String?
    // Set by an Easy-Switch, so the device's return reads it again.
    private var switched = false
    private var hosts: NSSegmentedControl?, hostsBox: NSView?
    private let revert = NSButton(title: "Revert", target: nil, action: nil)

    private var rememberedKey: String { "device." + device.settingsKey }
    private var noun: String { device.kind == "mouse" || device.kind == "keyboard" ? device.kind : "device" }

    override init(device: FoundDevice, hidpp: (() throws -> Hidpp)? = nil) {
        remembered = OtherSettings.fromText(Settings.get("device." + device.settingsKey))
        rememberedAtLoad = remembered
        super.init(device: device, hidpp: hidpp)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        var sections: [NSView] = []
        if device.has(0x8040) { sections.append(brightnessSection()) }
        if device.has(0x2201) { sections.append(pointerSection()) }
        if device.has(0x2110) || device.has(0x2111) || device.has(0x2121) { sections.append(wheelSection()) }
        if device.has(0x2150) { sections.append(thumbSection()) }
        if device.has(0x1982) { sections.append(backlightSection()) }
        if device.has(0x40A3) || device.has(0x4521) { let section = keysSectionView(); keysSection = section; sections.append(section) }
        if device.has(0x1814) { let section = easySwitchSection(); hostsBox = section; sections.append(section) }
        releasePending = device.has(0x1B04)
        revert.target = self
        revert.action = #selector(revertClicked)
        view = Rows.page(header: header, sticky: picture, sections: sections, status: status, buttons: [revert])
        header.show(device)
        refresh()
        load()
    }

    // ---- sections ----

    private func brightnessSection() -> NSView {
        let slider = Ui.slider(self, #selector(brightChanged))
        bright = slider
        return Rows.section(device.kind == "device" ? "Screens" : "Brightness", [
            Rows.row("Brightness", device.kind == "device" ? "The key screens; Logi Options+ may set it again"
                     : "Logi Options+ may set it again when it starts", Rows.slider(slider, brightValue))])
    }

    private func pointerSection() -> NSView {
        let slider = Ui.slider(self, #selector(dpiChanged))
        dpi = slider
        return Rows.section("Pointer", [Rows.row("Speed", "How far the pointer moves", Rows.slider(slider, dpiValue))])
    }

    private func wheelSection() -> NSView {
        var rows: [NSView] = []
        if device.has(0x2110) || device.has(0x2111) {
            let toggle = Ui.toggle(self, #selector(shiftToggled))
            shiftOn = toggle
            rows.append(Rows.row("SmartShift", "Ratchet to free spin when you scroll fast", toggle))
            let slider = Ui.slider(self, #selector(shiftChanged))
            slider.maxValue = 49
            shift = slider
            let row = Rows.row("Switch to free spin at", "How fast you scroll, in turns a second", Rows.slider(slider, shiftValue))
            shiftRow = row
            rows.append(row)
        }
        if device.has(0x2121) {
            let toggle = Ui.toggle(self, #selector(invertToggled))
            invert = toggle
            rows.append(Rows.row("Invert scrolling", "The wheel scrolls the other way", toggle))
        }
        return Rows.section("Scroll wheel", rows)
    }

    private func thumbSection() -> NSView {
        let toggle = Ui.toggle(self, #selector(thumbToggled))
        thumb = toggle
        return Rows.section("Thumb wheel", [Rows.row("Invert", "The thumb wheel scrolls the other way", toggle)])
    }

    private func backlightSection() -> NSView {
        let lightToggle = Ui.toggle(self, #selector(lightToggled)), autoToggle = Ui.toggle(self, #selector(autoToggled))
        light = lightToggle
        auto = autoToggle
        let slider = Ui.slider(self, #selector(levelChanged))
        level = slider
        // Plugged in, the MX Keys S's hand sensor seems off: turned on, it stays dark until a key is pressed. On battery it lights at
        // once (an owner, 2026-11).
        var rows: [NSView] = [Rows.row("Backlight", "Plugged in, the keys light up when you next type", lightToggle)]
        autoRow = Rows.row("Automatic", "Dims by itself with the room's light", autoToggle)
        levelRow = Rows.row("Level", "How bright the keys are, when not automatic", Rows.slider(slider, levelValue))
        effect.target = self; effect.action = #selector(effectPicked)
        effect.widthAnchor.constraint(equalToConstant: Rows.controlWidth).isActive = true
        effectRow = Rows.row("Effect", "Fn and the light key switch it too", effect)
        rows += [autoRow!, levelRow!, effectRow!]
        let hints = ["Fades after this long without hands near", "Fades after this long with hands near", "Fades after this long, plugged in"]
        for (index, name) in ["Hands away", "Hands near", "Plugged in"].enumerated() {
            let popup = NSPopUpButton()
            popup.tag = index
            popup.target = self
            popup.action = #selector(delayPicked)
            popup.widthAnchor.constraint(equalToConstant: Rows.controlWidth).isActive = true
            popup.setAccessibilityLabel("Fades after, " + name.lowercased())
            delays.append(popup)
            let row = Rows.row(name, hints[index], popup)
            delayRows.append(row)
            rows.append(row)
        }
        let saverToggle = Ui.toggle(self, #selector(saverToggled))
        saver = saverToggle
        saverRow = Rows.row("Battery saving", "Turns the backlight off below 10% battery", saverToggle)
        rows.append(saverRow!)
        return Rows.section("Backlight", rows)
    }

    private func keysSectionView() -> NSView {
        var rows: [NSView] = []
        if device.has(0x40A3) {
            let toggle = Ui.toggle(self, #selector(mediaKeysToggled))
            mediaKeys = toggle
            mediaKeysRow = Rows.row("F1–F12 as media keys", "Off, they type F1–F12. Fn and Esc switch it too", toggle)
            rows.append(mediaKeysRow!)
        }
        if device.has(0x4521) {
            for (index, name) in OtherDevice.disableNames.enumerated() {
                let toggle = Ui.toggle(self, #selector(disableToggled))
                toggle.tag = index
                toggle.setAccessibilityLabel("Disable " + name)
                let row = Rows.row("Disable " + name, "The key does nothing while this is on", toggle)
                disableToggles.append(toggle)
                disableRows.append(row)
                rows.append(row)
            }
        }
        return Rows.section("Keys", rows)
    }

    private var effectChoices: [Int] { OtherDevice.effectIds.filter { id in state.map { $0.effects >> id & 1 != 0 } ?? true } }

    // The keyboard's own numbers, as Logi Options+ shows them: 0 is off (an MX Mechanical Mini, 2026-11-26).
    static func levelText(_ value: Int, _ levels: Int) -> String { "\(value) of \(levels - 1)" }

    override func viewWillAppear() { super.viewWillAppear(); pageShown = true; refresh() }
    override func viewDidDisappear() { super.viewDidDisappear(); pageShown = false; refresh() }

    // After an Easy-Switch, the device's return (a scan that finds it again) reads it again.
    override func scanned() {
        if switched { switched = false; load() }
    }

    private func easySwitchSection() -> NSView {
        let picker = NSSegmentedControl(labels: ["1", "2", "3"], trackingMode: .selectOne, target: self, action: #selector(hostPicked))
        hosts = picker
        return Rows.section("Easy-Switch", [Rows.row("Computer", "Switching sends the \(noun) there", picker)])
    }

    // ---- changes ----

    @objc private func brightChanged() { change(OtherSettings.bright, bright!.integerValue) }
    @objc private func dpiChanged() {
        if let state = state, dpi!.integerValue < state.dpis.count { change(OtherSettings.dpi, state.dpis[dpi!.integerValue]) }
    }
    @objc private func shiftToggled() { change(OtherSettings.shift, shiftOn!.state == .on ? shift!.integerValue + 1 : 255) }
    @objc private func shiftChanged() { change(OtherSettings.shift, shift!.integerValue + 1) }
    @objc private func invertToggled() { change(OtherSettings.invert, invert!.state == .on ? 1 : 0) }
    @objc private func thumbToggled() { change(OtherSettings.thumb, thumb!.state == .on ? 1 : 0) }
    @objc private func lightToggled() { change(OtherSettings.light, light!.state == .on ? 1 : 0) }
    @objc private func autoToggled() { change(OtherSettings.auto, auto!.state == .on ? 1 : 0) }
    @objc private func effectPicked() {
        let choices = effectChoices
        if effect.indexOfSelectedItem >= 0 && effect.indexOfSelectedItem < choices.count { change(OtherSettings.effect, choices[effect.indexOfSelectedItem]) }
    }
    @objc private func saverToggled() { change(OtherSettings.saver, saver!.state == .on ? 1 : 0) }
    @objc private func mediaKeysToggled() { change(OtherSettings.mediaKeys, mediaKeys!.state == .on ? 1 : 0) }
    @objc private func disableToggled(_ sender: NSSwitch) {
        let bit = OtherDevice.disableBits[sender.tag]
        change(OtherSettings.disabled, sender.state == .on ? current[OtherSettings.disabled] | bit : current[OtherSettings.disabled] & ~bit)
    }
    @objc private func levelChanged() { change(OtherSettings.level, level!.integerValue) }
    @objc private func delayPicked(_ sender: NSPopUpButton) {
        let setting = OtherSettings.delays[sender.tag]
        change(setting, OtherPage.delayChoices(current[setting])[sender.indexOfSelectedItem])
    }

    private func change(_ setting: Int, _ value: Int) {
        if refreshing || state == nil || current[setting] < 0 { return }
        current[setting] = value
        if OtherPage.remembers(setting) { remembered[setting] = value }
        releasedNote = nil
        changed()
    }

    private func changed() {
        dirty = true
        sequence += 1
        edited()
        refresh()
        showApplied()
        // While a slider moves, sent at most every 120 ms rather than once it stops.
        if debounce == nil {
            debounce = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                self?.debounce = nil
                self?.send()
            }
        }
    }

    // The keyboard keeps these and changes them with its own keys (Fn and Esc, Fn and the light key): sent again at each load, they
    // would undo a change made there.
    static func remembers(_ setting: Int) -> Bool { setting != OtherSettings.effect && setting != OtherSettings.mediaKeys }

    private func showApplied() { status.show(state != nil && dirty ? "Applied to the \(noun)." : releasedNote ?? "") }

    @objc private func hostPicked() {
        guard let state = state, let hosts = hosts else { return }
        let host = hosts.selectedSegment
        hosts.selectedSegment = state.host
        if host == state.host || host < 0 { return }
        if !state.paired[host] {
            status.show("Nothing is paired on computer \(host + 1) yet. Pair it with the Easy-Switch button first.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Switch the \(noun) to \(state.names[host] ?? "computer \(host + 1)")?"
        alert.informativeText = "It leaves this Mac until you switch back"
            + (state.pairedKnown ? "." : ". If nothing is paired there, press its Easy-Switch button to come back.")
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.logAction("Switch to computer \(host + 1)")
            self.run({ try OtherDevice.switchTo($0, host) }, done: {
                // The picker shows where the device is now, until it comes back (scanned) or is read again.
                self.switched = true
                self.state?.host = host
                self.hosts?.selectedSegment = host
                self.status.show("Switched to computer \(host + 1). Press the Easy-Switch button to come back.")
            })
        }
    }

    override func presetText() -> String? { current.toText() }

    // Only what this device has, in its ranges; what the preset changes is remembered, as a change made by hand (app/OtherDevicePage.cs).
    override func applyPreset(_ text: String) {
        guard let state = state else { return }
        let preset = OtherDevice.keepSupported(OtherSettings.fromText(text), state)
        for setting in 0..<OtherSettings.count where preset[setting] >= 0 && preset[setting] != current[setting] && OtherPage.remembers(setting) {
            remembered[setting] = preset[setting]
        }
        current.merge(preset)
        changed()
    }

    override func revertWithoutPreset() { backToLoad() }

    @objc private func revertClicked() {
        if revertToPreset() { return }
        backToLoad()
    }

    private func backToLoad() {
        guard let stored = stored else { return }
        current = stored
        remembered = rememberedAtLoad
        changed()
        dirty = false
        showApplied()
        refresh()
    }

    // ---- device ----

    private func send() {
        guard let state = state else { return }
        let want = current, before = sent
        sequence += 1
        let startedAt = sequence
        var refused: [Int] = []
        run({ device in
            if startedAt != self.sequence { return }
            // What the device has now, not the snapshot: a send still running when this one was queued changes it.
            refused = try OtherDevice.apply(device, state, want, self.sent)
            var now = want
            for setting in refused { now[setting] = before[setting] }
            self.sent = now
        }, done: { if startedAt == self.sequence { self.refused(refused, before) } })
    }

    // A refused setting goes back to what the device has, and isn't remembered or sent again.
    private func refused(_ refused: [Int], _ device: OtherSettings) {
        for setting in refused { current[setting] = device[setting]; remembered[setting] = -1 }
        Settings.set(rememberedKey, remembered.toText())
        if refused.isEmpty { showApplied(); return }
        refresh()
        status.show("The \(noun) refused the " + Array(Set(refused.map(OtherDevice.name))).sorted().joined(separator: " and the ") + ".",
                    error: true)
    }

    private func load() {
        status.show("Reading the \(noun)…")
        let keep = remembered, found = device
        var read: OtherDevice.State?, before = OtherSettings(), refused: [Int] = []
        let startedAt = sequence
        let release = releasePending
        releasePending = false
        run({ device in
            if release { self.releaseIfStopped(device) }
            var state = try OtherDevice.read(device, found)
            before = state.set
            var want = state.set
            want.merge(OtherDevice.keepSupported(keep, state))
            // With Automatic on, the level follows the room's light, so the one remembered from manual mode isn't sent.
            if want[OtherSettings.auto] == 1 { want[OtherSettings.level] = state.set[OtherSettings.level] }
            if want != state.set {
                refused = try OtherDevice.apply(device, state, want, state.set)
                for setting in refused { want[setting] = before[setting] }
                state.set = want
            }
            read = state
        }, done: {
            guard let read = read else { return }
            self.state = read
            self.stored = read.set
            if startedAt == self.sequence {
                self.current = read.set
                self.sent = read.set
                self.dirty = false
            }
            self.refresh()
            self.status.show(self.releasedNote ?? "")
            if !refused.isEmpty { self.refused(refused, before) }
            self.rememberedAtLoad = self.remembered
            self.loaded()
        })
    }

    // Logi Options+ installed but not running: keys it diverted are dead until the device reconnects. Off in the demo.
    // shortcut: looks for the app in /Applications and its processes by name (logioptionsplus); Windows asks its service manager.
    static var optionsPlusStopped: () -> Bool = {
        guard FileManager.default.fileExists(atPath: "/Applications/logioptionsplus.app") else { return false }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-i", "logioptionsplus"]
        check.standardOutput = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return false }
        check.waitUntilExit()
        return check.terminationStatus != 0
    }

    // On the device's queue, since the check runs a process.
    private func releaseIfStopped(_ device: Hidpp) {
        if self.device.key.hasPrefix("demo|") || !OtherPage.optionsPlusStopped() { return }
        guard let released = try? OtherDevice.releaseDiverted(device), released > 0 else { return }
        let note = "\(released) " + (released == 1 ? "key" : "keys") + " Logi Options+ had taken over work again."
        DispatchQueue.main.async { self.releasedNote = note }
    }

    // ---- showing ----

    private func refresh() {
        refreshing = true
        defer { refreshing = false }
        let ready = state != nil
        if let bright = bright {
            let on = ready && current[OtherSettings.bright] >= 0
            bright.isEnabled = on
            bright.maxValue = Double(state?.brightMax ?? 100)
            bright.integerValue = max(0, current[OtherSettings.bright])
            brightValue.stringValue = !on ? "" : state!.brightMax == 100 ? "\(current[OtherSettings.bright])%"
                : "\(current[OtherSettings.bright]) of \(state!.brightMax)"
        }
        if let dpi = dpi {
            let on = ready && current[OtherSettings.dpi] > 0
            dpi.isEnabled = on && state!.dpis.count > 1
            dpi.maxValue = on ? Double(max(1, state!.dpis.count - 1)) : 100
            dpi.numberOfTickMarks = 0
            dpi.integerValue = on ? OtherDevice.nearest(state!.dpis, current[OtherSettings.dpi]) : 0
            dpiValue.stringValue = on ? "\(current[OtherSettings.dpi]) DPI" : ""
        }
        if let shiftOn = shiftOn, let shift = shift {
            let threshold = current[OtherSettings.shift]
            let has = ready && threshold >= 0, on = has && threshold < 255
            shiftOn.isEnabled = has
            shiftOn.state = on ? .on : .off
            shift.isEnabled = on
            shift.integerValue = max(0, min(49, (on ? threshold : state?.shiftDefault ?? 10) - 1))
            shiftRow?.enable(on)
            shiftValue.stringValue = on ? Ui.number(Double(threshold) / 4) + " turns a second" : ""
        }
        if let invert = invert {
            invert.isEnabled = ready && current[OtherSettings.invert] >= 0
            invert.state = current[OtherSettings.invert] == 1 ? .on : .off
        }
        if let thumb = thumb {
            thumb.isEnabled = ready && current[OtherSettings.thumb] >= 0
            thumb.state = current[OtherSettings.thumb] == 1 ? .on : .off
        }
        if let light = light, let auto = auto, let level = level {
            let lit = current[OtherSettings.light] == 1
            light.isEnabled = ready && current[OtherSettings.light] >= 0
            light.state = lit ? .on : .off
            auto.isEnabled = ready && current[OtherSettings.auto] >= 0 && lit
            autoRow?.enable(auto.isEnabled)
            auto.state = lit && current[OtherSettings.auto] == 1 ? .on : .off
            let manual = ready && current[OtherSettings.level] >= 0 && lit && current[OtherSettings.auto] != 1
            level.isEnabled = manual
            level.maxValue = Double(ready && state!.levels > 1 ? state!.levels - 1 : 1)
            level.integerValue = max(0, current[OtherSettings.level])
            levelRow?.enable(manual)
            levelValue.stringValue = ready && current[OtherSettings.level] >= 0 ? OtherPage.levelText(current[OtherSettings.level], state!.levels) : ""
            let choices = effectChoices, hasEffect = ready && current[OtherSettings.effect] >= 0
            effect.removeAllItems()
            effect.addItems(withTitles: choices.map { OtherDevice.effectNames[OtherDevice.effectIds.firstIndex(of: $0)!] })
            effect.selectItem(at: choices.firstIndex(of: current[OtherSettings.effect]) ?? -1)
            effect.isEnabled = hasEffect && lit
            effectRow?.enable(hasEffect && lit)
            saver?.isEnabled = ready && current[OtherSettings.saver] >= 0
            saver?.state = current[OtherSettings.saver] == 1 ? .on : .off
            // Once read, the rows the keyboard doesn't have go: on its first firmware, the MX Mechanical Mini's backlight is only on or off.
            effectRow?.isHidden = ready && !hasEffect
            saverRow?.isHidden = ready && current[OtherSettings.saver] < 0
            autoRow?.isHidden = ready && current[OtherSettings.auto] < 0
            levelRow?.isHidden = ready && current[OtherSettings.level] < 0
            for row in delayRows { row.isHidden = ready && current[OtherSettings.away] <= 0 }
            let fades = ready && current[OtherSettings.away] > 0 && lit
            for (index, popup) in delays.enumerated() {
                let seconds = current[OtherSettings.delays[index]]
                let choices = OtherPage.delayChoices(seconds)
                popup.removeAllItems()
                popup.addItems(withTitles: choices.map(OtherPage.delayText))
                popup.selectItem(at: choices.firstIndex(of: seconds) ?? -1)
                popup.isEnabled = fades
                delayRows[index].enable(fades)
            }
        }
        if let mediaKeys = mediaKeys {
            mediaKeys.isEnabled = ready && current[OtherSettings.mediaKeys] >= 0
            mediaKeys.state = current[OtherSettings.mediaKeys] == 1 ? .on : .off
            mediaKeysRow?.isHidden = ready && current[OtherSettings.mediaKeys] < 0
        }
        for (index, toggle) in disableToggles.enumerated() {
            let can = ready && current[OtherSettings.disabled] >= 0 && state!.disableable & OtherDevice.disableBits[index] != 0
            toggle?.isEnabled = can
            toggle?.state = can && current[OtherSettings.disabled] & OtherDevice.disableBits[index] != 0 ? .on : .off
            disableRows[index]?.isHidden = ready && !can
        }
        keysSection?.isHidden = ready && current[OtherSettings.mediaKeys] < 0 && current[OtherSettings.disabled] < 0
        if let picture = picture {
            if !isoShown, let iso = isoModel, ready, KeyLayout.isIso(state!.layoutCode) {
                isoShown = true
                picture.setLayout(iso)
            }
            // As bright as the level (0 is off); full when the keyboard has no levels.
            let shownLevel = current[OtherSettings.level]
            let brightness = ready && shownLevel >= 0 && state!.levels > 1 ? Double(shownLevel) / Double(state!.levels - 1) : 1
            backlightPicture?.show(on: ready && current[OtherSettings.light] == 1, level: brightness, effect: current[OtherSettings.effect],
                                   shown: pageShown)
        }
        if let hosts = hosts {
            let count = state?.hosts ?? 0
            hostsBox?.isHidden = ready && count <= 1
            let labels = count > 1 ? (0..<count).map(hostName) : ["1", "2", "3"]
            hosts.segmentCount = labels.count
            for (index, label) in labels.enumerated() { hosts.setLabel(label, forSegment: index); hosts.setWidth(0, forSegment: index) }
            hosts.isEnabled = count > 1
            hosts.selectedSegment = count > 1 ? state!.host : -1
        }
        revert.isEnabled = dirty
    }

    private func hostName(_ host: Int) -> String {
        guard let state = state else { return "\(host + 1)" }
        if host < state.paired.count && !state.paired[host] { return "\(host + 1): –" }
        if host < state.names.count, let name = state.names[host] { return "\(host + 1): \(name)" }
        return "\(host + 1)"
    }

    static let delaySteps = [5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]

    // The usual delays, with the keyboard's own when it isn't one of them.
    static func delayChoices(_ seconds: Int) -> [Int] {
        seconds <= 0 || delaySteps.contains(seconds) ? delaySteps : (delaySteps + [seconds]).sorted()
    }

    static func delayText(_ seconds: Int) -> String {
        seconds % 3600 == 0 ? "\(seconds / 3600) h" : seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }
}

// An MX keyboard's backlight on its picture (app/OtherDevicePage.cs, BacklightPicture): white, as bright as the level, with the
// keyboard's effect, as seen on an MX Mechanical Mini (2026-11-26): Contrast dims the letters, digits, F1–F4, F9–F12 and the arrows,
// Breathing fades all the keys in and out, Waves sweep from left to right, Reaction lights a key when it's pressed, Random lights keys
// at random. The speeds are guesses. Only while the screen is shown: Reaction's key presses come from an event tap, stopped with it.
final class BacklightPicture {
    private static let contrast = 3, breathing = 2, waves = 6, reaction = 4, random = 5
    private static let breathSeconds = 4.0, waveSeconds = 3.0, fadeSeconds = 1.0, twinkleSeconds = 1.5, contrastDim = 0.35, tick = 0.04
    private let picture: KeyPicture
    private var timer: Timer?
    private var presses: KeyPresses?
    private let clock = Date()
    // When each key last lit up, for Reaction and Random.
    private var litAt: [Double] = []
    private var lit = false, brightness = 0.0, effect = 0

    init(_ picture: KeyPicture) { self.picture = picture }

    deinit { timer?.invalidate(); presses?.stop() }

    func show(on: Bool, level: Double, effect newEffect: Int, shown: Bool) {
        lit = on
        brightness = level
        effect = newEffect
        let moving = shown && on && [BacklightPicture.breathing, BacklightPicture.waves, BacklightPicture.reaction, BacklightPicture.random].contains(effect)
        if moving && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: BacklightPicture.tick, repeats: true) { [weak self] _ in self?.draw() }
        }
        if !moving { timer?.invalidate(); timer = nil }
        if moving && effect == BacklightPicture.reaction && presses == nil { presses = KeyPresses() }
        if !(moving && effect == BacklightPicture.reaction) { presses?.stop(); presses = nil }
        draw()
    }

    private func draw() {
        let seconds = Date().timeIntervalSince(clock)
        if litAt.count != picture.count { litAt = [Double](repeating: -1000, count: picture.count) }
        for usage in presses?.take() ?? [] {
            var key = keyOf(usage)
            // Scan code 2B is \ on ANSI keyboards and # on ISO ones (as Echo does).
            if key < 0 && usage == 0x31 { key = keyOf(0x32) }
            if key >= 0 { litAt[key] = seconds }
        }
        picture.show((0..<picture.count).map { key in
            let value = Int(255 * (lit ? brightness * max(0, min(1, factor(key, seconds))) : 0))
            return value << 16 | value << 8 | value
        })
    }

    private func keyOf(_ usage: Int) -> Int {
        let id = KeyPresses.lightingId(usage)
        return id < 0 ? -1 : (0..<picture.count).first { picture.idOf($0) == id } ?? -1
    }

    // The key's share of the level, 0 to 1.
    private func factor(_ key: Int, _ seconds: Double) -> Double {
        switch effect {
        case BacklightPicture.contrast:
            let id = picture.idOf(key)
            // Dim, as on the Mini: letters and digits (lighting ids 01–24), the punctuation among them (2A–35 but `, and ISO's <>, 61),
            // F1–F4 and F9–F12 (37–3A, 3F–42) and the arrows (4C–4F).
            let dim = (0x01...0x24).contains(id) || ((0x2A...0x35).contains(id) && id != 0x32) || id == 0x61
                || (0x37...0x3A).contains(id) || (0x3F...0x42).contains(id) || (0x4C...0x4F).contains(id)
            return dim ? BacklightPicture.contrastDim : 1
        case BacklightPicture.breathing: return 0.5 - 0.5 * cos(2 * Double.pi * seconds / BacklightPicture.breathSeconds)
        case BacklightPicture.waves: return 0.5 + 0.5 * cos(2 * Double.pi * (picture.xOf(key) - seconds / BacklightPicture.waveSeconds))
        case BacklightPicture.reaction: return 1 - (seconds - litAt[key]) / BacklightPicture.fadeSeconds
        case BacklightPicture.random:
            var age = seconds - litAt[key]
            // About one key in six lit at a time.
            if age >= BacklightPicture.twinkleSeconds && Double.random(in: 0..<1) < BacklightPicture.tick / BacklightPicture.twinkleSeconds / 5 {
                litAt[key] = seconds
                age = 0
            }
            return age < BacklightPicture.twinkleSeconds ? sin(Double.pi * age / BacklightPicture.twinkleSeconds) : 0
        default: return 1
        }
    }
}
