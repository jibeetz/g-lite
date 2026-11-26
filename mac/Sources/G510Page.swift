import AppKit

// The G510 screen (app/G510Page.cs): Off, Static, Breathe and Cycle, a colour, brightness and speed. Live only, kept as
// lighting.<device> and set again on load; Breathe and Cycle are G-Lite's frames every 50 ms, so they stop when G-Lite quits.
// M1 to M3 (the footer) each have their own lighting and G key bindings, as in LGS; the Bindings view sets G1 to G18 (kept, not acted
// on yet) and the Game view shows the Game mode switch.
final class G510Page: DevicePage {
    // Each M key's lighting, nil until one is picked (the keyboard's colour as read is shown then).
    private var lights = [G510Settings?](repeating: nil, count: G510Keys.banks)
    private var bank = 0
    private var current: G510Settings? {
        get { lights[bank] }
        set { lights[bank] = newValue }
    }
    private var read: G510Settings?, sent: G510Settings?
    private var answered = false
    private var ready = false, refreshing = false, framing = false, sequence = 0
    private var framed = -1
    private var pausedUntil = Date.distantPast
    private var debounce: Timer?, animation: Timer?
    private let clock = Date()

    private let effects = NSSegmentedControl(labels: G510Settings.effects, trackingMode: .selectOne, target: nil, action: nil)
    private let color = NSColorWell()
    private let bright = Ui.slider(), speed = Ui.slider(), brightValue = Ui.value(), speedValue = Ui.value()
    private var effectRow: RowView!, colorRow: RowView!, brightRow: RowView!, speedRow: RowView!
    private let revert = NSButton(title: "Revert", target: nil, action: nil)
    private let picture = KeyLayout.load("g510.json").map { KeyPicture($0) }
    private var lightingSection = NSView(), savingSection = NSView(), keysSection = NSView(), gameSection = NSView()
    private let views = ["Settings", "Bindings", "Game"]
    private lazy var viewPick = NSSegmentedControl(labels: views, trackingMode: .selectOne, target: self, action: #selector(viewPicked))
    private var openView = 0
    private let bankPicker = NSSegmentedControl(labels: ["M1", "M2", "M3"], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var gKeys = (0..<G510Keys.banks).map { G510Keys.fromText(Settings.get(gKeysSetting($0))) }
    private let buttonRows = ButtonRows(actions: Bindings.keyboardActions)
    private let gameState = Ui.label("")

    // M1's is where the one lighting was kept before the M keys had their own.
    private func remembered(_ set: Int) -> String { "lighting." + device.settingsKey + (set == 0 ? "" : ".m\(set + 1)") }
    private func gKeysSetting(_ set: Int) -> String { "gkeys." + device.settingsKey + ".m\(set + 1)" }

    deinit { animation?.invalidate() }

    override func loadView() {
        lights = (0..<G510Keys.banks).map { G510Settings.fromText(Settings.get(remembered($0))) }
        for control in [effects, color, bright, speed] as [NSControl] { control.target = self; control.action = #selector(changed) }
        revert.target = self; revert.action = #selector(revertClicked)
        effectRow = Rows.row("Effect", "What the lighting does", effects)
        colorRow = Rows.row("Color", "One color for the whole keyboard", color)
        brightRow = Rows.row("Brightness", "How bright the keys are", Rows.slider(bright, brightValue))
        speedRow = Rows.row("Speed", "How fast the effect moves", Rows.slider(speed, speedValue))
        lightingSection = Rows.section("Lighting", [effectRow, colorRow, brightRow, speedRow])
        savingSection = Rows.section("Saving", [Rows.note("G-Lite can't save to this keyboard yet. It keeps your lighting and sets it again "
                                                          + "when G-Lite starts and when you open this screen.")])
        bankPicker.target = self; bankPicker.action = #selector(bankPicked)
        bankPicker.setAccessibilityLabel("M key")
        buttonRows.assigned = { [weak self] row, binding in
            guard let self = self else { return }
            self.gKeys[self.bank][row] = binding
            Settings.set(self.gKeysSetting(self.bank), G510Keys.toText(self.gKeys[self.bank]))
            self.logAction("\(G510Keys.names[row]) in M\(self.bank + 1): " + Bindings.describe(binding))
            self.refresh()
        }
        keysSection = Rows.section("G keys", [buttonRows])
        gameState.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        gameSection = Rows.section("Game mode", [
            Rows.note("While its Game mode switch is on, the keyboard turns off its Windows keys itself. There are no other keys to pick."),
            Rows.row("Game mode switch", "Read from the keyboard when this view opens", gameState)])
        view = Rows.page(header: header, sticky: picture, sections: [lightingSection, savingSection, keysSection, gameSection],
                         status: status, buttons: [bankPicker, revert])
        header.show(device)
        refresh()
        load()
    }

    @objc private func changed(_ sender: NSControl) {
        guard !refreshing, ready else { return }
        var settings = current ?? read ?? G510Settings()
        if sender === effects {
            settings.on = effects.selectedSegment > 0
            if settings.on { settings.effect = effects.selectedSegment - 1 }
        }
        if sender === color { settings.color = color.color.rgb }
        if sender === bright { settings.bright = max(1, bright.integerValue) }
        if sender === speed {
            settings.period = G510Settings.maxPeriod
                - Int((Double(G510Settings.maxPeriod - G510Settings.minPeriod) * speed.doubleValue / 100).rounded())
        }
        current = settings
        sequence += 1
        edited()
        refresh()
        // While a slider moves, sent at most every 120 ms rather than once it stops.
        if sender is NSSlider || sender === color {
            if debounce == nil {
                debounce = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in self?.debounce = nil; self?.send() }
            }
        } else { debounce?.invalidate(); debounce = nil; send() }
    }

    override var headerAccessory: NSView? { viewPick }

    @objc private func viewPicked() {
        openView = max(0, viewPick.selectedSegment)
        buttonRows.stopRecording()
        refresh()
        guard openView == 2 else { return }
        var state = "Unknown"
        run({ hidpp in
            do { state = try G510Keys.gameMode(hidpp) ? "On" : "Off" } catch GLiteError.io {}
        }, done: { self.gameState.stringValue = state })
    }

    // For --snapshot.
    func showView(_ index: Int) { viewPick.selectedSegment = index; viewPicked() }

    // The M key's own lighting, sent with its light lit (feature 0x04, as LGS did); the G keys follow in the Bindings view.
    @objc private func bankPicked() {
        let index = bankPicker.selectedSegment
        if index < 0 || index == bank { return }
        bank = index
        buttonRows.stopRecording()
        logAction("M\(bank + 1)")
        refresh()
        if !ready { return }
        run({ try G510Keys.lightBank($0, index) })
        send()
    }

    // Every M key's lighting, so picking another M key doesn't change the preset.
    override func presetText() -> String? {
        lights.allSatisfy { $0 == nil } ? "" : lights.map { $0?.toText() ?? "" }.joined(separator: "|")
    }

    // A preset from before the M keys had their own lighting holds one: M1's, where it was kept. An empty one has none.
    override func applyPreset(_ text: String) {
        let pieces = text.components(separatedBy: "|")
        if pieces.count == 1 && !text.isEmpty {
            guard let settings = G510Settings.fromText(text) else { return }
            lights[0] = settings
        } else {
            lights = (0..<G510Keys.banks).map { $0 < pieces.count ? G510Settings.fromText(pieces[$0]) : nil }
        }
        sequence += 1
        refresh()
        send()
    }

    override func revertWithoutPreset() { backToRead() }

    @objc private func revertClicked() {
        if revertToPreset() { return }
        backToRead()
    }

    private func backToRead() {
        guard let read = read else { return }
        current = nil
        keepLights()
        refresh()
        send(read)
    }

    private func keepLights() {
        for (set, light) in lights.enumerated() {
            if let light = light { Settings.set(remembered(set), light.toText()) } else { Settings.remove(remembered(set)) }
        }
    }

    // An M key without its own lighting goes back to the colour read.
    private func send() {
        keepLights()
        if let want = current ?? read { send(want) }
    }

    // Breathe and Cycle are sent by animate, frame by frame.
    private func send(_ want: G510Settings) {
        sequence += 1
        let startedAt = sequence
        framed = -1
        pausedUntil = .distantPast
        if want.on && want.effect != G510Settings.staticEffect {
            run({ _ in self.sent = nil }, done: { if startedAt == self.sequence { self.showStatus() } })
            return
        }
        run({ hidpp in
            if startedAt != self.sequence || want.same(self.sent) { return }
            try G510Lighting.set(hidpp, G510Lighting.frame(want, 0))
            self.sent = want
        }, done: { if startedAt == self.sequence { self.showStatus() } })
    }

    // Every backlit key in the colour the keyboard shows, Breathe and Cycle frame by frame.
    private func showFrame() {
        guard let picture = picture else { return }
        let settings = current ?? read
        let frame = ready && settings != nil ? G510Lighting.frame(settings!, Date().timeIntervalSince(clock) * 1000) : 0
        picture.show((0..<picture.count).map { picture.idOf($0) >= 0 ? frame : 0 })
    }

    private func animate() {
        showFrame()
        guard let current = current, current.on, current.effect != G510Settings.staticEffect, !framing, Date() >= pausedUntil else { return }
        let frame = G510Lighting.frame(current, Date().timeIntervalSince(clock) * 1000)
        if frame == framed { return }
        framing = true
        queue.async {
            var failure: Error?
            do { try G510Lighting.set(try self.connection(), frame, quiet: true) } catch { failure = error }
            DispatchQueue.main.async {
                self.framing = false
                guard let failure = failure else { self.framed = frame; return }
                // A refused frame would otherwise fail, and be logged, 20 times a second.
                self.framed = -1
                self.pausedUntil = Date().addingTimeInterval(10)
                self.status.show("The keyboard refused the effect's colours: \(failure)", error: true)
            }
        }
    }

    private func load() {
        status.show("Reading the keyboard…")
        let wanted = lights
        var color = -1, lit = bank
        run({ hidpp in
            self.sent = nil
            // Starts on the M key the keyboard has lit.
            lit = (try? G510Keys.litBank(hidpp, lit)) ?? lit
            color = (try? G510Lighting.read(hidpp)) ?? -1
            if let want = wanted[lit], color >= 0, !want.on || want.effect == G510Settings.staticEffect {
                try G510Lighting.set(hidpp, G510Lighting.frame(want, 0))
                self.sent = want
            }
        }, done: {
            self.ready = true
            self.bank = lit
            self.answered = color >= 0
            // Only the first: later loads read what G-Lite set, which would pass one M key's colour to another.
            if self.read == nil && self.answered {
                self.read = G510Settings(on: color != 0, color: color == 0 ? 0xFFFFFF : color, bright: 100)
            }
            self.refresh()
            self.showStatus()
            self.loaded()
        })
    }

    private func showStatus() {
        if ready && !answered { status.show("The keyboard didn't answer. Is it plugged in?", error: true); return }
        status.show(current == nil ? "" : "Set by G-Lite, not saved to the keyboard")
    }

    private func refresh() {
        refreshing = true
        defer { refreshing = false }
        let settings = current ?? read
        let known = ready && settings != nil, lit = known && settings!.on
        let hasColor = lit && settings!.effect != G510Settings.cycle, moving = lit && settings!.effect != G510Settings.staticEffect
        effects.isEnabled = ready
        effects.selectedSegment = known ? (settings!.on ? settings!.effect + 1 : 0) : -1
        effectRow.enable(ready)
        effectRow.hint.stringValue = moving ? "Drawn by G-Lite: it stops when you quit G-Lite" : "What the lighting does"
        color.isEnabled = hasColor
        colorRow.enable(hasColor)
        color.color = NSColor(rgb: settings?.color ?? 0xFFFFFF)
        bright.isEnabled = lit
        brightRow.enable(lit)
        bright.integerValue = lit ? settings!.bright : 0
        brightValue.stringValue = lit ? "\(settings!.bright)%" : ""
        speed.isEnabled = moving
        speedRow.enable(moving)
        speed.doubleValue = moving ? (Double(G510Settings.maxPeriod - settings!.period) * 100
            / Double(G510Settings.maxPeriod - G510Settings.minPeriod)).rounded() : 0
        speedValue.stringValue = moving ? "\(speed.integerValue)%" : ""
        revert.isEnabled = ready && current != nil && read != nil
        for part in [lightingSection, savingSection] { part.isHidden = openView != 0 }
        keysSection.isHidden = openView != 1
        gameSection.isHidden = openView != 2
        viewPick.selectedSegment = openView
        bankPicker.selectedSegment = bank
        buttonRows.show(names: G510Keys.names, bindings: gKeys[bank], editable: true, note: "Not working yet: G-Lite doesn't read the G keys yet")
        showFrame()
        let animated = ready && current?.on == true && current?.effect != G510Settings.staticEffect
        if animated && animation == nil {
            animation = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.animate() }
        } else if !animated { animation?.invalidate(); animation = nil }
    }
}
