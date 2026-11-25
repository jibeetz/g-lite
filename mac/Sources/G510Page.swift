import AppKit

// The G510 screen (app/G510Page.cs): Off, Static, Breathe and Cycle, a colour, brightness and speed. Live only, kept as
// lighting.<device> and set again on load; Breathe and Cycle are G-Lite's frames every 50 ms, so they stop when G-Lite quits.
final class G510Page: DevicePage {
    private var current: G510Settings?, read: G510Settings?, sent: G510Settings?
    private var ready = false, refreshing = false, framing = false, sequence = 0
    private var framed = -1
    private var pausedUntil = Date.distantPast
    private var debounce: Timer?, animation: Timer?
    private let clock = Date()

    private let effects = NSSegmentedControl(labels: G510Settings.effects, trackingMode: .selectOne, target: nil, action: nil)
    private let color = NSColorWell()
    private let bright = Ui.slider(), speed = Ui.slider(), brightValue = Ui.value(), speedValue = Ui.value()
    private let colorHead = Ui.secondary("Colour")
    private var brightHead = NSTextField(), speedHead = NSTextField()
    private let revert = NSButton(title: "Revert", target: nil, action: nil)

    private var rememberedKey: String { "lighting." + device.settingsKey }

    deinit { animation?.invalidate() }

    override func loadView() {
        current = G510Settings.fromText(Settings.get(rememberedKey))
        for control in [effects, color, bright, speed] as [NSControl] { control.target = self; control.action = #selector(changed) }
        revert.target = self; revert.action = #selector(revertClicked)
        color.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let (brightRow, brightName) = Ui.sliderRow("Brightness", bright, brightValue, width: 250)
        let (speedRow, speedName) = Ui.sliderRow("Speed", speed, speedValue, width: 250)
        brightHead = brightName
        speedHead = speedName
        let sliders = NSStackView(views: [brightRow, speedRow])
        sliders.alignment = .top
        sliders.spacing = 24
        let backlight = Ui.column([Ui.column([Ui.secondary("Effect"), effects], spacing: 4), Ui.column([colorHead, color], spacing: 4), sliders])
        let note = Ui.hint("One colour for the whole keyboard. G-Lite sets it again when it starts, and runs Breathe and Cycle itself: they "
                           + "stop when you quit G-Lite.")
        view = Ui.page(header: header, body: [Ui.box("Backlight", backlight), note], status: status, buttons: [revert])
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

    // Back to the colour the keyboard had when G-Lite read it, and nothing remembered.
    override func presetText() -> String? { current?.toText() ?? "" }

    override func applyPreset(_ text: String) {
        guard let settings = G510Settings.fromText(text) else { return }
        current = settings
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
        Settings.remove(rememberedKey)
        current = nil
        refresh()
        send(read)
    }

    private func send() {
        guard let current = current else { return }
        Settings.set(rememberedKey, current.toText())
        send(current)
    }

    // Breathe and Cycle are sent by animate, frame by frame.
    private func send(_ want: G510Settings) {
        sequence += 1
        let startedAt = sequence
        framed = -1
        pausedUntil = .distantPast
        if want.on && want.effect != G510Settings.staticEffect {
            sent = nil
            showStatus()
            return
        }
        run({ hidpp in
            if startedAt != self.sequence || want.same(self.sent) { return }
            try G510Lighting.set(hidpp, G510Lighting.frame(want, 0))
            self.sent = want
        }, done: { if startedAt == self.sequence { self.showStatus() } })
    }

    private func animate() {
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
        let want = current
        var color = -1
        run({ hidpp in
            self.sent = nil
            color = (try? G510Lighting.read(hidpp)) ?? -1
            if let want = want, color >= 0, !want.on || want.effect == G510Settings.staticEffect {
                try G510Lighting.set(hidpp, G510Lighting.frame(want, 0))
                self.sent = want
            }
        }, done: {
            self.ready = true
            self.read = color < 0 ? nil : G510Settings(on: color != 0, color: color == 0 ? 0xFFFFFF : color, bright: 100)
            self.refresh()
            self.showStatus()
            self.loaded()
        })
    }

    private func showStatus() {
        if ready && read == nil { status.show("The keyboard didn't answer. Is it plugged in?", error: true); return }
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
        color.isEnabled = hasColor
        Ui.dim(colorHead, !hasColor)
        color.color = NSColor(rgb: settings?.color ?? 0xFFFFFF)
        bright.isEnabled = lit
        Ui.dim(brightHead, !lit)
        bright.integerValue = settings?.bright ?? 100
        brightValue.stringValue = lit ? "\(settings!.bright)%" : ""
        speed.isEnabled = moving
        Ui.dim(speedHead, !moving)
        speed.doubleValue = known ? (Double(G510Settings.maxPeriod - settings!.period) * 100
            / Double(G510Settings.maxPeriod - G510Settings.minPeriod)).rounded() : 0
        speedValue.stringValue = moving ? "\(speed.integerValue)%" : ""
        revert.isEnabled = ready && current != nil && read != nil
        let animated = ready && current?.on == true && current?.effect != G510Settings.staticEffect
        if animated && animation == nil {
            animation = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.animate() }
        } else if !animated { animation?.invalidate(); animation = nil }
    }
}
