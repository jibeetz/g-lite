import AppKit

// The screen for the 0x8071 keyboards other than the G515 (app/KeyboardPage.cs, its live path): the G915, G915 TKL and G815, which
// also save into their onboard profile, and the G512 X 75, G915 X and other RGB keyboards, live only. The lighting is set on every
// cluster (the logo gets a close effect when it lacks one), kept as lighting.<device> and set again at each load.
// The G915 family also has its G keys (the Bindings view, saved into the running profile) and its onboard profiles M1-M3 (the picker
// left of Save, following the M keys through 0x8100 events).
// Game mode (the G815, experimental on the others) has its own view.
// The G512 X 75's light bar can have its own lighting (Per zone, then Keys or Light bar, or a click on the picture), kept after "#".
// The G915s' When idle settings go into the profile with the lighting; the G815 has none (its profiles hold 0 for both times).
final class LiveKeyboardPage: DevicePage {
    private let kind: KeyboardKind
    private var clusters: [[UInt8]]?
    private var verticalWave = false
    private var current = Lighting(), stored: Lighting?
    // The light bar's lighting with Per zone on, and the part the controls edit: 0 both (Per zone off), 1 the keys, 2 the bar.
    private var bar: Lighting?, part = 0
    private var parts: Bool { !kind.bar.isEmpty && picture != nil }
    private let perZone = Ui.toggle()
    private let partPicker = NSSegmentedControl(labels: ["Keys", "Light bar"], trackingMode: .selectOne, target: nil, action: nil)
    private var target: Lighting {
        get { part == 2 && bar != nil ? bar! : current }
        set { if part == 2 && bar != nil { bar = newValue } else { current = newValue } }
    }
    private var unknownStored = true, dirty = false, loaded = false
    private var brightness = 100, storedBrightness = 100, previewSequence = 0
    private var previewTimer: Timer?
    // The enabled onboard profiles' sectors (N for MN) and the one running; takenOver once the keyboard leaves its onboard profiles.
    private var slots: [Int] = [], running = 0, takenOver = false, checkingSlot = false, profilesFeature: UInt8 = 0
    // The G keys as edited, and as the running profile has them: they reach the keyboard on Save only. gKeysSector is the sector they
    // were read from, so Save never writes one slot's G keys into another.
    private var gKeys: [[UInt8]]?, storedGKeys: [[UInt8]]?, gKeysSector = 0, gKeyEdits = 0
    private var gKeysChanged: Bool { gKeys != nil && storedGKeys != nil && gKeys! != storedGKeys! }
    private lazy var game = GameKeys(device, supported: kind.gameMode && layout != nil, experimental: kind.gameModeExperimental)
    private lazy var gameBox: GameModeBox? = layout.flatMap { layout in game.map { GameModeBox(layout: layout, game: $0, page: self) } }
    private var gameArea = NSView()
    // Settings, Bindings (the G keys) and Game, those this keyboard has.
    private lazy var views = ["Settings"] + (kind.gKeys != nil ? ["Bindings"] : []) + (game != nil ? ["Game"] : [])
    private lazy var viewPick = NSSegmentedControl(labels: views, trackingMode: .selectOne, target: nil, action: nil)
    private var openView = "Settings"
    private var showingKeys: Bool { openView == "Bindings" }
    private lazy var idleBox: IdleBox? = kind.profile && !kind.noIdleTimes ? IdleBox(offersNever: false) : nil
    private var lightingRow = NSView(), idleArea = NSView(), idleHeight: NSLayoutConstraint?
    private let slotPicker = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var buttonRows = ButtonRows(actions: Bindings.keyboardActions)
    private var gKeysBox = NSView(), lightingBox = NSView(), keysPicture: NSView?

    private let effect = NSPopUpButton(), color = NSColorWell(), direction = NSPopUpButton()
    private let speed = Ui.slider(), intensity = Ui.slider(), level = Ui.slider()
    private let intensityValue = Ui.value(), levelValue = Ui.value()
    private let save = NSButton(title: "Save to keyboard", target: nil, action: nil)
    private let revert = NSButton(title: "Revert", target: nil, action: nil)
    private let backups = NSButton(title: "Backups", target: nil, action: nil)
    private var rows: [String: NSGridRow] = [:]
    private lazy var layout = KeyLayout.forKeyboard(device)
    private lazy var picture = layout.map(KeyPicture.init)
    // G-Lite's own effects after the keyboard's, drawn key by key through 0x8081 (LiveEffects).
    private lazy var effects = G515Profile.effects + (picture != nil && device.has(0x8081) ? LiveEffects.all : [])
    private lazy var runner = picture.map { LiveRunner(page: self, picture: $0, claim: { try G915Lighting.claim($0) }, release: { try G915Lighting.release($0) }) }
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
            guard let self = self, let picture = self.picture, let key = keys.first else { return }
            if self.screening { self.screenBox.give(keys.map { picture.idOf($0) }); return }
            // A click on the keys or the bar picks that part, with Per zone on.
            if self.bar != nil && !self.live { self.part = picture.onBar(key) ? 2 : 1; self.refresh() }
        }
        return box
    }()
    // The hint in the title, so the page keeps Windows' height.
    private lazy var screenArea: NSView = Ui.box(picture == nil ? "Screen" : "Screen: pick an area, then click or drag over keys to give them to it", screenBox)
    private var screening: Bool { current.effect == 0xFE }
    private var note = NSTextField()

    private var rememberedKey: String { "lighting." + device.settingsKey }
    private var backupId: String { device.settingsKey }
    // Up and Down once the keyboard's Wave lists them (G915Lighting.clusters), as on Windows.
    private var directions: [Int] { live ? LiveEffects.directions : verticalWave ? [6, 1, 7, 2, 3, 8] : [6, 1, 3, 8] }
    private var directionNames: [String] {
        live ? LiveEffects.directionNames
            : verticalWave ? ["Left", "Right", "Up", "Down", "Center out", "Center in"] : ["Left", "Right", "Center out", "Center in"]
    }

    override init(device: FoundDevice, hidpp: (() throws -> Hidpp)?) {
        kind = KeyboardKind.of(device)
        super.init(device: device, hidpp: hidpp)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        effect.addItems(withTitles: effects.map { $0.name })
        effect.autoenablesItems = false
        for control in [effect, direction] as [NSControl] { control.target = self; control.action = #selector(changed) }
        for control in [speed, intensity, level] { control.target = self; control.action = #selector(changed) }
        color.target = self; color.action = #selector(changed)
        save.target = self; save.action = #selector(saveClicked); save.keyEquivalent = "\r"
        revert.target = self; revert.action = #selector(revertClicked)
        backups.target = self; backups.action = #selector(showBackups)
        color.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for popup in [effect, direction] { popup.widthAnchor.constraint(equalToConstant: 160).isActive = true }
        // Narrower beside the When idle box.
        for slider in [speed, intensity, level] { slider.widthAnchor.constraint(equalToConstant: idleBox == nil ? 280 : 200).isActive = true }
        for value in [intensityValue, levelValue] { value.widthAnchor.constraint(equalToConstant: 44).isActive = true }

        viewPick.target = self; viewPick.action = #selector(viewPicked)
        viewPick.selectedSegment = 0
        slotPicker.target = self; slotPicker.action = #selector(slotPicked)
        slotPicker.isHidden = true
        slotPicker.setAccessibilityLabel("Onboard profile")
        buttonRows.assigned = { [weak self] row, binding in
            guard let self = self, self.gKeys != nil, row < self.gKeys!.count, !self.live else { return }
            self.gKeys![row] = binding
            self.gKeyEdits += 1
            self.edited()
            self.refresh()
            self.showStatus()
        }
        perZone.target = self; perZone.action = #selector(perZoneToggled)
        perZone.setAccessibilityLabel("Lighting per zone")
        partPicker.target = self; partPicker.action = #selector(partPicked)
        partPicker.setAccessibilityLabel("Part")
        picture?.bar = kind.bar
        let zoneRow = NSStackView(views: [perZone, Ui.label("Per zone"), partPicker])
        zoneRow.spacing = 10
        let grid = NSGridView(views: [
            [Ui.label("Zone"), zoneRow],
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
        for (i, name) in ["zone", "effect", "color", "speed", "intensity", "direction", "level"].enumerated() { rows[name] = grid.row(at: i) }
        // A switch has no baseline, so the Zone row is centred instead.
        rows["zone"]?.rowAlignment = .none
        rows["zone"]?.yPlacement = .center
        note = Ui.hint(kind.profile ? "Changes show at once. Save to keyboard keeps them in its profile, so they stay without G-Lite."
                           : "Changes show at once. G-Lite sets them again each time it starts; the keyboard doesn't keep them.")
        runner?.screenSetup = screenBox.setup
        keysPicture = picture.map { pictureBox($0) }
        lightingBox = Ui.box("Lighting", grid)
        lightingRow = lightingBox
        if let idleBox = idleBox {
            idleBox.changed = { [weak self] idle, dim, sleep in
                guard let self = self else { return }
                self.current.idle = idle; self.current.dim = dim; self.current.sleep = sleep
                self.unknownStored = false
                self.dirty = true
                self.edited()
                self.refresh()
                self.showStatus()
            }
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .vertical)
            idleArea = Ui.box("When idle", Ui.column([idleBox, spacer]))
            let row = NSStackView(views: [lightingBox, idleArea])
            row.alignment = .top
            idleHeight = idleArea.heightAnchor.constraint(equalTo: lightingBox.heightAnchor)
            lightingRow = row
        }
        gKeysBox = Ui.box("G keys", buttonRows)
        gKeysBox.isHidden = true
        if let gameBox = gameBox { gameArea = Ui.box("Game mode", gameBox) }
        gameArea.isHidden = true
        view = Ui.page(header: header, body: (keysPicture.map { [$0] } ?? []) + [lightingRow, screenArea, note, gKeysBox, gameArea], status: status,
                       buttons: kind.profile ? [slotPicker, backups, revert, save] : [revert])
        header.show(device)
        refresh()
        load()
    }

    // ---- showing ----

    private func refresh() {
        // A live effect draws the picture itself (LiveRunner).
        let known = loaded && !(unknownStored && !dirty)
        if !live { picture?.display(known ? current : nil, brightness, bar: bar) }
        let viewed = target
        let info = effects.first { $0.id == viewed.effect } ?? G515Profile.effects[1]
        let keys = clusters.map { $0[G915Lighting.keys($0)] }
        for (index, item) in effect.itemArray.enumerated() {
            let id = effects[index].id
            // The bar has no Ripple, and a live effect covers the whole keyboard.
            item.isEnabled = part == 2 ? id != 0x17 && !LiveEffects.isLive(id)
                : LiveEffects.isLive(id) || (keys.map { G915Lighting.pick(id, $0, loose: false) >= 0 } ?? true)
        }
        effect.selectItem(at: unknownStored && !dirty ? -1 : effects.firstIndex { $0.id == viewed.effect } ?? 1)
        rows["zone"]?.isHidden = !parts || live
        perZone.state = bar != nil ? .on : .off
        perZone.isEnabled = known
        partPicker.isEnabled = known && bar != nil
        partPicker.selectedSegment = bar != nil ? part - 1 : -1
        picture?.part = live || !known || bar == nil ? 0 : part
        rows["color"]?.isHidden = !info.color
        rows["speed"]?.isHidden = !info.speed
        rows["intensity"]?.isHidden = !(live && info.intensity || !live && kind.intensity && info.intensity)
        if gKeys == nil && showingKeys { openView = "Settings" }
        let settings = openView == "Settings"
        keysPicture?.isHidden = !settings
        lightingRow.isHidden = !settings
        idleBox?.show(current, enabled: loaded)
        // A live effect isn't saved, so its idle times wouldn't be either.
        idleArea.isHidden = live
        idleHeight?.isActive = !live
        screenArea.isHidden = !screening || !settings
        screenBox.showing(screening && settings)
        // A live effect runs only while G-Lite does, which the status line says.
        note.isHidden = screening || !settings
        gKeysBox.isHidden = !showingKeys
        gameArea.isHidden = openView != "Game"
        gameBox?.show()
        if let bindings = views.firstIndex(of: "Bindings") { viewPick.setEnabled(gKeys != nil, forSegment: bindings) }
        viewPick.selectedSegment = views.firstIndex(of: openView) ?? 0
        if let names = kind.gKeys {
            // A live effect stops Save, so the G keys wait until it's off.
            buttonRows.show(names: names, bindings: gKeys ?? [], editable: loaded && gKeys != nil && !live,
                            note: live ? "Turn off the \(info.name) effect to change the G keys."
                                : kind.gKeysExperimental ? "Experimental: changes take effect once saved to the keyboard."
                                : "Changes take effect once saved to the keyboard.")
        }
        showSlots()
        rows["direction"]?.isHidden = !info.direction
        color.color = NSColor(rgb: viewed.color)
        if info.speed {
            speed.doubleValue = (Double(info.maxPeriod - viewed.period) * 100 / Double(info.maxPeriod - info.minPeriod)).rounded()
        }
        intensity.integerValue = viewed.intensity
        intensityValue.stringValue = "\(viewed.intensity)%"
        direction.removeAllItems()
        direction.addItems(withTitles: directionNames)
        direction.selectItem(at: directions.firstIndex(of: viewed.direction) ?? -1)
        level.integerValue = brightness
        levelValue.stringValue = "\(brightness)%"
        // A live effect runs in G-Lite: the keyboard can't keep it.
        save.isEnabled = loaded && kind.profile && (dirty && !unknownStored || gKeysChanged) && !live && !takenOver
        revert.isEnabled = loaded && (dirty || !Settings.get(rememberedKey).isEmpty)
        for control in [effect, color, speed, intensity, direction, level] as [NSControl] { control.isEnabled = loaded }
    }

    // ---- edits ----

    @objc private func changed(_ sender: NSControl) {
        var light = target
        if sender === effect, effect.indexOfSelectedItem >= 0 {
            let picked = effects[effect.indexOfSelectedItem]
            if picked.id != light.effect {
                // A live effect covers the whole keyboard, so the bar's own lighting goes.
                if LiveEffects.isLive(picked.id) { bar = nil; part = 0; light = current }
                light.effect = picked.id
                if picked.speed { light.period = picked.defaultPeriod }
                if LiveEffects.isLive(picked.id) { light.direction = LiveEffects.defaultDirection(picked.id) }
                else if picked.direction && !directions.contains(light.direction) { light.direction = 1 }
            }
        }
        let info = effects.first { $0.id == light.effect } ?? G515Profile.effects[1]
        if sender === color { light.color = color.color.rgb }
        if sender === speed && info.speed {
            light.period = info.maxPeriod - Int((Double(info.maxPeriod - info.minPeriod) * speed.doubleValue / 100).rounded())
        }
        if sender === intensity { light.intensity = max(1, intensity.integerValue) }
        if sender === direction, direction.indexOfSelectedItem >= 0 { light.direction = directions[direction.indexOfSelectedItem] }
        target = light
        if sender === level { brightness = snapped(level.integerValue) }
        unknownStored = false
        dirty = true
        edited()
        refresh()
        status.show("")
        // At most one preview every 120 ms during a drag, as on Windows.
        if previewTimer == nil {
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                self?.previewTimer = nil
                self?.apply()
            }
        }
    }

    // Per zone on: the bar starts as a copy of the keys (Static instead of Ripple, which it lacks); off: it follows the keys again.
    @objc private func perZoneToggled() {
        if (perZone.state == .on) == (bar != nil) || live { refresh(); return }
        if perZone.state == .on {
            var copy = current
            if copy.effect == 0x17 { copy.effect = 0x01 }
            bar = copy
            part = 1
        } else {
            bar = nil
            part = 0
        }
        changed(perZone)
    }

    @objc private func partPicked() {
        guard bar != nil, partPicker.selectedSegment >= 0 else { return }
        part = partPicker.selectedSegment + 1
        refresh()
    }

    // The light bar's text after "#" (app/KeyboardPage.cs, BarText and BarFrom): Ripple, Screen and the live effects become Static.
    private func barText(_ level: Int) -> String { bar.map { "#" + $0.toText(level) } ?? "" }

    private func barFrom(_ text: String) -> Lighting? {
        let pieces = GameModeKeys.split(text).preset.components(separatedBy: "~")[0].components(separatedBy: "|")[0].components(separatedBy: "#")
        guard parts, pieces.count > 1, var (lighting, _) = Lighting.fromText(pieces[1]) else { return nil }
        if lighting.effect == 0x17 || G515Profile.effect(lighting.effect) == nil { lighting.effect = 0x01 }
        return lighting
    }

    // The G815 keeps only some brightness levels and drops any other to the one below, so the slider does the same.
    private func snapped(_ value: Int) -> Int {
        guard let levels = kind.brightnessLevels else { return value }
        return levels.filter { $0 <= value }.max() ?? 0
    }

    private func apply() {
        let lighting = current, level = brightness, others = bar
        previewSequence += 1
        let startedAt = previewSequence
        var sent = false
        if live {
            runner?.run(lighting)
            Settings.set(rememberedKey, lighting.toText(level))
            run({ hidpp in if level != (try G515Profile.brightness(hidpp)) { try G515Profile.setBrightness(hidpp, level) } },
                done: { self.refresh(); self.status.show(self.runner?.problem ?? "A live effect runs while G-Lite does: the keyboard doesn't keep it") })
            return
        }
        runner?.stop()
        run({ hidpp in
            if startedAt != self.previewSequence { return }
            let clusters = try self.clusters ?? G915Lighting.clusters(hidpp).clusters
            self.clusters = clusters
            if level != (try G515Profile.brightness(hidpp)) { try G515Profile.setBrightness(hidpp, level) }
            try G915Lighting.claim(hidpp)
            try G915Lighting.preview(hidpp, clusters, lighting, others)
            sent = true
        }, done: {
            guard startedAt == self.previewSequence else { return }
            if sent { Settings.set(self.rememberedKey, lighting.toText(level) + (others.map { "#" + $0.toText(level) } ?? "")) }
            self.refresh()
            self.status.show(self.kind.profile && self.dirty ? "Applied to the keyboard, not saved on it yet" : "")
        })
    }

    // The Windows prefixes: the G915 and G915 TKL share profile.g915., the G815 and the G512 X 75 have their own.
    override var presetPrefix: String {
        let upper = device.name.uppercased()
        return device.isG915 ? (upper.contains("G815") ? "profile.g815." : "profile.g915.")
            : upper.contains("G512 X 75") ? "profile.g512x." : "profile." + device.settingsKey + "."
    }

    override func presetText() -> String? {
        current.toText(brightness) + barText(brightness) + (screening ? "|" + screenBox.setup.toText() : "") + (game?.presetText ?? "")
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
        if LiveEffects.isLive(current.effect) && !effects.contains(where: { $0.id == current.effect }) { current.effect = 0x01 }
        bar = LiveEffects.isLive(current.effect) ? nil : barFrom(text)
        part = bar == nil ? 0 : 1
        brightness = snapped(max(0, min(100, level)))
        unknownStored = false
        dirty = true
        refresh()
        apply()
    }

    override func revertWithoutPreset() { backToKeyboard() }

    // The G keys aren't in presets (they belong to an onboard profile), so Revert with a preset picked brings them back too.
    @objc private func revertClicked() {
        dropGKeyEdits()
        if revertToPreset() { refresh(); showStatus(); return }
        backToKeyboard()
    }

    private func dropGKeyEdits() {
        buttonRows.stopRecording()
        gKeys = storedGKeys
        gKeyEdits += 1
    }

    // ---- views, slots ----

    override var headerAccessory: NSView? { views.count > 1 ? viewPick : nil }

    @objc private func viewPicked() {
        let index = viewPick.selectedSegment
        openView = index >= 0 && index < views.count && (views[index] != "Bindings" || gKeys != nil) ? views[index] : "Settings"
        if !showingKeys { buttonRows.stopRecording() }
        refresh()
    }

    // For --snapshot.
    func showKeys() { openView = gKeys != nil ? "Bindings" : "Settings"; refresh() }
    func showGame() { openView = game != nil ? "Game" : "Settings"; refresh() }

    private func showSlots() {
        guard kind.profile else { return }
        let shown = slots.count > 1
        slotPicker.segmentCount = slots.count
        for (index, sector) in slots.enumerated() { slotPicker.setLabel("M\(sector)", forSegment: index); slotPicker.setWidth(0, forSegment: index) }
        slotPicker.selectedSegment = slots.firstIndex(of: running) ?? -1
        slotPicker.isHidden = !shown
        slotPicker.isEnabled = loaded
        save.title = shown && slots.contains(running) ? "Save to M\(running)" : "Save to keyboard"
    }

    // The running profile's own M key sends nothing and leaves 0x8071 control as it was (tried on the G815), so a live effect can't
    // follow it; picking that profile here stops the effect instead (app/KeyboardPage.cs).
    @objc private func slotPicked() {
        let index = slotPicker.selectedSegment
        guard index >= 0 && index < slots.count else { return }
        switched(to: slots[index], picked: true, again: live && slots[index] == running)
    }

    // 0x8100 event fn 0: the keyboard runs another profile (an M key). The G815 sends it, per Windows.
    override func heard(_ report: [UInt8]) {
        guard report.count >= 4, report[3] >> 4 == 0, profilesFeature != 0, report[2] == profilesFeature else { return }
        checkSlot()
    }

    private func checkSlot() {
        guard kind.profile, slots.count >= 2 || takenOver, !checkingSlot else { return }
        checkingSlot = true
        queue.async {
            var now = 0, host = false
            if let hidpp = try? self.connection(), let feature = try? hidpp.featureIndex(0x8100),
               let reply = try? hidpp.callUnlogged(feature, 4) {
                now = Int(reply[0]) << 8 | Int(reply[1])
                if now == 0 { host = (try? hidpp.callUnlogged(feature, 2))?[0] != 1 }
            }
            DispatchQueue.main.async { self.slotRead(now, host) }
        }
    }

    private func slotRead(_ now: Int, _ host: Bool) {
        checkingSlot = false
        if host && !takenOver {
            Log.add(device.shortName, "found", "the keyboard left its onboard profiles")
            takenOver = true
            slots = []
            refresh()
            showStatus()
            return
        }
        if now != 0 && takenOver {
            Log.add(device.shortName, "found", "the keyboard runs its onboard profiles again")
            takenOver = false
            // Back on another profile than before is an M-key switch.
            if running != 0 && now != running { switched(to: now, picked: false) } else { load() }
            return
        }
        if now == 0 || now == running { return }
        Log.add(device.shortName, "found", "M\(now) picked on the keyboard")
        switched(to: now, picked: false)
    }

    // Another onboard profile runs, picked here or with an M key. The keyboard shows that profile's saved lighting, so a lighting not
    // saved goes, as on the keyboard alone, with the preset and the G key edits (app/KeyboardPage.cs, SlotSwitched).
    private func switched(to sector: Int, picked: Bool, again: Bool = false) {
        if sector == running && !again { return }
        if picked { logAction("Switch to M\(sector)") }
        running = sector
        if live { runner?.stop(); current = stored ?? Lighting() }
        dropPreset()
        Settings.remove(rememberedKey)
        dirty = false
        dropGKeyEdits()
        previewSequence += 1
        previewTimer?.invalidate(); previewTimer = nil
        refresh()
        run({ hidpp in
            try G915Lighting.release(hidpp)
            if picked { try hidpp.call(try hidpp.featureIndex(0x8100), 3, [UInt8(sector >> 8 & 0xFF), UInt8(sector & 0xFF)]) }
        })
        load()
    }

    private func showStatus() {
        if takenOver { status.show("G HUB or another app has taken over the keyboard. Close it to save.", error: true); return }
        if live { status.show(runner?.problem ?? "A live effect runs while G-Lite does: the keyboard doesn't keep it"); return }
        let place = slots.contains(running) && slots.count > 1 ? "M\(running)" : "the keyboard"
        status.show(unknownStored && !dirty ? "The keyboard runs an effect G-Lite doesn't know."
                    : dirty ? "Not saved on the keyboard yet" : gKeysChanged ? "G keys not saved to \(place)" : "")
    }

    // Back to the keyboard's own lighting: the remembered lighting is dropped and the keys given back.
    private func backToKeyboard() {
        runner?.stop()
        Settings.remove(rememberedKey)
        bar = nil
        part = 0
        previewSequence += 1
        previewTimer?.invalidate(); previewTimer = nil
        dirty = false
        run({ try G915Lighting.release($0) }, done: { self.load() })
    }

    // ---- device ----

    private func load() {
        dirty = false
        status.show("Reading the keyboard…")
        let keptText = Settings.get(rememberedKey)
        let kept = Lighting.fromText(keptText.components(separatedBy: "#")[0]), keptBar = barFrom(keptText)
        let startedAt = previewSequence, kind = self.kind
        var read: [[UInt8]] = [], vertical = false, saved: Lighting?, dropped = false, readLevel = 100, code = -1
        var slotsRead: [Int] = [], runningRead = 0, hostRead = false, keysRead: [[UInt8]]?, profiles: UInt8 = 0
        let keyEditsAtStart = gKeyEdits
        run({ hidpp in
            code = self.layoutCode(hidpp)
            self.game?.sendAgain(hidpp, self.device.shortName)
            (read, vertical) = try G915Lighting.clusters(hidpp)
            if kind.profile, let (found, now, onboard) = try? G915Lighting.slots(hidpp) {
                slotsRead = found; runningRead = now; hostRead = !onboard
                profiles = (try? hidpp.featureIndex(0x8100)) ?? 0
            }
            // The saved lighting only when nothing is remembered, since a remembered lighting replaces it; the G keys always.
            // Optional: any failure leaves the screen on live lighting.
            if kind.profile && (kept == nil || kind.gKeys != nil), let (profile, _, buttons) = try? G915Lighting.readProfile(hidpp) {
                if kept == nil { saved = G915Lighting.decode(profile, G915Lighting.keys(read), intensity: kind.intensity) }
                if let names = kind.gKeys, !kind.gKeysExperimental || buttons == names.count + 3 {
                    keysRead = G915Lighting.readButtons(profile, names.count)
                }
            }
            // A remembered live effect starts again on the main queue, once the screen shows it (done below).
            if let (lighting, savedLevel) = kept, startedAt == self.previewSequence, !LiveEffects.isLive(lighting.effect) {
                let now = try G515Profile.brightness(hidpp)
                if savedLevel >= 0 && savedLevel <= 100 && savedLevel != now {
                    try G515Profile.setBrightness(hidpp, savedLevel)
                }
                try G915Lighting.claim(hidpp)
                do { try G915Lighting.preview(hidpp, read, lighting, keptBar) } catch GLiteError.refused {
                    try G915Lighting.release(hidpp)
                    dropped = true
                }
            }
            readLevel = try G515Profile.brightness(hidpp)
        }, done: {
            if dropped { Settings.remove(self.rememberedKey) }
            self.slots = slotsRead
            self.running = runningRead
            self.profilesFeature = profiles
            self.takenOver = hostRead
            // G key edits made during the read are kept, unless the keys are another slot's now.
            let sameSlot = keysRead != nil && runningRead == self.gKeysSector
            self.storedGKeys = keysRead
            if keyEditsAtStart == self.gKeyEdits || self.gKeys == nil || !sameSlot {
                self.buttonRows.stopRecording()
                self.gKeys = keysRead
            }
            self.gKeysSector = runningRead
            self.applyLayout(self.picture, self.layout, code)
            self.clusters = read
            self.verticalWave = vertical
            let lighting = dropped ? saved : kept?.0 ?? saved
            self.stored = lighting
            self.unknownStored = lighting == nil
            self.dirty = kept != nil && !dropped && kind.profile
            if let lighting = lighting { self.current = lighting }
            self.bar = dropped || kept == nil || LiveEffects.isLive(self.current.effect) ? nil : keptBar
            self.part = self.bar == nil ? 0 : 1
            if let lighting = lighting, LiveEffects.isLive(lighting.effect), self.effects.contains(where: { $0.id == lighting.effect }) {
                self.runner?.run(lighting)
            }
            self.brightness = readLevel
            self.storedBrightness = readLevel
            self.loaded = true
            self.refresh()
            self.showStatus()
            self.loaded()
        })
    }

    override func giveBack() { runner?.stop() }

    override func scanned() {
        guard let game = game, !game.keys.isEmpty else { return }
        queue.async { if let hidpp = try? self.connection() { game.sendAgain(hidpp, self.device.shortName) } }
    }

    // Only G keys changed: the lighting stays as saved, which also covers one G-Lite can't read.
    @objc private func saveClicked() {
        let lighting = current, kind = self.kind, lightingToo = dirty && !unknownStored
        let keys = gKeysChanged ? gKeys : nil, keysWere = storedGKeys, keysSector = gKeysSector, keyEditsAtStart = gKeyEdits
        previewTimer?.invalidate(); previewTimer = nil
        previewSequence += 1
        save.isEnabled = false
        status.show("Saving…")
        logAction("Save to keyboard")
        run({ hidpp in
            let clusters = try self.clusters ?? G915Lighting.clusters(hidpp).clusters
            let (profile, sector, _) = try G915Lighting.readProfile(hidpp)
            var built = profile
            if lightingToo {
                built = try G915Lighting.build(profile, clusters, lighting, nil, idleTimes: !kind.noIdleTimes)
            }
            if keys != nil && sector != keysSector {
                throw GLiteError.refused("The keyboard switched profiles: read it again before saving the G keys")
            }
            if let keys = keys { built = G915Lighting.withButtons(built, keys, keysWere) }
            try Backups.save(self.backupId, data: [String(format: "%04X", sector): profile], who: self.device.shortName)
            try G915Lighting.store(hidpp, sector, built, reloadThroughHostMode: kind.reloadThroughHostMode)
        }, done: {
            if lightingToo {
                Settings.remove(self.rememberedKey)
                self.stored = lighting
                self.dirty = false
            }
            if let keys = keys {
                self.storedGKeys = keys
                if keyEditsAtStart == self.gKeyEdits { self.gKeys = keys }
            }
            self.refresh()
            self.status.show("Saved to the keyboard")
        })
    }

    // A backup holds the whole profile, G keys included; the factory restore copies the factory copy's lighting and idle times, and
    // its G keys on a keyboard whose G keys G-Lite edits, so the rest of the profile (M1-M3, G-shift, macros) stays.
    private func restore(_ entry: Backups.Entry?) {
        let backup = entry.flatMap { LiveKeyboardPage.backupSector($0) }
        let when = entry.map { DateFormatter.localizedString(from: $0.when, dateStyle: .medium, timeStyle: .short) }
        let kind = self.kind, keyCount = kind.gKeys?.count ?? 0
        let what = when.map { "the backup from \($0)" } ?? (keyCount > 0 ? "the factory profile" : "the factory lighting")
        previewSequence += 1
        save.isEnabled = false
        status.show("Restoring \(what)…")
        logAction("Restore \(what)")
        run({ hidpp in
            let (now, sector, _) = try G915Lighting.readProfile(hidpp)
            if let backup = backup, backup.sector != sector {
                throw GLiteError.refused("The keyboard runs another profile than the one in this backup")
            }
            var profile = try backup?.data ?? G915Lighting.factoryLighting(hidpp, sector, now)
            if backup == nil && keyCount > 0 { profile = try G915Lighting.factoryButtons(hidpp, sector, profile, keyCount) }
            try Backups.save(self.backupId, data: [String(format: "%04X", sector): now], who: self.device.shortName)
            try G915Lighting.store(hidpp, sector, profile, reloadThroughHostMode: kind.reloadThroughHostMode)
        }, done: {
            Settings.remove(self.rememberedKey)
            self.load()
            self.status.show("Restored \(what)")
        })
    }

    static func backupSector(_ entry: Backups.Entry) -> (sector: Int, data: [UInt8])? {
        guard entry.data.count == 1, let (key, value) = entry.data.first, let data = value, let sector = Int(key, radix: 16),
              sector > 0 && sector < 0x100 && MouseProtocol.valid(data) else { return nil }
        return (sector, data)
    }

    @objc private func showBackups() {
        let menu = NSMenu()
        menu.addItem(withTitle: kind.gKeys != nil ? "Restore the factory profile" : "Restore the factory lighting", action: #selector(restoreFactory),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        let entries = Backups.list(backupId)
        if entries.isEmpty {
            menu.addItem(withTitle: "No backups yet: one is made before each save", action: nil, keyEquivalent: "").isEnabled = false
        }
        for (index, entry) in entries.enumerated() {
            let usable = LiveKeyboardPage.backupSector(entry)
            let lighting = usable.flatMap { G915Lighting.decode($0.data, clusters.map(G915Lighting.keys) ?? 1) }
            let text = usable == nil ? "damaged, can't be restored"
                : lighting.flatMap { G515Profile.effect($0.effect)?.name } ?? "an effect G-Lite doesn't know"
            let item = NSMenuItem(title: DateFormatter.localizedString(from: entry.when, dateStyle: .medium, timeStyle: .short) + ": " + text
                                  + (entry.first ? " (the first)" : ""), action: usable != nil ? #selector(restoreBackup) : nil, keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: backups.bounds.height + 4), in: backups)
    }

    @objc private func restoreFactory() { confirm(kind.gKeys != nil ? "Restore the factory profile?" : "Restore the factory lighting?") { self.restore(nil) } }

    @objc private func restoreBackup(_ sender: NSMenuItem) {
        let entries = Backups.list(backupId)
        guard sender.tag < entries.count else { return }
        confirm("Restore this backup?") { self.restore(entries[sender.tag]) }
    }

    private func confirm(_ question: String, _ then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = "The keyboard's profile is backed up first."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { then() } }
    }
}
