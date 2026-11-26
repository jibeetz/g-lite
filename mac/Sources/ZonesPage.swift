import AppKit

// The screen of the G560 speakers and the 0x8070 keyboards (app/ZonesPage.cs): All or one zone, the effects that zone lists, sent
// live, kept as lighting.<device> and set again at each load. Nothing is saved on the device.
// The G512 and G513 (0x8080, experimental) add G-Lite's live effects, drawn key by key every 40 ms, on All only, with the keyboard's own
// effect set to Off first, since a running 0x8070 effect would draw over them (OpenLogi); intensity stays at each effect's default.
// Game mode keys through 0x4522, on a keyboard with a lighting-id picture (the G413, G512 and G513), in their own view.
final class ZonesPage: DevicePage {
    private let keyboard: Bool
    private let count: Int
    private var zones: [[Int: Int]]?
    private var monochrome = false
    private var current: [MouseLight?]?
    private var sent: [MouseLight?]
    // The zones the zone row lists after All (with the G213's areas, the whole-keyboard zone is what All sets).
    private var shownZones: [Int] = []
    private var picked = 0, sequence = 0
    private var refreshing = false, wholeAgain = false
    private var debounce: Timer?

    private let zonePicker = NSSegmentedControl(labels: ["All"], trackingMode: .selectOne, target: nil, action: nil)
    private let effect = NSPopUpButton(), color = NSColorWell(), direction = NSPopUpButton()
    private let speed = Ui.slider(), bright = Ui.slider()
    private let brightValue = Ui.value(), speedValue = Ui.value()
    private var rows: [String: RowView] = [:]
    private var shownEffects: [UInt8] = []
    private lazy var layout = KeyLayout.forZones(device)
    private lazy var picture = layout.map(KeyPicture.init)
    // The G560's, in the keyboards' picture place; framed: the screen's colours last sent, while the Screen effect runs.
    private lazy var speakers: SpeakerPicture? = keyboard ? nil : SpeakerPicture()
    private var framed: [Int]?
    private var frameTimer: Timer?
    // The Screen effect, on the speakers only, as on Windows: the four corners of the screen, one per zone (screen.on.<device>=1).
    private var screenKey: String { "screen.on." + device.settingsKey }
    private var screening: Bool { !keyboard && Settings.get(screenKey) == "1" }
    private var setupKey: String { "screen." + device.settingsKey }
    private lazy var screenBox: ScreenBox = {
        let box = ScreenBox(setup: follower.setup, brightness: true, lit: "the lights") { ScreenSettings.corners("").zones }
        box.changed = { [weak self] setup in
            guard let self = self else { return }
            Settings.set(self.setupKey, setup.toText())
            self.follower.setup = setup
            self.edited()
        }
        return box
    }()
    private lazy var follower = ScreenFollower(setup: ScreenSettings.corners(Settings.get(setupKey))) { [weak self] colors in self?.sendScreen(colors) }
    private let clock = Date()
    // The Audio effect (ZoneLighting.audio), on a keyboard: the level rises at once and falls at 1.6 a second, sent in 50 steps, all
    // again every 2 s.
    private var audioTimer: Timer?
    private var audioLevel = 0.0, audioClock = 0.0, audioSent = -1, audioRefresh = Date.distantPast, framing = false
    private var audioProblem: String?
    // Tried on the G413 (2026-11-22, per Windows); the G512 and G513 aren't.
    private lazy var game = GameKeys(device, supported: keyboard && picture != nil && layout?.zones != true && device.has(0x4522),
                                     experimental: !device.shortName.uppercased().hasPrefix("G413"))
    private lazy var gameBox: GameModeBox? = layout.flatMap { layout in game.map { game in
        GameModeBox(layout: layout, game: game, page: self, note: (game.experimental ? "Experimental, not tried on this keyboard yet. " : "")
            + "Select the keys you want to disable while gaming (Fn+F8 turns Game mode on). Changes apply immediately and can be saved in "
            + "your G-Lite presets, but not in the keyboard's memory.")
    } }
    private var lightingSection = NSView(), savingSection = NSView()
    private let viewPick = NSSegmentedControl(labels: ["Settings", "Game"], trackingMode: .selectOne, target: nil, action: nil)
    private var showingGame = false
    private lazy var perKey = keyboard && picture != nil && layout?.zones != true && device.has(0x8080)
    private var liveTimer: Timer?
    private var animation: LiveEffect?, animationId: UInt8 = 0, keyField: KeyField?
    private var liveStart = Date(), lastLiveFrame = 0.0, nextLiveRefresh = Date.distantPast
    private var sentKeys: [Int: Int]?, liveClaimed = false, liveProblem: String?

    private var noun: String { keyboard ? "keyboard" : "speakers" }
    private var rememberedKey: String { "lighting." + device.settingsKey }

    override init(device: FoundDevice, hidpp: (() throws -> Hidpp)?) {
        keyboard = device.kind == "keyboard"
        count = keyboard ? 6 : 4
        sent = [MouseLight?](repeating: nil, count: count)
        super.init(device: device, hidpp: hidpp)
        current = ZoneLighting.fromText(Settings.get(rememberedKey), count)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        zonePicker.target = self; zonePicker.action = #selector(zonePicked)
        zonePicker.selectedSegment = 0
        effect.autoenablesItems = false
        direction.addItems(withTitles: ZoneLighting.directionNames)
        for control in [effect, direction] as [NSControl] { control.target = self; control.action = #selector(changed) }
        for slider in [speed, bright] { slider.target = self; slider.action = #selector(changed) }
        color.target = self; color.action = #selector(changed)
        for popup in [effect, direction] { popup.widthAnchor.constraint(equalToConstant: Rows.controlWidth).isActive = true }
        if !keyboard {
            shownZones = Array(0..<count)
            setZoneLabels(["All"] + ZoneLighting.names)
        }
        rows["zone"] = Rows.row("Zone", "", zonePicker)
        rows["effect"] = Rows.row("Effect", "What the lighting does", effect)
        rows["color"] = Rows.row("Color", "The effect's color", color)
        rows["direction"] = Rows.row("Direction", "Which way the effect moves", direction)
        rows["bright"] = Rows.row("Brightness", "How bright the lights are", Rows.slider(bright, brightValue))
        rows["speed"] = Rows.row("Speed", "How fast the effect moves", Rows.slider(speed, speedValue))
        var lightRows: [NSView] = [rows["zone"]!, rows["effect"]!]
        if !keyboard { lightRows += screenBox.rows }
        lightRows += ["color", "direction", "bright", "speed"].map { rows[$0]! }
        if !keyboard { lightRows += screenBox.pauseRows }
        lightingSection = Rows.section("Lighting", lightRows)
        let saving = Rows.section("Saving", [Rows.note("G-Lite can't save to " + (keyboard ? "this keyboard" : "these speakers")
            + " yet. It keeps your lighting and sets it again when G-Lite starts and when you open this screen.")])
        savingSection = saving
        viewPick.target = self; viewPick.action = #selector(viewPicked)
        viewPick.selectedSegment = 0
        if let speakers = speakers {
            speakers.heightAnchor.constraint(equalToConstant: 150).isActive = true
            speakers.picked = { [weak self] zone in
                guard let self = self, self.zonePicker.isEnabled, let at = self.shownZones.firstIndex(of: zone) else { return }
                self.picked = at + 1
                self.refresh()
            }
        }
        let pictures: [NSView] = (picture.map { [$0] } ?? []) + (speakers.map { [$0] } ?? []) + (gameBox.map { [$0.picture] } ?? [])
        view = Rows.page(header: header, sticky: pictures.isEmpty ? nil : Rows.sticky(pictures),
                         sections: [lightingSection, saving] + (gameBox.map { [$0.section] } ?? []), status: status, buttons: [])
        if picture != nil || speakers != nil {
            frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                if self?.view.window?.isVisible == true { self?.showFrame() }
            }
        }
        header.show(device)
        refresh()
        load()
    }

    private func setZoneLabels(_ labels: [String]) {
        zonePicker.segmentCount = labels.count
        for (index, label) in labels.enumerated() { zonePicker.setLabel(label, forSegment: index); zonePicker.setWidth(0, forSegment: index) }
    }

    private var zone: Int { picked == 0 || picked > shownZones.count ? 0 : shownZones[picked - 1] }

    private func isArea(_ zone: Int) -> Bool {
        guard let zones = zones, zone < zones.count else { return false }
        return ZoneLighting.isArea(zones[zone][ZoneLighting.place] ?? 0)
    }

    // An area showing zone 0's effect, which it can't take itself, is shown and edited as Static.
    private func own(_ zone: Int, _ light: MouseLight?) -> MouseLight? {
        guard var light = light, zone != 0, let zones = zones, zone < zones.count, isArea(zone), zones[zone][Int(light.effect)] == nil else {
            return light
        }
        light.effect = 0x01
        return light
    }

    private var displayed: MouseLight? { current.flatMap { own(zone, $0[zone]) } }

    // On a per-key keyboard Audio is the per-key one, which shares its id with ZoneLighting.audio.
    private func info(_ id: UInt8) -> EffectInfo? { live(id) ? LiveEffects.info(id) : ZoneLighting.effect(id) }
    private func live(_ id: UInt8) -> Bool { perKey && id != 0xFE && LiveEffects.isLive(id) }
    private var running: Bool { (current?.first ?? nil).map { live($0.effect) } ?? false }

    // ---- edits ----

    @objc private func zonePicked() { picked = max(0, zonePicker.selectedSegment); refresh() }

    @objc private func changed(_ sender: NSControl) {
        guard !refreshing else { return }
        // The Screen effect can be turned off before the speakers answer.
        if sender === effect && !keyboard {
            if effect.indexOfSelectedItem == shownEffects.count { if zones != nil { startScreen(); edited() }; return }
            if screening { stopScreen() }
        }
        guard let zones = zones else { edited(); refresh(); return }
        func change(_ light: inout MouseLight) {
            if sender === effect, effect.indexOfSelectedItem >= 0 {
                let id = shownEffects[effect.indexOfSelectedItem]
                if let info = info(id), id != light.effect {
                    // A live effect's period means something else (Rain's fall, Aurora's turn), so crossing starts at the new default.
                    let crossed = live(light.effect) != live(id)
                    light.effect = id
                    if crossed { light.period = info.speed ? info.defaultPeriod : 0 }
                    if info.speed && (light.period < info.minPeriod || light.period > info.maxPeriod) { light.period = info.defaultPeriod }
                    if live(id) { light.direction = LiveEffects.defaultDirection(id) }
                }
            }
            if sender === color { light.color = color.color.rgb }
            if sender === bright { light.bright = max(1, bright.integerValue) }
            if sender === speed, let info = info(light.effect), info.speed {
                light.period = info.maxPeriod - Int((Double(info.maxPeriod - info.minPeriod) * speed.doubleValue / 100).rounded())
            }
            if sender === direction, direction.indexOfSelectedItem >= 0 { light.direction = ZoneLighting.directions[direction.indexOfSelectedItem] }
        }
        var lights = current ?? [MouseLight?](repeating: MouseLight(), count: count)
        if picked == 0 {
            wholeAgain = true
            var all = lights[0] ?? MouseLight()
            change(&all)
            lights = [MouseLight?](repeating: all, count: count)
        } else {
            var one = own(zone, lights[zone]) ?? MouseLight()
            change(&one)
            lights[zone] = one
            // On the G213, setting one area ends the whole keyboard's effect on all of them (docs/G213.md): the areas that followed it
            // get its colour.
            if isArea(zone) {
                for area in 0..<min(zones.count, count) where area != zone && isArea(area)
                    && (lights[area] == nil || zones[area][Int(lights[area]!.effect)] == nil) {
                    var follow = lights[0] ?? MouseLight()
                    follow.effect = follow.effect == 0 ? 0 : 0x01
                    lights[area] = follow
                }
            }
        }
        current = lights
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

    // The Windows text: one light per zone (ZoneLighting.toText), then the speakers' Screen effect after "|". Its areas aren't set on
    // a Mac, so a Windows setup after it is left out.
    override func presetText() -> String? {
        (current.map { ZoneLighting.toText($0) } ?? "") + (screening ? "|" + follower.setup.toText() : "") + (game?.presetText ?? "")
    }

    override var headerAccessory: NSView? { game != nil ? viewPick : nil }

    @objc private func viewPicked() { showingGame = viewPick.selectedSegment == 1; refresh() }

    override func scanned() {
        guard let game = game, !game.keys.isEmpty else { return }
        queue.async { if let hidpp = try? self.connection() { game.sendAgain(hidpp, self.device.shortName) } }
    }

    override func applyPreset(_ full: String) {
        let (text, keys) = GameModeKeys.split(full)
        if let keys = keys, let game = game {
            game.set(GameModeKeys.fromText(keys, game.controlBitmap), on: self)
            gameBox?.show()
        }
        let pieces = text.components(separatedBy: "|")
        let screen = !keyboard && pieces.count > 1
        if screen {
            screenBox.setup = ScreenSettings.corners(pieces[1])
            follower.setup = screenBox.setup
            Settings.set(setupKey, screenBox.setup.toText())
        }
        if screening && !screen { stopScreen() }
        if let lights = ZoneLighting.fromText(pieces[0], count) { current = lights }
        wholeAgain = true
        sequence += 1
        if screen && !screening { startScreen() } else { refresh(); send() }
    }

    private func startScreen() {
        Settings.set(screenKey, "1")
        follower.start()
        refresh()
        showStatus()
    }

    // Back to the lights G-Lite keeps: they're all sent again.
    private func stopScreen() {
        Settings.remove(screenKey)
        follower.stop()
        sent = [MouseLight?](repeating: nil, count: count)
        wholeAgain = true
    }

    private func sendScreen(_ colors: [Int]) {
        guard let zones = zones else { return }
        framed = colors
        queue.async {
            guard let hidpp = try? self.connection() else { return }
            for zone in 0..<min(zones.count, colors.count) { try? ZoneLighting.setColor(hidpp, zone, zones[zone], colors[zone]) }
        }
        DispatchQueue.main.async { self.showStatus() }
    }

    override func giveBack() {
        follower.stop()
        stopAudio()
        liveTimer?.invalidate()
        liveTimer = nil
        stopLive()
    }

    // ---- live effects (0x8080) ----

    private func syncLive() {
        let wanted = perKey && zones != nil && running
        if wanted && liveTimer == nil {
            liveTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in self?.liveTick() }
            showStatus()
        }
        if !wanted && liveTimer != nil {
            liveTimer?.invalidate()
            liveTimer = nil
            stopLive()
        }
    }

    private func stopLive() {
        animation?.stop()
        animation = nil
        sentKeys = nil
        liveClaimed = false
        if liveProblem != nil { liveProblem = nil; showStatus() }
    }

    // As on Windows (ZonesPage.LiveTick): the keys whose colour moved, all of them every 2 s with the keyboard's effect set to Off again.
    private func liveTick() {
        guard let listed = zones, let lights = current, let light = lights.first ?? nil, live(light.effect), let picture = picture,
              !framing else { return }
        if animation == nil || animationId != light.effect {
            stopLive()
            animation = LiveEffects.make(light.effect)
            animationId = light.effect
            liveStart = Date()
            lastLiveFrame = 0
        }
        guard let animation = animation else { return }
        if keyField == nil { keyField = KeyField.from(picture) }
        guard let field = keyField else { return }
        animation.color = light.color
        animation.period = light.period
        animation.intensity = LiveEffects.defaultIntensity
        animation.direction = light.direction
        let seconds = Date().timeIntervalSince(liveStart), elapsed = min(0.25, seconds - lastLiveFrame)
        lastLiveFrame = seconds
        var colors = [Int](repeating: 0, count: field.count)
        animation.frame(field, seconds, elapsed, &colors)
        if animation.problem != liveProblem { liveProblem = animation.problem; showStatus() }
        var byId: [Int: Int] = [:]
        for i in 0..<field.count {
            colors[i] = ZonesPage.scale(colors[i], Double(light.bright) / 100)
            byId[field.ids[i]] = colors[i]
        }
        picture.show((0..<picture.count).map { byId[picture.idOf($0)] ?? 0 })
        let full = sentKeys == nil || Date() >= nextLiveRefresh
        if full { nextLiveRefresh = Date().addingTimeInterval(2) }
        var lastSent = sentKeys ?? [:]
        var changes: [Int: Int] = [:]
        for (id, color) in byId {
            let before = lastSent[id]
            if full || before == nil || LiveEffects.distance(before!, color) > 9 || (color == 0 && before != 0) { changes[id] = color }
        }
        if changes.isEmpty { return }
        for (id, color) in changes { lastSent[id] = color }
        sentKeys = lastSent
        // Off is sent again with every full frame: a keyboard turned off and on comes back running its own effect.
        let claim = !liveClaimed || full, firstClaim = !liveClaimed, count = self.count
        framing = true
        queue.async {
            defer { DispatchQueue.main.async { self.framing = false } }
            do {
                let hidpp = try self.connection()
                if claim {
                    for zone in 0..<min(listed.count, count) { try ZoneLighting.setLight(hidpp, zone, listed[zone], MouseLight(effect: 0x00), quiet: !firstClaim) }
                    DispatchQueue.main.async { self.sent = [MouseLight?](repeating: nil, count: count); self.liveClaimed = true }
                }
                try ZoneLighting.sendKeys(hidpp, changes)
            } catch {
                DispatchQueue.main.async { self.sentKeys = nil; self.liveClaimed = false; self.status.show("\(error)", error: true) }
            }
        }
    }

    // ---- Audio ----

    private func syncAudio() {
        let wanted = keyboard && !perKey && zones != nil && current?.contains { $0?.effect == ZoneLighting.audio.id } == true
        if wanted && audioTimer == nil {
            ScreenSource.shared.use(self)
            audioTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.audioTick() }
            showStatus()
        }
        if !wanted && audioTimer != nil { stopAudio() }
    }

    private func stopAudio() {
        audioTimer?.invalidate()
        audioTimer = nil
        ScreenSource.shared.release(self)
        audioSent = -1
        audioLevel = 0
        if audioProblem != nil { audioProblem = nil; showStatus() }
    }

    // The loudest of eight bands, 30% to 90% of the range spread over the whole level (app/ZonesPage.cs, AudioTick).
    private func audioTick() {
        guard let listed = zones, let lights = current, !framing else { return }
        let heard = ScreenSource.shared.bands(8)
        let problem = heard != nil ? nil : ScreenSource.shared.failure
            ?? (ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0))
                ? nil : "Audio needs macOS 13 or later to hear the Mac's sound.")
        if problem != audioProblem { audioProblem = problem; showStatus() }
        let seconds = Date().timeIntervalSince(clock), elapsed = min(0.25, seconds - audioClock)
        audioClock = seconds
        let target = max(0, min(1, ((heard?.max() ?? 0) - 0.3) / 0.6))
        audioLevel = target > audioLevel ? target : max(target, audioLevel - elapsed * 1.6)
        let step = Int((audioLevel * 50).rounded()), refresh = Date() >= audioRefresh
        if step == audioSent && !refresh { return }
        if refresh { audioRefresh = Date().addingTimeInterval(2) }
        audioSent = step
        let level = Double(step) / 50, white = monochrome
        framing = true
        queue.async {
            defer { DispatchQueue.main.async { self.framing = false } }
            guard let hidpp = try? self.connection() else { DispatchQueue.main.async { self.audioSent = -1 }; return }
            let wholeAudio = lights.first??.effect == ZoneLighting.audio.id
            for zone in 0..<min(lights.count, listed.count) {
                guard let light = lights[zone], light.effect == ZoneLighting.audio.id else { continue }
                // On the G213 zone 0 covers the areas, and an area write would end it (docs/G213.md).
                if zone > 0 && wholeAudio && ZoneLighting.isArea(listed[zone][ZoneLighting.place] ?? 0) { continue }
                do { try ZoneLighting.setColor(hidpp, zone, listed[zone], ZonesPage.scale(white ? 0xFFFFFF : light.color, level), bright: light.bright) }
                catch { DispatchQueue.main.async { self.audioSent = -1 }; return }
            }
        }
    }

    static func scale(_ color: Int, _ factor: Double) -> Int {
        Int(Double(color >> 16 & 0xFF) * factor) << 16 | Int(Double(color >> 8 & 0xFF) * factor) << 8 | Int(Double(color & 0xFF) * factor)
    }

    // ---- device ----

    private func send() {
        guard let want = current, let zones = zones else { return }
        Settings.set(rememberedKey, ZoneLighting.toText(want))
        sequence += 1
        let startedAt = sequence, whole = wholeAgain
        wholeAgain = false
        run({ hidpp in
            if startedAt != self.sequence { return }
            try self.apply(hidpp, zones, want, whole: whole)
        }, done: { if startedAt == self.sequence { self.showStatus() } })
    }

    private func apply(_ hidpp: Hidpp, _ zones: [[Int: Int]], _ want: [MouseLight?], whole: Bool = false) throws {
        let areas = zones.contains { ZoneLighting.isArea($0[ZoneLighting.place] ?? 0) }
        // An area write ends the whole-keyboard effect on the G213, so All sends it again even when it looks unchanged.
        if whole && areas { for zone in 0..<min(zones.count, count) where zones[zone][ZoneLighting.place] == 1 { sent[zone] = nil } }
        for zone in 0..<min(zones.count, count) {
            guard var light = want[zone], sent[zone] != light else { continue }
            // Static scales its colour by brightness; the G413 ignores Breathe's intensity byte, so its white is scaled here instead.
            if monochrome {
                light.color = light.effect == 0x0A ? G515Profile.scale(0xFFFFFF, light.bright) : 0xFFFFFF
            }
            try ZoneLighting.setLight(hidpp, zone, zones[zone], light)
            sent[zone] = want[zone]
        }
    }

    private func load() {
        status.show("Reading the \(noun)…")
        let want = current
        var read: [[Int: Int]] = [], oneColor = false, code = -1
        run({ hidpp in
            code = self.layoutCode(hidpp)
            self.game?.sendAgain(hidpp, self.device.shortName)
            (read, oneColor) = try ZoneLighting.zones(hidpp)
            self.monochrome = oneColor
            self.sent = [MouseLight?](repeating: nil, count: self.count)
            if let want = want { try self.apply(hidpp, read, want) }
        }, done: {
            self.applyLayout(self.picture, self.layout, code)
            self.zones = read
            if self.keyboard {
                let listed = Array(read.prefix(self.count))
                let areas = listed.contains { ZoneLighting.isArea($0[ZoneLighting.place] ?? 0) }
                self.shownZones = (0..<listed.count).filter { !(areas && listed[$0][ZoneLighting.place] == 1) }
                self.setZoneLabels(["All"] + self.shownZones.map { ZoneLighting.zoneName(listed[$0][ZoneLighting.place] ?? 0, $0) })
                if self.picked > self.shownZones.count { self.picked = 0 }
            }
            if self.screening { self.follower.start() }
            self.refresh()
            self.showStatus()
            self.loaded()
        })
    }

    deinit { frameTimer?.invalidate() }

    // ---- showing ----

    // Each key lit by its zone's light: on the G213 the ids are zones, on the one-zone keyboards (the G413) every lit key is zone 0
    // (app/ZonesPage.cs, KeyZones and ShowFrame). An area that can't take zone 0's effect shows zone 0's.
    private func showFrame() {
        if let speakers = speakers { showSpeakers(speakers); return }
        // A live effect draws the picture itself (liveTick).
        if running { return }
        guard let picture = picture, let zones = zones, let lights = current else { picture?.show([]); return }
        let seconds = Date().timeIntervalSince(clock)
        // On a lighting-id picture every key shows the zone at the keys (0x8070 location 1, else zone 0) but the logo, which has no id:
        // it shows the zone at the logo (location 2, the G512's second zone).
        let keysZone = max(0, zones.firstIndex { $0[ZoneLighting.place] == 1 } ?? 0), logoZone = zones.firstIndex { $0[ZoneLighting.place] == 2 } ?? -1
        var colors: [Int] = [], marked: [Bool] = []
        for key in 0..<picture.count {
            let id = picture.idOf(key)
            let zone = layout?.zones == true ? id : id >= 0 ? keysZone : picture.nameOf(key) == "Logo" ? logoZone : -1
            var light: MouseLight?
            if zone >= 0 && zone < zones.count && zone < lights.count {
                light = lights[zone].flatMap { zones[zone][Int($0.effect)] != nil ? $0 : nil } ?? lights[0]
            }
            if monochrome, light != nil { light!.color = 0xFFFFFF }
            if let audio = light, audio.effect == ZoneLighting.audio.id {
                light!.effect = audioLevel <= 0 ? 0 : 0x01
                light!.bright = max(1, Int((Double(audio.bright) * audioLevel).rounded()))
            }
            colors.append(light.map { ZoneLighting.colorAt($0, picture.xOf(key), seconds) } ?? 0)
            marked.append(picked > 0 && zone == self.zone)
        }
        picture.show(colors, marked: marked)
    }

    // The speakers' four lights: what each zone runs, or the screen's colours while the Screen effect does.
    private func showSpeakers(_ speakers: SpeakerPicture) {
        let seconds = Date().timeIntervalSince(clock)
        speakers.colors = (0..<4).map { zone in
            if screening { return framed.flatMap { zone < $0.count ? $0[zone] : nil } ?? -1 }
            guard let zones = zones, let lights = current, zone < zones.count, zone < lights.count else { return -1 }
            let own = lights[zone].flatMap { zones[zone][Int($0.effect)] != nil ? $0 : nil } ?? lights[0]
            return own.map { ZoneLighting.colorAt($0, 0.5, seconds) } ?? -1
        }
        speakers.selected = picked > 0 && zonePicker.isEnabled ? zone : -1
        speakers.pickable = zonePicker.isEnabled
    }

    private func showStatus() {
        if let zones = zones, zones.isEmpty { status.show("The \(noun) list no lighting zones", error: true); return }
        if let problem = audioProblem { status.show(problem, error: true); return }
        if audioTimer != nil { status.show("Audio effect: G-Lite runs it, so it stops if you quit G-Lite"); return }
        if let problem = liveProblem { status.show(problem, error: true); return }
        if running { status.show("Experimental: G-Lite draws this effect key by key, not tried on this keyboard yet"); return }
        if screening {
            status.show(follower.problem ?? "Screen effect: G-Lite runs it, so it stops if you quit G-Lite", error: follower.problem != nil)
            return
        }
        // The G213's light button turns the backlight off inside the keyboard: nothing is reported, and lighting sent then stays dark
        // (docs/G213.md).
        if current != nil && keyboard && device.shortName.uppercased() == "G213" {
            status.show("Set by G-Lite. Keys dark? Press the light button above Pause")
            return
        }
        status.show(current == nil ? "" : "Set by G-Lite, not saved to the \(noun)")
    }

    private func refresh() {
        refreshing = true
        defer { refreshing = false }
        let ready = zones.map { !$0.isEmpty } ?? false
        let shown = displayed
        let info = shown.flatMap { self.info($0.effect) }
        let mixed = picked == 0 && current.map { lights in lights.contains { $0 != lights[0] } } ?? false
        rows["effect"]?.hint.stringValue = zones?.isEmpty == true ? "Not found on these \(noun)"
            : screening ? "The lights follow the screen"
            : shown.map { live($0.effect) } == true ? "Drawn by G-Lite, key by key"
            : shown?.effect == ZoneLighting.audio.id ? "Follows the Mac's sound"
            : shown != nil || !ready ? "What the lighting does"
            : keyboard ? "The keyboard's own lighting, until you pick one" : "The speakers' own lighting, until you pick one"
        rows["zone"]?.hint.stringValue = mixed && !screening ? "Zones differ: a change sets all of them"
            : speakers != nil ? "Click a light to pick it" : "The lights to set"
        rows["effect"]?.enable(ready)
        rows["zone"]?.isHidden = keyboard && shownZones.count <= 1
        zonePicker.isEnabled = ready
        zonePicker.selectedSegment = picked
        let offered = !ready ? [] : picked == 0 ? zones! : [zones![zone]]
        // Audio is sent as Static, so it's listed where Static is.
        // The live effects cover the whole keyboard, so only on All.
        let drawn: [UInt8] = !keyboard ? [] : perKey ? LiveEffects.all.map { $0.id }.filter { $0 != 0xFE } : [ZoneLighting.audio.id]
        shownEffects = (ZoneLighting.effects.map { $0.id } + drawn).filter { id in
            live(id) ? picked == 0 : offered.isEmpty || offered.contains { $0[Int(id == ZoneLighting.audio.id ? 0x01 : id)] != nil }
        }
        effect.removeAllItems()
        effect.addItems(withTitles: shownEffects.compactMap { self.info($0)?.name } + (keyboard ? [] : ["Screen"]))
        effect.isEnabled = ready || screening
        effect.selectItem(at: screening ? shownEffects.count : shown.flatMap { light in shownEffects.firstIndex(of: light.effect) } ?? -1)
        let plain = !screening
        let hasColor = plain && info?.color == true && !monochrome, hasSpeed = plain && info?.speed == true
        let hasBrightness = plain && shown != nil && shown!.effect != 0
        rows["zone"]?.isHidden = rows["zone"]?.isHidden == true || screening
        rows["color"]?.isHidden = !hasColor
        rows["direction"]?.isHidden = !plain || info?.direction != true || shown.map { live($0.effect) } == true
        if !keyboard { screenBox.showing(screening); screenBox.pausing(screening) }
        picture?.isHidden = showingGame
        gameBox?.picture.isHidden = !showingGame
        lightingSection.isHidden = showingGame
        savingSection.isHidden = showingGame
        gameBox?.section.isHidden = !showingGame
        gameBox?.show()
        viewPick.selectedSegment = showingGame ? 1 : 0
        rows["speed"]?.isHidden = !hasSpeed
        rows["bright"]?.isHidden = !hasBrightness
        syncAudio()
        syncLive()
        if let light = shown {
            color.color = NSColor(rgb: light.color)
            bright.integerValue = light.bright
            brightValue.stringValue = "\(light.bright)%"
            if let info = info, hasSpeed {
                speed.doubleValue = (Double(info.maxPeriod - light.period) * 100 / Double(info.maxPeriod - info.minPeriod)).rounded()
                speedValue.stringValue = "\(speed.integerValue)%"
            }
            direction.selectItem(at: ZoneLighting.directions.firstIndex(of: light.direction) ?? 0)
        }
    }
}

// The G560 speakers (app/ZonesPage.cs, SpeakerPicture): the front lights (zones 0 and 1) under the grilles, the back ones (2 and 3)
// as the glow behind, up the wall; a click picks the zone, a mark under the speaker (front) or above it (back).
final class SpeakerPicture: NSView {
    // RGB per zone, -1 when off or unknown.
    var colors = [-1, -1, -1, -1] { didSet { needsDisplay = true } }
    var selected = -1 { didSet { needsDisplay = true } }
    var pickable = false
    var picked: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    private var radius: CGFloat { (bounds.height - 24) * 0.36 }

    private func center(_ speaker: Int) -> CGPoint {
        CGPoint(x: bounds.midX + (speaker == 0 ? -1 : 1) * radius * 2.6, y: bounds.midY + radius * 0.18)
    }

    // A colour as the keys show it: its hue at full brightness, mixed into the unlit key colour by its brightness.
    private static func shown(_ rgb: Int) -> NSColor {
        let off = KeyPicture.keyOff.usingColorSpace(.sRGB) ?? .gray
        let red = rgb >> 16 & 0xFF, green = rgb >> 8 & 0xFF, blue = rgb & 0xFF, top = max(red, green, blue)
        if rgb < 0 || top == 0 { return off }
        let mix = CGFloat(top) / 255
        let lit = NSColor(srgbRed: CGFloat(red) / CGFloat(top), green: CGFloat(green) / CGFloat(top), blue: CGFloat(blue) / CGFloat(top), alpha: 1)
        return off.blended(withFraction: mix, of: lit) ?? lit
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = self.radius
        guard radius > 1, let context = NSGraphicsContext.current?.cgContext else { return }
        for speaker in 0..<2 {
            let center = self.center(speaker)
            let back = colors[2 + speaker], front = SpeakerPicture.shown(colors[speaker])
            // The glow behind, kept inside the picture.
            if back >= 0 && back & 0xFFFFFF != 0 {
                let reach = min(center.y, bounds.height - center.y) - 1
                let glow = SpeakerPicture.shown(back)
                context.saveGState()
                let oval = CGRect(x: center.x - radius * 1.7, y: center.y - reach, width: radius * 3.4, height: reach * 2)
                context.addEllipse(in: oval)
                context.clip()
                let focus = CGPoint(x: center.x, y: center.y - radius * 0.3)
                if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                             colors: [glow.withAlphaComponent(0.6).cgColor, glow.withAlphaComponent(0).cgColor] as CFArray,
                                             locations: [0, 1]) {
                    context.translateBy(x: focus.x, y: focus.y)
                    context.scaleBy(x: 1.7 * radius / reach, y: 1)
                    context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: reach,
                                               options: [])
                }
                context.restoreGState()
            }
            // The housing, its inner side's curve lit along its bottom.
            let inner: CGFloat = speaker == 0 ? 1 : -1
            let housing = CGRect(x: center.x - radius * 1.08 + inner * radius * 0.1, y: center.y - radius * 1.02, width: radius * 2.16,
                                 height: radius * 2.12)
            NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: housing).fill()
            let arc = NSBezierPath()
            let arcRadius = (housing.width - radius * 0.1) / 2
            // Flipped view: angles run clockwise from the right, so 90 is the bottom.
            arc.appendArc(withCenter: CGPoint(x: housing.midX, y: housing.midY), radius: arcRadius,
                          startAngle: speaker == 0 ? -10 : 90, endAngle: speaker == 0 ? 90 : 190, clockwise: false)
            arc.lineWidth = radius * 0.11
            arc.lineCapStyle = .round
            front.setStroke()
            arc.stroke()
            let grille = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            KeyPicture.keyOff.setFill()
            grille.fill()
            NSColor.separatorColor.setStroke()
            grille.lineWidth = 1
            grille.stroke()
            if selected == speaker || selected == 2 + speaker {
                let markY = selected == speaker ? center.y + radius * 1.02 + 6 : center.y - radius * 1.02 - 9
                let mark = NSBezierPath(roundedRect: CGRect(x: center.x - radius * 0.5, y: markY, width: radius, height: 3), xRadius: 1.5, yRadius: 1.5)
                NSColor.controlAccentColor.setStroke()
                mark.lineWidth = 2
                mark.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard pickable else { return }
        let point = convert(event.locationInWindow, from: nil)
        let speaker = point.x < bounds.midX ? 0 : 1
        picked?(point.y > center(speaker).y ? speaker : 2 + speaker)
    }
}
