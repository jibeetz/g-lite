import AppKit

// The Litra screen (app/LightPage.cs): the front light, and on the Beam LX the back light. The front light isn't set on load; the
// back light is kept as lighting.<device> once changed and set again on load. Breathe, Cycle and Wave are G-Lite's frames, every
// 50 ms: they keep running with the window closed and stop when G-Lite quits.
// The live picture shows the light as set; Try effect sends one of the light's own 0x8071 effects, to learn what each does, until
// Back to G-Lite's colours or any change.
final class LightPage: DevicePage {
    private let back: Bool
    private var current: LightState?, sent: LightState?
    private var lumens = LightRange(min: 30, max: 400, step: 1), kelvins = LightRange(min: 2700, max: 6500, step: 100)
    private var refreshing = false, colorsChosen = false, framing = false, sequence = 0
    private var picked = 0
    private var debounce: Timer?, animation: Timer?
    private var framed: [Int]?
    private let clock = Date()
    private let picture = LightPicture()
    private let tryNote = Ui.hint("")
    private let tryButton = NSButton(title: "Try effect", target: nil, action: nil)
    private var liveBox = NSView()
    // The 0x8071 groups and their effects, read at load on a light that has 0x8071; trying while one of them runs.
    private var groups: [[UInt8]]?, trying = false, tried = ""

    private let frontOn = Ui.toggle(), backOn = Ui.toggle()
    private let lumen = Ui.slider(), kelvin = Ui.slider(), level = Ui.slider(), speed = Ui.slider()
    private let lumenValue = Ui.value(), kelvinValue = Ui.value(), levelValue = Ui.value(), speedValue = Ui.value()
    private let effects = NSSegmentedControl(labels: LightState.effects + ["Screen"], trackingMode: .selectOne, target: nil, action: nil)
    // The Screen effect on the back light, as on Windows: seven columns of the screen, one per zone (screen.on.<device>=1).
    private var screenKey: String { "screen.on." + device.settingsKey }
    private var screening: Bool { back && Settings.get(screenKey) == "1" }
    private var setupKey: String { "screen." + device.settingsKey }
    private lazy var screenBox: ScreenBox = {
        let box = ScreenBox(setup: follower.setup, brightness: false) { ScreenSettings.columns("").zones }
        box.changed = { [weak self] setup in
            guard let self = self else { return }
            Settings.set(self.setupKey, setup.toText())
            self.follower.setup = setup
            self.edited()
        }
        return box
    }()
    private lazy var screenArea: NSView = Ui.box("Screen", screenBox)
    private lazy var follower = ScreenFollower(setup: ScreenSettings.columns(Settings.get(setupKey))) { [weak self] colors in self?.sendScreen(colors) }
    private let zonePicker = NSSegmentedControl(labels: ["All"] + (1...LightState.zones).map { "\($0)" }, trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let color = NSColorWell()
    private var speedHead = NSTextField(), zoneHead = Ui.secondary("Zone"), colorHead = Ui.secondary("Colour")

    private var rememberedKey: String { "lighting." + device.settingsKey }

    override init(device: FoundDevice, hidpp: (() throws -> Hidpp)?) {
        back = device.has(0x8081)
        super.init(device: device, hidpp: hidpp)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { animation?.invalidate() }

    override func loadView() {
        for control in [frontOn, backOn, lumen, kelvin, level, speed, effects, zonePicker, color] as [NSControl] {
            control.target = self
            control.action = #selector(changed)
        }
        zonePicker.selectedSegment = 0
        color.widthAnchor.constraint(equalToConstant: 60).isActive = true
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.alignment = .top
            stack.spacing = 24
            return stack
        }
        let front = Ui.column([
            Ui.toggleRow("On", frontOn),
            row([Ui.sliderRow("Brightness", lumen, lumenValue, width: 250).0,
                 Ui.sliderRow("Colour temperature", kelvin, kelvinValue, width: 250).0]),
        ])
        picture.picked = { [weak self] zone in
            guard let self = self, self.zonePicker.isEnabled else { return }
            self.picked = zone
            self.refresh()
        }
        tryNote.isHidden = true
        liveBox = Ui.box("Live on the light", Ui.column([tryNote, picture], spacing: 6))
        var body = [liveBox, Ui.box("Front light", front)]
        if back {
            let (speedRow, head) = Ui.sliderRow("Speed", speed, speedValue, width: 250)
            speedHead = head
            tryButton.target = self; tryButton.action = #selector(tryMenu)
            tryButton.setAccessibilityLabel("Try the light's own effects")
            tryButton.isHidden = !device.has(0x8071)
            let backColumn = Ui.column([
                row([Ui.toggleRow("On", backOn), tryButton]),
                row([Ui.sliderRow("Brightness", level, levelValue, width: 250).0, speedRow]),
                row([Ui.column([Ui.secondary("Effect"), effects], spacing: 4), Ui.column([zoneHead, zonePicker], spacing: 4),
                     Ui.column([colorHead, color], spacing: 4)]),
            ])
            body.append(Ui.box("Back light", backColumn))
        }
        if back { body.append(screenArea) }
        view = Ui.page(header: header, body: body, status: status, buttons: [])
        header.show(device)
        refresh()
        load()
    }

    // ---- edits ----

    @objc private func changed(_ sender: NSControl) {
        guard !refreshing, var light = current else { return }
        if sender === zonePicker { picked = max(0, zonePicker.selectedSegment); refresh(); return }
        endTrying()
        if sender === frontOn { light.frontOn = frontOn.state == .on }
        if sender === lumen { light.lumen = lumens.snap(lumens.min + (lumens.max - lumens.min) * lumen.integerValue / 100) }
        if sender === kelvin { light.kelvin = kelvins.snap(kelvins.min + kelvin.integerValue * kelvins.step) }
        if sender === backOn { light.backOn = backOn.state == .on }
        if sender === level { light.backLevel = max(1, level.integerValue) }
        if sender === speed {
            light.period = LightState.maxPeriod - Int((Double(LightState.maxPeriod - LightState.minPeriod) * speed.doubleValue / 100).rounded())
        }
        if sender === effects && effects.selectedSegment == LightState.effects.count {
            Settings.set(screenKey, "1")
            follower.start()
            edited()
            refresh()
            showStatus()
            return
        }
        if sender === effects && screening {
            Settings.remove(screenKey)
            follower.stop()
            // Every zone is sent again.
            sent?.colors = [Int](repeating: -1, count: LightState.zones)
        }
        if sender === effects { light.effect = max(0, effects.selectedSegment); colorsChosen = true }
        if sender === color {
            colorsChosen = true
            for zone in 0..<LightState.zones where picked == 0 || picked == zone + 1 { light.colors[zone] = color.color.rgb }
        }
        current = light
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

    // ---- device ----

    private func send() {
        guard let want = current, let before = sent else { return }
        let colorsToo = colorsChosen
        if back && (!Settings.get(rememberedKey).isEmpty || colorsToo || want.backOn != before.backOn || want.backLevel != before.backLevel) {
            Settings.set(rememberedKey, want.backText())
        }
        sequence += 1
        let startedAt = sequence
        run({ hidpp in
            if startedAt != self.sequence { return }
            try self.apply(hidpp, want, colorsToo: colorsToo)
        }, done: { if startedAt == self.sequence { self.showStatus() } })
    }

    private func apply(_ hidpp: Hidpp, _ want: LightState, colorsToo: Bool) throws {
        guard let was = sent else { return }
        if was.frontOn != want.frontOn { try LitraProtocol.setFrontOn(hidpp, want.frontOn) }
        if was.lumen != want.lumen { try LitraProtocol.set(hidpp, 4, want.lumen) }
        if was.kelvin != want.kelvin { try LitraProtocol.set(hidpp, 9, want.kelvin) }
        var now = want
        if back {
            if was.backOn != want.backOn { try LitraProtocol.setBackOn(hidpp, want.backOn) }
            if was.backLevel != want.backLevel { try LitraProtocol.setBackLevel(hidpp, want.backLevel) }
            if colorsToo && want.effect == LightState.staticEffect && was.colors != want.colors { try LitraProtocol.colors(hidpp, want.colors) }
        }
        // An animated effect's colours are sent frame by frame (animate), so they count as not sent.
        if !colorsToo || want.effect != LightState.staticEffect {
            now.colors = colorsToo ? [Int](repeating: -1, count: LightState.zones) : was.colors
        }
        sent = now
    }

    // The Windows text: front:<on,lumen,kelvin>;back:<on,level,colours,effect,period>, then the Screen effect after "|". Its areas
    // aren't set on a Mac, so a Windows setup after it is left out.
    override func presetText() -> String? {
        guard let light = current else { return "" }
        return "front:" + light.frontText() + (back ? ";back:" + light.backText() : "") + (screening ? "|" + follower.setup.toText() : "")
    }

    override func applyPreset(_ text: String) {
        guard var next = current else { return }
        endTrying()
        let pieces = text.components(separatedBy: "|")
        for part in pieces[0].components(separatedBy: ";") {
            if part.hasPrefix("front:") { _ = next.readFront(String(part.dropFirst(6))) }
            if part.hasPrefix("back:") && back { _ = next.readBack(String(part.dropFirst(5))) }
        }
        next.lumen = lumens.snap(next.lumen)
        next.kelvin = kelvins.snap(next.kelvin)
        let screen = back && pieces.count > 1
        if screen {
            screenBox.setup = ScreenSettings.columns(pieces[1])
            follower.setup = screenBox.setup
            Settings.set(setupKey, screenBox.setup.toText())
        }
        if screening && !screen { Settings.remove(screenKey); follower.stop(); sent?.colors = [Int](repeating: -1, count: LightState.zones) }
        if screen && !screening { Settings.set(screenKey, "1"); follower.start() }
        colorsChosen = true
        current = next
        sequence += 1
        refresh()
        send()
    }

    private func sendScreen(_ colors: [Int]) {
        queue.async { if let hidpp = try? self.connection() { try? LitraProtocol.colors(hidpp, colors, quiet: true) } }
        showStatus()
    }

    override func giveBack() { follower.stop() }

    private func animate() {
        guard let light = current, light.effect != LightState.staticEffect, !screening, !trying else { return }
        let frame = LitraProtocol.frame(light, Date().timeIntervalSince(clock) * 1000)
        show(frame)
        if framing || frame == framed { return }
        framing = true
        queue.async {
            defer { DispatchQueue.main.async { self.framing = false } }
            guard let hidpp = try? self.connection(), (try? LitraProtocol.colors(hidpp, frame, quiet: true)) != nil else { return }
            DispatchQueue.main.async { self.framed = frame }
        }
    }

    private func load() {
        status.show("Reading the light…")
        var remembered = LightState()
        let hasRemembered = back && remembered.readBack(Settings.get(rememberedKey))
        var read = LightState(), readLumens = lumens, readKelvins = kelvins, readGroups: [[UInt8]]?
        let canTry = back && device.has(0x8071), wasTrying = trying
        run({ hidpp in
            if wasTrying { LitraProtocol.release(hidpp) }
            readLumens = try LitraProtocol.lumens(hidpp)
            readKelvins = try LitraProtocol.kelvins(hidpp)
            read.frontOn = try LitraProtocol.frontOn(hidpp)
            read.lumen = try LitraProtocol.get(hidpp, 3)
            read.kelvin = try LitraProtocol.get(hidpp, 8)
            if self.back {
                read.backLevel = max(1, min(100, try LitraProtocol.backLevel(hidpp)))
                read.backOn = try LitraProtocol.backOn(hidpp) ?? true
                read.colors = [Int](repeating: -1, count: LightState.zones)
                if canTry { readGroups = try? G915Lighting.clusters(hidpp).clusters }
            }
            self.sent = read
            if hasRemembered {
                var want = read
                want.backOn = remembered.backOn; want.backLevel = remembered.backLevel; want.colors = remembered.colors
                want.effect = remembered.effect; want.period = remembered.period
                try self.apply(hidpp, want, colorsToo: true)
                read = want
            }
        }, done: {
            if hasRemembered { self.colorsChosen = true }
            self.lumens = readLumens
            self.kelvins = readKelvins
            if readGroups != nil { self.groups = readGroups }
            self.trying = false
            if read.colors.contains(where: { $0 < 0 }) { read.colors = [Int](repeating: 0xFFFFFF, count: LightState.zones) }
            self.current = read
            self.framed = nil
            if self.screening { self.follower.start() }
            self.refresh()
            self.showStatus()
            self.loaded()
        })
    }

    // ---- showing ----

    private func show(_ zones: [Int]?) {
        guard let light = current else {
            picture.display(back: back, frontOn: false, front: 0, kelvin: 4000, backOn: false, level: 0, colors: nil, selected: -1)
            return
        }
        let zoned = light.effect == LightState.staticEffect || light.effect == LightState.breathe
        picture.display(back: back, frontOn: light.frontOn, front: Double(light.lumen - lumens.min) / Double(max(1, lumens.max - lumens.min)),
                        kelvin: light.kelvin, backOn: light.backOn && !trying, level: Double(light.backLevel) / 100,
                        colors: zones ?? light.colors, selected: zoned && !screening && !trying ? picked : -1)
    }

    // ---- Try effect ----

    @objc private func tryMenu() {
        guard let groups = groups else { return }
        let menu = NSMenu()
        for (group, ids) in groups.enumerated() {
            for (index, id) in ids.enumerated() {
                let item = NSMenuItem(title: "Group \(group): " + LitraProtocol.effectName(id), action: #selector(tryPicked), keyEquivalent: "")
                item.target = self
                item.representedObject = [group, index, Int(id)]
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Back to G-Lite's colours", action: #selector(stopTrying), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: tryButton.bounds.height + 4), in: tryButton)
    }

    @objc private func tryPicked(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [Int], values.count == 3, let state = current else { return }
        let name = sender.title
        trying = true
        tried = name
        refresh()
        logAction("Try effect " + name)
        run({ hidpp in try LitraProtocol.tryEffect(hidpp, values[0], values[1], UInt8(values[2]), state) },
            done: { self.status.show("Sent \(name). What lit up? Please say in your issue.") })
    }

    @objc private func stopTrying() {
        guard current != nil else { return }
        logAction("Back to G-Lite's colours")
        endTrying()
        colorsChosen = true
        refresh()
        send()
    }

    // Every way out of Try effect gives back the software control it took, so G-Lite's own colours show again.
    private func endTrying() {
        if !trying { return }
        trying = false
        framed = nil
        // Every zone is sent again, after the release (the queue keeps the order).
        sent?.colors = [Int](repeating: -1, count: LightState.zones)
        queue.async { if let hidpp = try? self.connection() { LitraProtocol.release(hidpp) } }
    }

    private func showStatus() {
        if screening {
            status.show(follower.problem ?? "Screen effect: G-Lite runs it, so it stops if you quit G-Lite", error: follower.problem != nil)
            return
        }
        if back, let light = current, light.effect != LightState.staticEffect {
            status.show(LightState.effects[light.effect] + ": G-Lite runs it, so it stops if you quit G-Lite")
            return
        }
        status.show(back && !Settings.get(rememberedKey).isEmpty ? "Back light set by G-Lite, not saved to the light" : "")
    }

    private func refresh() {
        refreshing = true
        defer { refreshing = false }
        let ready = current != nil
        for control in [frontOn, lumen, kelvin, backOn, level, effects] as [NSControl] { control.isEnabled = ready }
        if let light = current {
            frontOn.state = light.frontOn ? .on : .off
            lumen.integerValue = (light.lumen - lumens.min) * 100 / max(1, lumens.max - lumens.min)
            lumenValue.stringValue = "\(light.lumen) lm"
            kelvin.maxValue = Double(max(1, (kelvins.max - kelvins.min) / kelvins.step))
            kelvin.integerValue = (light.kelvin - kelvins.min) / kelvins.step
            kelvinValue.stringValue = "\(light.kelvin) K"
            backOn.state = light.backOn ? .on : .off
            level.integerValue = light.backLevel
            levelValue.stringValue = "\(light.backLevel)%"
            effects.selectedSegment = screening ? LightState.effects.count : light.effect
            speed.doubleValue = (Double(LightState.maxPeriod - light.period) * 100 / Double(LightState.maxPeriod - LightState.minPeriod)).rounded()
            color.color = NSColor(rgb: light.colors[picked == 0 ? 0 : picked - 1])
        }
        // Static and Breathe have a colour per zone; Cycle and Wave run through every hue.
        let zoned = ready && !screening && (current!.effect == LightState.staticEffect || current!.effect == LightState.breathe)
        let moving = ready && !screening && current!.effect != LightState.staticEffect
        zonePicker.isEnabled = zoned
        zonePicker.selectedSegment = picked
        color.isEnabled = zoned
        Ui.dim(zoneHead, !zoned)
        Ui.dim(colorHead, !zoned)
        speed.isEnabled = moving
        Ui.dim(speedHead, !moving)
        speedValue.stringValue = moving ? "\(speed.integerValue)%" : ""
        if back { screenArea.isHidden = !screening; screenBox.showing(screening) }
        // The Screen effect has its own box with the screen, so the light's picture goes, as on Windows.
        liveBox.isHidden = back && screening
        tryButton.isEnabled = ready && !screening && groups != nil
        tryNote.stringValue = "Trying \(tried): look at the light"
        tryNote.isHidden = !trying
        if let light = current, light.effect == LightState.staticEffect || screening { show(light.colors) } else if current == nil { show(nil) }
        let animated = back && moving
        if animated && animation == nil {
            animation = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.animate() }
        } else if !animated { animation?.invalidate(); animation = nil }
    }
}
