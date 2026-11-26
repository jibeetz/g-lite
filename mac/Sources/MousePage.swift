import AppKit

// The mouse screen (app/MousePage.cs): lighting and sensitivity sent live, Save to mouse writes the active onboard profile after a
// backup, and the Backups menu restores one or the factory profile. The Bindings view sets the buttons, saved with the profile; the
// mouse's own DPI button and profile changes are followed (0x8100 events).
final class MousePage: DevicePage {
    private let mouse: MouseDriver
    private var current = MouseSettings(), stored: MouseSettings?, sent: MouseSettings?
    private var state: MouseProtocol.State?
    private var refreshing = false, dirty = false, lightSet = false, sequence = 0
    private var note = ""
    private var debounce: Timer?, watch: Timer?

    private let effects = NSSegmentedControl(labels: MouseProtocol.effects.map { $0.name }, trackingMode: .selectOne, target: nil, action: nil)
    private let color = NSColorWell()
    private let bright = Ui.slider(), speed = Ui.slider(), dpi = Ui.slider()
    private let brightValue = Ui.value(), speedValue = Ui.value(), dpiValue = Ui.value()
    private var lightHead = NSTextField(), colorHead = Ui.secondary("Colour"), brightHead = NSTextField(), speedHead = NSTextField()
    private let stages = NSSegmentedControl(labels: ["–"], trackingMode: .selectOne, target: nil, action: nil)
    private let rates = NSSegmentedControl(labels: ["–"], trackingMode: .selectOne, target: nil, action: nil)
    private let stageHead = Ui.secondary("DPI stage"), rateHead = Ui.secondary("Report rate"), rateHint = Ui.hint("")
    private let invert = Ui.toggle()
    private var invertRow = NSView()
    private let save = NSButton(title: "Save to mouse", target: nil, action: nil)
    private let revert = NSButton(title: "Revert", target: nil, action: nil)
    private let backups = NSButton(title: "Backups", target: nil, action: nil)

    // The Bindings view (app/MousePage.cs and app/Buttons.cs, ButtonRows): a row per button with what it does, Keystroke… recording
    // the next keys, and the button spy (0x8110) lighting the row of the button pressed.
    private let viewPick = NSSegmentedControl(labels: ["Settings", "Bindings"], trackingMode: .selectOne, target: nil, action: nil)
    private var settingsRow = NSView(), bindingsBox = NSView()
    private let buttonRows = ButtonRows(actions: Bindings.mouseActions)
    private var pressedRow = -1
    private var pressedTimer: Timer?
    private var spy: (Port, Reader)?
    private var showingButtons = false
    private let picture = MousePicture()
    private var pictureBox = NSView()

    private var backupId: String { device.settingsKey }
    private var invertKey: String { "wheel.invert." + device.settingsKey }
    private var lightKey: String { "lighting." + device.settingsKey }

    init(device: FoundDevice, hidpp: (() throws -> Hidpp)?, mouse: MouseDriver) {
        self.mouse = mouse
        super.init(device: device, hidpp: hidpp)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for control in [effects, stages, rates] as [NSControl] { control.target = self }
        effects.action = #selector(effectPicked)
        stages.action = #selector(stagePicked)
        rates.action = #selector(ratePicked)
        color.target = self; color.action = #selector(colorPicked)
        for (slider, action) in [(bright, #selector(brightMoved)), (speed, #selector(speedMoved)), (dpi, #selector(dpiMoved))] {
            slider.target = self; slider.action = action
        }
        invert.target = self; invert.action = #selector(invertToggled)
        save.target = self; save.action = #selector(saveClicked); save.keyEquivalent = "\r"
        revert.target = self; revert.action = #selector(revertClicked)
        backups.target = self; backups.action = #selector(showBackups)
        color.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let (brightRow, brightName) = Ui.sliderRow("Brightness", bright, brightValue, width: 230)
        let (speedRow, speedName) = Ui.sliderRow("Speed", speed, speedValue, width: 230)
        let (dpiRow, _) = Ui.sliderRow("DPI", dpi, dpiValue, width: 230)
        brightHead = brightName
        speedHead = speedName
        lightHead = Ui.secondary("")
        invertRow = Ui.toggleRow("Invert scrolling", invert)
        // The two boxes are as tall as the taller one: a spacer at the bottom of each takes the extra height, which otherwise went
        // to whichever row the stack picked.
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(.init(1), for: .vertical)
            return view
        }
        let lighting = Ui.column([lightHead, Ui.column([Ui.secondary("Effect"), effects], spacing: 4),
                                  Ui.column([colorHead, color], spacing: 4), brightRow, speedRow, spacer()])
        let sensitivity = Ui.column([Ui.column([stageHead, stages], spacing: 4), dpiRow,
                                     Ui.column([rateHead, rates, rateHint], spacing: 4), invertRow, spacer()])
        let left = Ui.box("Lighting", lighting), right = Ui.box("Sensitivity", sensitivity)
        let row = NSStackView(views: [left, right])
        row.alignment = .top
        row.distribution = .fillEqually
        left.heightAnchor.constraint(equalTo: right.heightAnchor).isActive = true
        let upper = device.name.uppercased()
        // Whole words: PRO, not the G102 Prodigy.
        picture.pro = upper.range(of: "\\bPRO\\b", options: .regularExpression) != nil
        picture.dex = upper.range(of: "\\bDEX\\b", options: .regularExpression) != nil
        picture.g502 = upper.contains("G502")
        pictureBox = Ui.box("Live on the mouse", picture)
        picture.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        let settings = Ui.column([pictureBox, row], spacing: 18)
        for view in [pictureBox, row] { view.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true }
        settingsRow = settings
        viewPick.target = self; viewPick.action = #selector(viewPicked)
        viewPick.selectedSegment = 0
        buttonRows.assigned = { [weak self] row, binding in self?.assign(row, binding) }
        bindingsBox = Ui.box("Buttons", buttonRows)
        bindingsBox.isHidden = true
        view = Ui.page(header: header, body: [settings, bindingsBox], status: status, buttons: [backups, revert, save])
        header.show(device)
        // The mouse forgets inverted scrolling when it turns off, so it's checked every 5 s while kept on.
        watch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.keepInverted() }
        refresh()
        load()
    }

    deinit { watch?.invalidate() }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopSpy()
        buttonRows.stopRecording()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if showingButtons { startSpy() }
    }

    // ---- the mouse's own buttons ----

    // 0x8100 event fn 0 is a new active profile (read it all again), fn 1 a new DPI stage from the mouse's DPI button (MyHUB,
    // docs/research/more-references.md). A G305 sends 0x1D4B (wireless device status) event 0 when it wakes up and wants its light
    // again, as Solaar re-applies its settings (app/MousePage.cs, Heard and Reconnected).
    override func heard(_ report: [UInt8]) {
        guard let state = state, report.count >= 4 else { return }
        let feature = report[2], fn = Int(report[3] >> 4)
        if device.lightIsLiveOnly && fn == 0 && feature != state.profilesFeature { reconnected(feature); return }
        guard state.profilesFeature != 0, feature == state.profilesFeature else { return }
        if fn == 0 { load(); return }
        if fn != 1 { return }
        let startedAt = sequence
        var read: (Int, Int) = (0, -1)
        queue.async {
            guard let hidpp = try? self.connection(), let now = try? MouseProtocol.readDpiAndStage(hidpp, state) else { return }
            read = now
            DispatchQueue.main.async {
                guard startedAt == self.sequence, read.0 != 0 else { return }
                self.current.dpi = read.0; self.current.stage = read.1
                self.sent?.dpi = read.0; self.sent?.stage = read.1
                self.stored?.dpi = read.0; self.stored?.stage = read.1
                self.refresh()
            }
        }
    }

    // The index is looked up only now, so the mouse's read sends nothing more.
    private func reconnected(_ feature: UInt8) {
        guard let kept = keptLight(), let state = state, !state.zones.isEmpty else { return }
        queue.async {
            guard let hidpp = try? self.connection(), (try? hidpp.featureIndex(0x1D4B)) == feature else { return }
            if let label = hidpp.deviceLabel { Log.add(label, "found", "woke up (wireless status event)") }
            try? self.mouse.setLight(hidpp, state, kept)
        }
    }

    // ---- bindings ----

    // At the right of the preset row, as on the keyboards.
    override var headerAccessory: NSView? { viewPick }

    @objc private func viewPicked() { showView(buttons: viewPick.selectedSegment == 1) }

    // For --snapshot.
    func showBindings() { showView(buttons: true) }

    private func showView(buttons: Bool) {
        showingButtons = buttons
        buttonRows.stopRecording()
        settingsRow.isHidden = buttons
        bindingsBox.isHidden = !buttons
        if buttons { startSpy() } else { stopSpy() }
        viewPick.selectedSegment = buttons ? 1 : 0
        syncButtons()
    }

    private var buttonCount: Int { min(state?.buttonCount ?? 0, current.buttons?.count ?? 0) }

    private func syncButtons() {
        let count = state?.buttons == nil ? 0 : buttonCount
        buttonRows.show(names: Bindings.names(device, count), bindings: (0..<count).map { current.buttons?[$0] },
                        editable: state?.savable == true, pressed: pressedRow,
                        note: spy != nil ? "Press a button on the mouse to find it." : state?.savable == true ? "" : "This mouse's buttons can't be saved.")
        viewPick.isHidden = count == 0
        if count == 0 && showingButtons { showView(buttons: false) }
    }

    private func assign(_ row: Int, _ binding: [UInt8]) {
        guard state != nil, current.buttons != nil, row < current.buttons!.count else { return }
        current.buttons![row] = binding
        dirty = true
        edited()
        refresh()
        showStatus()
    }

    // 0x8110: fn 1 starts, fn 2 stops; while on, the mouse sends event fn 0 with a big-endian bitmap, bit n = profile slot n (checked
    // on the G502 LIGHTSPEED). It only reports: the buttons keep working.
    private func startSpy() {
        guard spy == nil, device.has(0x8110), let port = device.port else { return }
        let index = device.index
        run({ hidpp in
            let feature = try hidpp.featureIndex(0x8110)
            try hidpp.call(feature, 1)
            DispatchQueue.main.async {
                guard self.showingButtons, self.spy == nil, let reader = try? port.reader() else { return }
                reader.heard = { [weak self] report in
                    guard report.count >= 6, report[1] == index, report[2] == feature, report[3] == 0x00 else { return }
                    let bits = Int(report[4]) << 8 | Int(report[5])
                    DispatchQueue.main.async { self?.pressed(bits) }
                }
                self.spy = (port, reader)
                self.syncButtons()
            }
        })
    }

    private func stopSpy() {
        guard let (port, reader) = spy else { return }
        port.remove(reader)
        spy = nil
        queue.async { if let hidpp = try? self.connection() { _ = try? hidpp.call(try hidpp.featureIndex(0x8110), 2) } }
    }

    private func pressed(_ bits: Int) {
        guard bits != 0, let first = (0..<16).first(where: { bits >> $0 & 1 != 0 }) else { return }
        pressedRow = first
        pressedTimer?.invalidate()
        pressedTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.pressedRow = -1
            self?.syncButtons()
        }
        syncButtons()
    }

    private var light: MouseLight {
        get { current.light ?? MouseLight() }
        set { current.light = newValue }
    }

    // ---- edits ----

    private var shownEffects: [EffectInfo] { state?.effects ?? mouse.effects }

    @objc private func effectPicked() {
        guard effects.selectedSegment >= 0, effects.selectedSegment < shownEffects.count else { return }
        let effect = shownEffects[effects.selectedSegment]
        var edited = light
        edited.effect = effect.id
        if effect.speed && (edited.period < effect.minPeriod || edited.period > effect.maxPeriod) { edited.period = effect.defaultPeriod }
        light = edited
        changed(now: true)
    }
    @objc private func colorPicked() { light.color = color.color.rgb; changed(now: false) }
    @objc private func brightMoved() { light.bright = max(1, bright.integerValue); changed(now: false) }
    @objc private func speedMoved() {
        guard let effect = MouseProtocol.effect(light.effect), effect.speed else { return }
        light.period = effect.maxPeriod - Int((Double(effect.maxPeriod - effect.minPeriod) * speed.doubleValue / 100).rounded())
        changed(now: false)
    }
    @objc private func stagePicked() {
        guard let state = state, stages.selectedSegment >= 0, stages.selectedSegment < state.stages.count else { return }
        current.stage = stages.selectedSegment
        current.dpi = state.stages[current.stage]
        changed(now: true)
    }
    @objc private func dpiMoved() {
        guard let state = state, !state.dpis.isEmpty else { return }
        current.dpi = state.dpis[min(state.dpis.count - 1, dpi.integerValue)]
        changed(now: false)
    }
    @objc private func ratePicked() {
        guard let state = state, rates.selectedSegment >= 0, rates.selectedSegment < state.rates.count else { return }
        let hz = state.rates[rates.selectedSegment]
        current.rate = hz
        // Without onboard profiles the rate is set live; with them it waits for the save.
        if !state.onboard { run({ try self.mouse.setRate($0, hz) }, done: { self.load() }); return }
        changed(now: true)
    }
    @objc private func invertToggled() {
        guard state != nil else { return }
        let on = invert.state == .on
        Settings.set(invertKey, on ? "1" : "0")
        logAction(on ? "Invert scrolling" : "Normal scrolling")
        run({ try self.mouse.setInvert($0, on) }, done: { self.state?.inverted = on; self.refresh() })
    }

    private func changed(now: Bool) {
        if refreshing || state == nil || state!.readOnly { return }
        dirty = true
        sequence += 1
        edited()
        refresh()
        showStatus()
        // While a slider moves, sent at most every 120 ms rather than once it stops.
        if now { debounce?.invalidate(); debounce = nil; send() }
        else if debounce == nil {
            debounce = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in self?.debounce = nil; self?.send() }
        }
    }

    override func presetText() -> String? { current.toText() }

    // A preset's buttons fill in from the profile's, and without a Left click the first button gets it back; its DPI is the nearest the
    // mouse takes, at the stage that has it (app/MousePage.cs, ApplyPreset).
    override func applyPreset(_ text: String) {
        guard let state = state, !state.readOnly, var settings = MouseSettings.fromText(text) else { return }
        let saved = stored?.buttons ?? current.buttons
        if current.buttons == nil { settings.buttons = nil }
        else if settings.buttons == nil { settings.buttons = saved }
        else if let saved = saved { settings.buttons = saved.indices.map { $0 < settings.buttons!.count ? settings.buttons![$0] : saved[$0] } }
        if let buttons = settings.buttons, !Bindings.hasLeft(buttons, state.buttonCount), !buttons.isEmpty { settings.buttons![0] = Bindings.leftClick }
        if !state.dpis.isEmpty { settings.dpi = state.dpis[OtherDevice.nearest(state.dpis, settings.dpi)] }
        settings.stage = state.stages.firstIndex(of: settings.dpi) ?? current.stage
        current = settings
        changed(now: true)
    }

    override func revertWithoutPreset() { backToStored() }

    override var keepable: Bool {
        current.buttons == nil || Bindings.hasLeft(current.buttons, state?.buttonCount ?? 0) || !Bindings.hasLeft(stored?.buttons, state?.buttonCount ?? 0)
    }

    @objc private func revertClicked() {
        if revertToPreset() { return }
        backToStored()
    }

    private func backToStored() {
        guard let stored = stored else { return }
        current = stored
        changed(now: true)
        dirty = lightSet && stored.light == nil
        refresh()
        showStatus()
    }

    // ---- device ----

    private func send() {
        guard let state = state else { return }
        let want = current, before = sent, liveOnly = device.lightIsLiveOnly
        sequence += 1
        let startedAt = sequence
        run({ hidpp in
            if startedAt != self.sequence { return }
            try self.mouse.sendDpi(hidpp, state, want, before)
            if let light = want.light, !state.zones.isEmpty, before?.light != light {
                try self.mouse.setLight(hidpp, state, light)
                self.lightSet = !liveOnly && light != state.light
            }
            self.sent = want
        }, done: {
            if startedAt != self.sequence { return }
            if liveOnly, let light = want.light { self.keep(light) }
            self.showStatus()
        })
    }

    private func keepInverted() {
        guard Settings.get(invertKey) == "1", state?.canInvert == true else { return }
        queue.async { if let hidpp = try? self.connection() { try? MouseProtocol.setInvert(hidpp, true) } }
    }

    // A mouse that ignores the profile's lighting (the G305): G-Lite keeps it as lighting.<device>, and it's no change to save.
    private func keep(_ light: MouseLight) {
        if light != keptLight() { Settings.set(lightKey, light.toText()) }
        guard stored != nil else { return }
        stored!.light = light
        if current.dpi == stored!.dpi && current.stage == stored!.stage && current.rate == stored!.rate { dirty = false }
        refresh()
    }

    private func keptLight() -> MouseLight? { MouseLight.fromText(Settings.get(lightKey)) }

    @objc private func saveClicked() {
        guard let state = state else { return }
        var want = current
        if device.lightIsLiveOnly { want.light = nil }
        debounce?.invalidate(); debounce = nil
        save.isEnabled = false
        status.show("Saving to the mouse…")
        logAction("Save to mouse")
        run({ hidpp in
            if state.fresh { try self.mouse.setup(hidpp, state, want); return }
            let now = try self.mouse.readProfile(hidpp, state)
            if !MousePage.intact(state, now) { throw GLiteError.refused("The profile on the mouse is damaged, not touching it") }
            try Backups.save(self.backupId, data: [state.key: now], who: self.device.shortName)
            try self.mouse.save(hidpp, state, now, want)
        }, done: {
            self.lightSet = false
            self.note = "Saved to the mouse"
            self.load()
        })
    }

    private func restore(_ data: [UInt8]?, _ what: String) {
        guard let state = state, state.writable, !state.fresh else { return }
        debounce?.invalidate(); debounce = nil
        sequence += 1
        save.isEnabled = false
        status.show("Restoring \(what)…")
        logAction("Restore \(what)")
        run({ hidpp in
            let now = try self.mouse.readProfile(hidpp, state)
            try Backups.save(self.backupId, data: [state.key: now], who: self.device.shortName)
            try self.mouse.restore(hidpp, state, now, data)
        }, done: {
            self.lightSet = false
            self.note = "Restored \(what)"
            self.load()
        })
    }

    // A backup that can go back on this mouse: the same sector, the right size, a checksum that checks.
    private func usable(_ entry: Backups.Entry) -> [UInt8]? {
        guard let state = state, let data = entry.data[state.key] ?? nil else { return nil }
        return state.writable && data.count == state.sectorSize && MousePage.intact(state, data) ? data : nil
    }

    // A profile G-Lite may write over: one whose CRC checks, or on a mouse with nothing live (the G300's report, no CRC) one of the
    // right size.
    static func intact(_ state: MouseProtocol.State, _ data: [UInt8]) -> Bool {
        state.saveOnly ? data.count == state.sectorSize : MouseProtocol.valid(data)
    }

    @objc private func showBackups() {
        let menu = NSMenu()
        if let state = state, state.writable && !state.fresh && mouse.hasFactory {
            menu.addItem(withTitle: "Restore the factory profile", action: #selector(restoreFactory), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let entries = Backups.list(backupId)
        if entries.isEmpty {
            menu.addItem(withTitle: "No backups yet: one is made before each save", action: nil, keyEquivalent: "").isEnabled = false
        }
        let format = DateFormatter()
        format.dateStyle = .medium
        format.timeStyle = .short
        for (index, entry) in entries.enumerated() {
            let data = state.flatMap { entry.data[$0.key] ?? nil }
            let item = NSMenuItem(title: format.string(from: entry.when) + ": " + (data.map(mouse.describe) ?? "another profile")
                                  + (entry.first ? " (the first)" : ""),
                                  action: usable(entry) != nil ? #selector(restoreBackup) : nil, keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show backups folder", action: #selector(showFolder), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: backups.bounds.height + 4), in: backups)
    }

    @objc private func restoreFactory() { confirm("Restore the factory profile?") { self.restore(nil, "the factory profile") } }

    @objc private func restoreBackup(_ sender: NSMenuItem) {
        let entries = Backups.list(backupId)
        guard sender.tag < entries.count, let data = usable(entries[sender.tag]) else { return }
        let when = DateFormatter.localizedString(from: entries[sender.tag].when, dateStyle: .medium, timeStyle: .short)
        confirm("Restore the backup from \(when)?") { self.restore(data, "the backup from \(when)") }
    }

    @objc private func showFolder() {
        let folder = Backups.folder(backupId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func confirm(_ question: String, _ then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "The profile on the mouse is backed up first."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { then() } }
    }

    private func load() {
        debounce?.invalidate(); debounce = nil
        status.show("Reading the mouse…")
        var read: MouseProtocol.State?
        let startedAt = sequence
        run({ read = try self.mouse.read($0) }, done: {
            guard let read = read else { return }
            self.state = read
            let start = read.stage >= 0 ? read.stage
                : read.profile != nil && !read.stages.isEmpty ? min(self.mouse.defaultStage(read.profile!), read.stages.count - 1) : -1
            var stored = MouseSettings(dpi: read.dpi, rate: read.rate, stage: start, light: read.light, buttons: read.buttons)
            if startedAt == self.sequence {
                self.current.dpi = read.dpi
                self.current.rate = read.rate
                self.current.stage = start
                self.current.buttons = read.buttons
                if !self.lightSet || self.current.light == nil { self.current.light = read.light }
                if !self.lightSet { self.dirty = false }
                let kept = self.device.lightIsLiveOnly && !read.zones.isEmpty ? self.keptLight() : nil
                if let kept = kept { self.current.light = kept; stored.light = kept }
                self.sent = MouseSettings(dpi: read.dpi, stage: start, light: self.lightSet ? self.current.light : read.light)
                if kept != nil { self.sent!.light = nil }
            }
            self.stored = stored
            self.refresh()
            self.showStatus()
            if self.note != "" { self.status.show(self.note); self.note = "" }
            if self.sent?.light == nil && self.current.light != nil && self.device.lightIsLiveOnly { self.send() }
            self.loaded()
        })
    }

    // ---- showing ----

    private func showStatus() {
        guard let state = state else { status.show(""); return }
        if !state.profileOk {
            status.show("The profile saved on the mouse is damaged. Restore a backup or the factory profile from Backups.", error: true)
            return
        }
        if state.readOnly { status.show("Read only: G-Lite shows this mouse's settings but can't change them yet"); return }
        if let buttons = current.buttons, !Bindings.hasLeft(buttons, state.buttonCount), Bindings.hasLeft(stored?.buttons, state.buttonCount) {
            status.show("No button is set to Left click. Set one to save.", error: true)
            return
        }
        let rate = stored != nil && state.onboard && current.rate > 0 && current.rate != stored!.rate
        // A format 6 to 8 mouse only takes its stages' DPI, so an edited stage waits for the save.
        // On a mouse with nothing live (the G300) everything does, the picked stage and the lighting too.
        let dpiWaits = (MouseProtocol.State.wideFormat(state.format) || state.saveOnly) && state.savable && current.stage >= 0
            && current.stage < state.stages.count
            && (current.dpi != state.stages[current.stage] || (state.saveOnly && current.stage != stored?.stage))
        let lightWaits = state.saveOnly && current.light != nil && current.light != stored?.light
        let buttons = stored != nil && current.buttons != stored!.buttons
        let waiting = (dpiWaits ? ["DPI"] : []) + (lightWaits ? ["lighting"] : []) + (buttons ? ["buttons"] : []) + (rate ? ["report rate"] : [])
        if dirty && !waiting.isEmpty {
            let text = waiting.joined(separator: " and ")
            status.show(text.prefix(1).uppercased() + text.dropFirst() + (waiting.count == 1 && !buttons ? " changes" : " change") + " when saved to the mouse")
            return
        }
        // Only formats 2 and 3 get their LED records written; on formats 4 to 8 a light set stays live.
        let liveLight = state.savable && !state.flash && !state.saveOnly && !state.zones.isEmpty && !MouseProtocol.State.knownFormat(state.format)
            && stored != nil && current.light != nil && current.light != stored!.light
        status.show(!dirty ? "Matches the mouse"
                    : liveLight ? "Lighting applied to the mouse; Save to mouse doesn't keep it on this mouse"
                    : state.savable ? "Applied to the mouse, not saved on it yet" : "Applied to the mouse, not saved on it")
    }

    private func refresh() {
        refreshing = true
        defer { refreshing = false }
        syncButtons()
        let ready = state != nil
        let info = current.light.flatMap { MouseProtocol.effect($0.effect) }
        let lit = ready && !state!.zones.isEmpty, known = lit && info != nil, live = ready && !state!.readOnly
        // The G300 (saveOnly) has no brightness: each colour is on or off.
        let hasColor = known && info!.color, hasSpeed = known && info!.speed, hasBrightness = known && light.effect != 0 && !state!.saveOnly
        lightHead.stringValue = !ready || lit
            ? (current.light == nil && lit ? "As saved on the mouse" : device.lightIsLiveOnly ? "Live only: the mouse doesn't save it" : "")
            : device.has(0x8071) ? "Not supported yet on this mouse" : "This mouse has no lighting G-Lite can set"
        lightHead.isHidden = lightHead.stringValue.isEmpty
        effects.segmentCount = shownEffects.count
        for (index, info) in shownEffects.enumerated() { effects.setLabel(info.name, forSegment: index); effects.setWidth(0, forSegment: index) }
        effects.isEnabled = lit && live
        effects.selectedSegment = known ? shownEffects.firstIndex { $0.id == light.effect } ?? -1 : -1
        Ui.dim(colorHead, !hasColor)
        color.isEnabled = hasColor && live
        color.color = NSColor(rgb: light.color)
        Ui.dim(brightHead, !hasBrightness)
        bright.isEnabled = hasBrightness && live
        bright.integerValue = light.bright
        brightValue.stringValue = hasBrightness ? "\(light.bright)%" : ""
        Ui.dim(speedHead, !hasSpeed)
        speed.isEnabled = hasSpeed && live
        if hasSpeed {
            speed.doubleValue = (Double(info!.maxPeriod - light.period) * 100 / Double(info!.maxPeriod - info!.minPeriod)).rounded()
        }
        speedValue.stringValue = hasSpeed ? "\(speed.integerValue)%" : ""

        let hasStages = ready && !state!.stages.isEmpty
        let stage = !hasStages ? -1 : !state!.writable ? state!.stages.firstIndex(of: current.dpi) ?? -1
            : current.stage >= 0 && current.stage < state!.stages.count ? current.stage : -1
        var shown = hasStages ? state!.stages : []
        if stage >= 0 && state!.writable { shown[stage] = current.dpi }
        let labels = hasStages ? shown.map { "\($0)" } : ["–"]
        stages.segmentCount = labels.count
        for (index, label) in labels.enumerated() { stages.setLabel(label, forSegment: index); stages.setWidth(0, forSegment: index) }
        stages.isEnabled = hasStages && live
        stages.selectedSegment = stage
        Ui.dim(stageHead, !hasStages)
        dpi.isEnabled = live && !state!.dpis.isEmpty
        dpi.maxValue = Double(max(1, (state?.dpis.count ?? 2) - 1))
        dpi.integerValue = ready && !state!.dpis.isEmpty ? OtherDevice.nearest(state!.dpis, current.dpi) : 0
        dpiValue.stringValue = ready ? "\(current.dpi)" : ""
        let rateOn = live && !state!.rates.isEmpty && (!state!.onboard || state!.savable)
        let rate = ready ? (current.rate > 0 ? current.rate : state!.rate) : 0
        let rateLabels = ready && !state!.rates.isEmpty ? state!.rates.map { $0 >= 1000 ? "\($0 / 1000)k" : "\($0)" } : ["–"]
        rates.segmentCount = rateLabels.count
        for (index, label) in rateLabels.enumerated() { rates.setLabel(label, forSegment: index); rates.setWidth(0, forSegment: index) }
        rates.selectedSegment = ready ? state!.rates.firstIndex(of: rate) ?? -1 : -1
        rates.isEnabled = rateOn
        Ui.dim(rateHead, !rateOn)
        rateHead.stringValue = "Report rate" + (ready && !state!.rates.isEmpty ? " (Hz)" : "")
            + (ready && state!.onboard && state!.savable ? ", on save" : "")
        rateHint.stringValue = !ready || state!.readOnly || !state!.onboard || state!.savable ? "" : "Set by the saved profile."
        rateHint.isHidden = rateHint.stringValue.isEmpty
        invertRow.isHidden = !(ready && state!.canInvert)
        invert.state = ready && state!.inverted ? .on : .off
        let keepable = current.buttons == nil || Bindings.hasLeft(current.buttons, state?.buttonCount ?? 0)
            || !Bindings.hasLeft(stored?.buttons, state?.buttonCount ?? 0)
        save.isEnabled = ready && state!.savable && dirty && keepable
        save.isHidden = ready ? !state!.writable : false
        backups.isHidden = ready && !state!.writable && !mouse.hasFactory
        let stageText = stage >= 0 && ready ? "Stage \(stage + 1) of \(state!.stages.count)"
            + (current.dpi != state!.stages[stage] ? ", was \(state!.stages[stage])" : "") : ""
        let rateText = rate > 0 ? "\(rate) Hz report rate" + (ready && rate != state!.rate ? " after saving" : "") : ""
        picture.display(lit ? current.light : MouseLight(effect: 0), dpi: ready ? current.dpi : 0, stage: stageText, rate: rateText)
        revert.isEnabled = dirty
    }
}
