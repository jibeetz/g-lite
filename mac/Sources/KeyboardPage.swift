import AppKit

// The G515 screen: live preview while editing, Save to keyboard writes the onboard profile after a backup (app/KeyboardPage.cs).
// The preview stays on the keys while G-Lite runs, also with the window closed; quitting gives the keys back to the saved lighting.
// The When idle settings are saved with the lighting; while a preview isn't saved, G-Lite dims and turns off the keys itself as the
// keyboard would (the keys are claimed, so its own timers don't run), claims them again after the keyboard slept, and gives them back
// while the screen is locked or off (KeyboardPage.Watch, Idle and PresenceChanged on Windows).
final class KeyboardPage: DevicePage {
    static let backupId = "G515"
    // The G515's Wave lists Up and Down (0x8071 fn 0: DC E1), so it gets the six directions (app/KeyboardPage.cs).
    static let directions = [6, 1, 7, 2, 3, 8]
    static let directionNames = ["Left", "Right", "Up", "Down", "Center out", "Center in"]

    private var current = Lighting(), stored: Lighting?
    private var brightness = 100, storedBrightness = 100
    private var claimed = false, loaded = false, previewSequence = 0
    private var previewTimer: Timer?
    private let idleBox = IdleBox(offersNever: true)
    private var lightingRow = NSView(), idleArea = NSView(), idleHeight: NSLayoutConstraint?
    // 0 lit, 1 dimmed, 2 off, as the idle times say; away while the screen is locked or off.
    private var watchTimer: Timer?, idleLevel = 0, watchTicks = 0, watching = false, away = false
    private let effect = NSPopUpButton(), color = NSColorWell(), direction = NSPopUpButton()
    private let speed = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let level = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let levelValue = NSTextField(labelWithString: "")
    private let save = NSButton(title: "Save to keyboard", target: nil, action: nil)
    private let revert = NSButton(title: "Revert", target: nil, action: nil)
    private var rows: [String: NSGridRow] = [:]
    private let layout = KeyLayout.load("g515-tkl.json")
    // Game mode through 0x4523 (tried on the G515), in its own view.
    private lazy var game = GameKeys(device, supported: layout != nil, experimental: false)
    private lazy var gameBox: GameModeBox? = layout.flatMap { layout in game.map { GameModeBox(layout: layout, game: $0, page: self) } }
    private var gameArea = NSView(), lightingBox = NSView(), keysPicture: NSView?
    private let viewPick = NSSegmentedControl(labels: ["Settings", "Game"], trackingMode: .selectOne, target: nil, action: nil)
    private var showingGame = false
    private lazy var picture = layout.map(KeyPicture.init)
    private let intensity = Ui.slider(), intensityValue = Ui.value()
    // G-Lite's own effects after the keyboard's, drawn key by key through 0x8081 (LiveEffects).
    private lazy var effects = G515Profile.effects + (picture != nil && device.has(0x8081) ? LiveEffects.all : [])
    private lazy var runner = picture.map { LiveRunner(page: self, picture: $0, claim: { [weak self] hidpp in
        try G515Profile.claim(hidpp)
        self?.claimed = true
    }, release: { [weak self] hidpp in
        try G515Profile.release(hidpp)
        self?.claimed = false
    }) }
    private var live: Bool { LiveEffects.isLive(current.effect) }
    // The Screen effect's box, shown while it runs; its setup is kept as screen.<device>.
    private var setupKey: String { "screen." + device.settingsKey }
    private lazy var screenBox: ScreenBox = {
        let box = ScreenBox(setup: ScreenSettings.fromText(Settings.get(setupKey)), brightness: false, battery: device.has(0x1004),
                            counts: picture.map { picture in { setup in setup.counts(KeyField.from(picture)) } }) { ScreenSettings.defaults() }
        box.changed = { [weak self] setup in
            guard let self = self else { return }
            Settings.set(self.setupKey, setup.toText())
            self.runner?.screenSetup = setup
            self.edited()
        }
        box.picked = { [weak self] zone in self?.runner?.screenZone = zone }
        runner?.screenZone = box.selectedZone
        picture?.keysPicked = { [weak self] keys in
            guard let self = self, self.screening, let picture = self.picture else { return }
            self.screenBox.give(keys.map { picture.idOf($0) })
        }
        return box
    }()
    // The hint in the title, so the page keeps Windows' height.
    private lazy var screenArea: NSView = Ui.box(picture == nil ? "Screen" : "Screen: pick an area, then click or drag over keys to give them to it", screenBox)
    private var screening: Bool { current.effect == 0xFE }
    private var directions: [Int] { live ? LiveEffects.directions : KeyboardPage.directions }


    override func loadView() {
        effect.addItems(withTitles: effects.map { $0.name })
        intensity.target = self; intensity.action = #selector(changed)
        intensity.widthAnchor.constraint(equalToConstant: 200).isActive = true
        for control in [effect, direction] as [NSControl] { control.target = self; control.action = #selector(changed) }
        for control in [speed, level] { control.target = self; control.action = #selector(changed); control.isContinuous = true }
        color.target = self; color.action = #selector(changed)
        save.target = self; save.action = #selector(saveClicked); save.keyEquivalent = "\r"
        revert.target = self; revert.action = #selector(revertClicked)
        levelValue.font = .monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        levelValue.widthAnchor.constraint(equalToConstant: 44).isActive = true
        color.widthAnchor.constraint(equalToConstant: 60).isActive = true
        // 200, so the When idle box fits beside the Lighting box.
        speed.widthAnchor.constraint(equalToConstant: 200).isActive = true
        level.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let grid = NSGridView(views: [
            [Ui.label("Effect"), effect],
            [Ui.label("Colour"), color],
            [Ui.label("Speed"), speed],
            [Ui.label("Intensity"), NSStackView(views: [intensity, intensityValue])],
            [Ui.label("Direction"), direction],
            [Ui.label("Brightness"), NSStackView(views: [level, levelValue])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12
        grid.rowAlignment = .firstBaseline
        for (i, name) in ["effect", "color", "speed", "intensity", "direction", "level"].enumerated() { rows[name] = grid.row(at: i) }

        viewPick.target = self; viewPick.action = #selector(viewPicked)
        viewPick.selectedSegment = 0
        keysPicture = picture.map { pictureBox($0) }
        lightingBox = Ui.box("Lighting", grid)
        idleBox.changed = { [weak self] idle, dim, sleep in
            guard let self = self else { return }
            self.current.idle = idle; self.current.dim = dim; self.current.sleep = sleep
            self.edited()
            self.refresh()
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        idleArea = Ui.box("When idle", Ui.column([idleBox, spacer]))
        let row = NSStackView(views: [lightingBox, idleArea])
        row.alignment = .top
        idleHeight = idleArea.heightAnchor.constraint(equalTo: lightingBox.heightAnchor)
        lightingRow = row
        if let gameBox = gameBox { gameArea = Ui.box("Game mode", gameBox) }
        gameArea.isHidden = true
        view = Ui.page(header: header, body: (keysPicture.map { [$0] } ?? []) + [lightingRow, screenArea, gameArea], status: status,
                       buttons: [revert, save])
        runner?.screenSetup = screenBox.setup
        header.show(device)
        Presence.watch()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.watch() }
        refresh()
        load()
    }

    deinit { watchTimer?.invalidate() }

    private func refresh() {
        // A live effect draws the picture itself (LiveRunner).
        if !live { picture?.display(loaded ? current : nil, brightness) }
        let info = effects.first { $0.id == current.effect } ?? G515Profile.effects[1]
        effect.selectItem(at: effects.firstIndex { $0.id == current.effect } ?? 1)
        rows["color"]?.isHidden = !info.color
        rows["speed"]?.isHidden = !info.speed
        rows["intensity"]?.isHidden = !(live && info.intensity)
        keysPicture?.isHidden = showingGame
        lightingRow.isHidden = showingGame
        idleBox.show(current, enabled: loaded)
        // A live effect isn't saved, so its idle times wouldn't be either.
        idleArea.isHidden = live
        idleHeight?.isActive = !live
        screenArea.isHidden = !screening || showingGame
        screenBox.showing(screening && !showingGame)
        gameArea.isHidden = !showingGame
        gameBox?.show()
        viewPick.selectedSegment = showingGame ? 1 : 0
        rows["direction"]?.isHidden = !info.direction
        intensity.integerValue = current.intensity
        intensityValue.stringValue = "\(current.intensity)%"
        direction.removeAllItems()
        direction.addItems(withTitles: live ? LiveEffects.directionNames : KeyboardPage.directionNames)
        if info.color { color.color = NSColor(rgb: current.color) }
        if info.speed {
            speed.doubleValue = (Double(info.maxPeriod - current.period) * 100 / Double(info.maxPeriod - info.minPeriod)).rounded()
        }
        if let i = directions.firstIndex(of: current.direction) { direction.selectItem(at: i) }
        level.integerValue = brightness
        levelValue.stringValue = "\(brightness)%"
        let dirty = loaded && (stored == nil || current != stored || brightness != storedBrightness)
        // A live effect runs in G-Lite: the keyboard can't keep it.
        save.isEnabled = dirty && !live
        revert.isEnabled = dirty
        for control in [effect, color, speed, intensity, direction, level] as [NSControl] { control.isEnabled = loaded }
    }

    @objc private func changed(_ sender: NSControl) {
        let picked = effects[max(0, effect.indexOfSelectedItem)]
        if sender === effect && picked.id != current.effect {
            current.effect = picked.id
            if picked.speed { current.period = picked.defaultPeriod }
            if LiveEffects.isLive(picked.id) { current.direction = LiveEffects.defaultDirection(picked.id) }
            else if picked.direction && !KeyboardPage.directions.contains(current.direction) { current.direction = 1 }
        }
        if sender === intensity { current.intensity = intensity.integerValue }
        if sender === color { current.color = color.color.rgb }
        if sender === speed && picked.speed {
            current.period = picked.maxPeriod - Int((Double(picked.maxPeriod - picked.minPeriod) * speed.doubleValue / 100).rounded())
        }
        if sender === direction, direction.indexOfSelectedItem >= 0 { current.direction = directions[direction.indexOfSelectedItem] }
        if sender === level { brightness = level.integerValue }
        edited()
        refresh()
        // At most one preview every 120 ms during a drag, as on Windows.
        if previewTimer == nil {
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                self?.previewTimer = nil
                self?.preview()
            }
        }
    }

    private func load() {
        status.show("Reading the keyboard…")
        var lighting: Lighting?, readLevel = 100, half = false, code = -1
        run({ hidpp in
            code = self.layoutCode(hidpp)
            self.game?.sendAgain(hidpp, self.device.shortName)
            do {
                let files = try G515Profile.snapshot(hidpp)
                lighting = G515Profile.decode(files.userProfile ?? files.factoryProfile!)
            } catch GLiteError.halfWritten { half = true }
            readLevel = try G515Profile.brightness(hidpp)
        }, done: {
            self.applyLayout(self.picture, self.layout, code)
            self.loaded = true
            self.stored = half ? nil : lighting ?? Lighting()
            self.current = lighting ?? Lighting()
            self.brightness = readLevel
            self.storedBrightness = readLevel
            self.refresh()
            if half {
                self.status.show("The lighting saved on the keyboard is half written. Save writes it again.", error: true)
            } else {
                self.status.show(lighting == nil ? "The keyboard runs its factory animation." : "")
            }
            self.loaded()
        })
    }

    private func preview() {
        let lighting = current, level = brightness
        previewSequence += 1
        let startedAt = previewSequence
        if live {
            runner?.run(lighting)
            run({ hidpp in if level != (try G515Profile.brightness(hidpp)) { try G515Profile.setBrightness(hidpp, level) } },
                done: { self.status.show(self.runner?.problem ?? "A live effect runs while G-Lite does: the keyboard can't save it") })
            return
        }
        runner?.stop()
        run({ hidpp in
            if startedAt != self.previewSequence { return }
            if level != (try G515Profile.brightness(hidpp)) { try G515Profile.setBrightness(hidpp, level) }
            if !self.claimed && lighting == self.stored { return }
            if !self.claimed { try G515Profile.claim(hidpp); self.claimed = true }
            do { try G515Profile.preview(hidpp, lighting) } catch let error as GLiteError {
                // 5: the keyboard took the lighting back (it slept), so claim it again.
                if error.code != 5 { throw error }
                try G515Profile.claim(hidpp)
                try G515Profile.preview(hidpp, lighting)
            }
        }, done: { if startedAt == self.previewSequence { self.status.show("") } })
    }

    // ---- the preview's idle watch (app/KeyboardPage.cs, Watch) ----

    private var unsaved: Bool { loaded && (stored == nil || current != stored || brightness != storedBrightness) }

    private func watch() {
        if Presence.away != away { away = Presence.away; awayChanged() }
        if live || screening || !unsaved || !claimed || away { idleLevel = 0; return }
        idle()
        // Every 3 s: the keyboard took its lighting back after it slept (0x8071 fn 5 says no software control), so it's claimed again.
        watchTicks += 1
        if watchTicks % 6 != 0 || watching || idleLevel == 2 { return }
        watching = true
        let lighting = current, level = brightness, shownLevel = idleLevel
        queue.async {
            defer { DispatchQueue.main.async { self.watching = false } }
            guard self.claimed, let hidpp = try? self.connection(),
                  let reply = try? hidpp.callUnlogged(try hidpp.featureIndex(0x8071), 5, [0x00]), reply[1] == 0 else { return }
            try? G515Profile.claim(hidpp)
            self.claimed = true
            if let now = try? G515Profile.brightness(hidpp), now != level { try? G515Profile.setBrightness(hidpp, level) }
            try? KeyboardPage.show(hidpp, lighting, shownLevel)
        }
    }

    // Dimmed after the idle time, off after the sleep time, as the saved profile would do.
    private func idle() {
        let seconds = IdleTime.seconds
        let level = current.sleep > 0 && seconds >= Double(current.sleep) ? 2 : current.idle > 0 && seconds >= Double(current.idle) ? 1 : 0
        if level == idleLevel { return }
        idleLevel = level
        let lighting = current
        queue.async {
            guard self.claimed, let hidpp = try? self.connection() else { return }
            try? KeyboardPage.show(hidpp, lighting, level)
        }
    }

    private static func show(_ hidpp: Hidpp, _ lighting: Lighting, _ level: Int) throws {
        if level == 2 { try G515Profile.preview(hidpp, Lighting(effect: 0)) }
        else { try G515Profile.preview(hidpp, lighting, level == 1 ? lighting.dim : 100) }
    }

    // Locked or off: the keys go back to the saved lighting (the keyboard's own timers run again); back: the preview again.
    private func awayChanged() {
        if live || screening || !unsaved { return }
        if away {
            if idleLevel == 2 { return }
            idleLevel = 0
            let level = storedBrightness
            run({ hidpp in
                if self.claimed { try G515Profile.release(hidpp); self.claimed = false }
                try G515Profile.setBrightness(hidpp, level)
            })
        } else {
            preview()
        }
    }

    @objc private func saveClicked() {
        let lighting = current, level = brightness
        previewSequence += 1
        save.isEnabled = false
        status.show("Saving…")
        logAction("Save to keyboard")
        run({ hidpp in
            let files = try G515Profile.snapshot(hidpp)
            try Backups.save(KeyboardPage.backupId, files, who: self.device.shortName)
            try G515Profile.store(hidpp, files, lighting)
            self.claimed = false
        }, done: {
            self.stored = lighting
            self.storedBrightness = level
            self.refresh()
            self.status.show("Saved to the keyboard")
        })
    }

    // Presets hold the lighting as text, as on Windows (profile.g515.<name>): a Screen setup after "|" and Game mode keys after "!".
    override var presetPrefix: String { "profile.g515." }
    override func presetText() -> String? {
        current.toText(brightness) + (screening ? "|" + screenBox.setup.toText() : "") + (game?.presetText ?? "")
    }

    override var headerAccessory: NSView? { game != nil ? viewPick : nil }

    @objc private func viewPicked() { showingGame = viewPick.selectedSegment == 1; refresh() }

    // For --snapshot.
    func showGame() { showingGame = game != nil; refresh() }

    override func scanned() {
        guard let game = game, !game.keys.isEmpty else { return }
        queue.async { if let hidpp = try? self.connection() { game.sendAgain(hidpp, self.device.shortName) } }
    }

    override func applyPreset(_ text: String) {
        if let keys = GameModeKeys.split(text).keys, let game = game {
            game.set(GameModeKeys.fromText(keys, game.controlBitmap), on: self)
            gameBox?.show()
        }
        guard let (lighting, level) = Lighting.fromText(KeyboardPage.lightingPart(text)) else { return }
        if let screen = KeyboardPage.screenPart(text) {
            screenBox.setup = ScreenSettings.fromText(screen)
            Settings.set(setupKey, screenBox.setup.toText())
            runner?.screenSetup = screenBox.setup
        }
        current = lighting
        // A live effect the keyboard can't run (no per-key lighting) becomes Static, as on Windows.
        if LiveEffects.isLive(current.effect) && !effects.contains(where: { $0.id == current.effect }) { current.effect = 0x01 }
        brightness = max(0, min(100, level))
        refresh()
        preview()
    }

    // The Screen setup a preset holds after "|", up to Game mode keys after the last "!" (GameModeKeys.split); G keys after a "~", from
    // presets saved while they held them, are left out, as on Windows.
    static func screenPart(_ text: String) -> String? {
        let parts = GameModeKeys.split(text).preset.components(separatedBy: "~")[0].components(separatedBy: "|")
        return parts.count > 1 ? parts[1] : nil
    }

    static func lightingPart(_ text: String) -> String {
        GameModeKeys.split(text).preset.components(separatedBy: "~")[0].components(separatedBy: "|")[0].components(separatedBy: "#")[0]
    }

    override func revertWithoutPreset() { backToStored() }

    @objc private func revertClicked() {
        if revertToPreset() { return }
        backToStored()
    }

    private func backToStored() {
        guard let stored = stored else { return }
        runner?.stop()
        current = stored
        brightness = storedBrightness
        previewSequence += 1
        refresh()
        let level = brightness
        run({ hidpp in
            if self.claimed { try G515Profile.release(hidpp); self.claimed = false }
            try G515Profile.setBrightness(hidpp, level)
        }, done: { self.status.show("") })
    }

    // At quit: the saved lighting and brightness come back, waiting for the device's queue.
    override func giveBack() {
        runner?.stop()
        previewSequence += 1
        let level = storedBrightness, changedLevel = brightness != storedBrightness
        queue.sync {
            guard self.claimed || changedLevel, let hidpp = try? self.connection() else { return }
            if self.claimed { try? G515Profile.release(hidpp) }
            if changedLevel { try? G515Profile.setBrightness(hidpp, level) }
        }
    }
}

extension NSColor {
    convenience init(rgb: Int) {
        self.init(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }

    var rgb: Int {
        guard let srgb = usingColorSpace(.sRGB) else { return 0xFFFFFF }
        func byte(_ value: CGFloat) -> Int { Int((max(0, min(1, value)) * 255).rounded()) }
        return byte(srgb.redComponent) << 16 | byte(srgb.greenComponent) << 8 | byte(srgb.blueComponent)
    }
}
