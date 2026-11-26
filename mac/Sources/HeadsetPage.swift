import AppKit
import AVFoundation

// The headset screen (app/HeadsetPage.cs): sidetone, auto-off and the equalizer (experimental), applied at once; the battery from
// its voltage. The equalizer's bands are vertical sliders side by side, where Windows has a row each: ten rows don't fit the page.
// Test sidetone opens the headset's microphone for 30 s (the dongle plays sidetone only while an app uses it), after the
// microphone permission.
// shortcut: no headset picture.
final class HeadsetPage: DevicePage {
    private var current = HeadsetSettings(), sent = HeadsetSettings()
    private var state: HeadsetProtocol.State?
    private var refreshing = false, dirty = false, sequence = 0
    private var debounce: Timer?
    private var offChoices = HeadsetProtocol.offMinutes

    private let sidetone = Ui.slider(), sideValue = Ui.value()
    private let off = NSPopUpButton()
    private let battery = Ui.secondary(""), firmware = Ui.secondary("")
    private var sideHead = NSTextField(), offHead = Ui.secondary("Turn off after")
    private let testButton = NSButton(title: "Test sidetone", target: nil, action: nil)
    private var microphone: MicrophoneCapture?, testTimer: Timer?
    private static let maxBands = 15
    private let bandSliders: [NSSlider] = (0..<maxBands).map { _ in
        let slider = NSSlider(value: 0, minValue: -12, maxValue: 12, target: nil, action: nil)
        slider.isVertical = true
        slider.isContinuous = true
        return slider
    }
    private let bandValues: [NSTextField] = (0..<maxBands).map { _ in Ui.value() }
    private let bandNames: [NSTextField] = (0..<maxBands).map { _ in Ui.value() }
    private var bandColumns: [NSView] = []
    private let flatButton = NSButton(title: "Flat", target: nil, action: nil)
    private var equalizerBox = NSView()
    // A band being dragged writes RAM only; once let go, RAM and EEPROM (persistence 1). keptBands: the last written to both.
    private var bandHeld = false
    private var keptBands: [Int]?

    override func loadView() {
        sidetone.target = self; sidetone.action = #selector(sidetoneMoved)
        off.target = self; off.action = #selector(offPicked)
        off.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let (sideRow, head) = Ui.sliderRow("Sidetone", sidetone, sideValue)
        sideHead = head
        testButton.target = self; testButton.action = #selector(testClicked)
        let sound = Ui.column([sideRow, Ui.hint("How much of your own voice you hear while you talk. It works while an app is using the "
                                                + "microphone, like a call or a voice chat."), testButton])
        let power = Ui.column([Ui.column([offHead, off], spacing: 4), Ui.column([Ui.secondary("Battery"), battery], spacing: 4),
                               Ui.column([Ui.secondary("Firmware"), firmware], spacing: 4)])
        for (i, slider) in bandSliders.enumerated() {
            slider.tag = i
            slider.target = self; slider.action = #selector(bandMoved(_:))
            slider.heightAnchor.constraint(equalToConstant: 110).isActive = true
            let column = NSStackView(views: [bandValues[i], slider, bandNames[i]])
            column.orientation = .vertical
            column.spacing = 4
            column.widthAnchor.constraint(equalToConstant: 44).isActive = true
            for label in [bandValues[i], bandNames[i]] { label.alignment = .center }
            bandColumns.append(column)
        }
        let bands = NSStackView(views: bandColumns)
        bands.spacing = 0
        flatButton.target = self; flatButton.action = #selector(flatClicked)
        equalizerBox = Ui.box("Equalizer", Ui.column([
            Ui.hint("Experimental. The headset stores these bands, but it hasn't been heard to play them yet: G HUB applies its equalizer "
                    + "on the PC. Changes are sent to the headset right away."), bands, flatButton]))
        equalizerBox.isHidden = true
        view = Ui.page(header: header, body: [Ui.box("Sound", sound), Ui.box("Power", power), equalizerBox], status: status, buttons: [])
        header.show(device)
        refresh()
        load()
    }

    // ---- Test sidetone ----

    @objc private func testClicked() {
        if microphone != nil { stopTest(); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startTest()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { if granted { self.startTest() } else { self.refused() } } }
        default: refused()
        }
    }

    private func refused() {
        status.show("G-Lite isn't allowed to use the microphone: turn it on in System Settings, Privacy & Security, Microphone.", error: true)
    }

    private func startTest() {
        guard let input = MicrophoneCapture.find(device.shortName) else {
            status.show("Couldn't find the headset's microphone in macOS", error: true)
            return
        }
        do { microphone = try MicrophoneCapture(input) } catch { status.show("\(error)", error: true); return }
        logAction("Test sidetone")
        testTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in self?.stopTest() }
        testButton.title = "Stop the test"
        testButton.keyEquivalent = "\r"
        status.show("Talk now. You hear yourself at the sidetone level. The test stops after 30 s.")
    }

    private func stopTest() {
        testTimer?.invalidate()
        testTimer = nil
        microphone?.stop()
        microphone = nil
        testButton.title = "Test sidetone"
        testButton.keyEquivalent = ""
        status.show(state == nil ? "" : dirty ? "Applied to the headset" : "Matches the headset")
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if microphone != nil { stopTest() }
    }

    override func giveBack() { microphone?.stop() }

    // The auto-off headsets: the PRO X Wireless (0ABA), the G PRO X 2's and G733's dongles (Windows' list, app/FoundDevice.cs).
    private var hasAutoOff: Bool { [0x0AAA, 0x0ABA, 0x0AFB, 0x0AFC].contains(device.port?.productId ?? 0) && device.has(0x1F20) }

    @objc private func sidetoneMoved() {
        current.sidetone = sidetone.integerValue
        changed(now: false)
    }

    @objc private func bandMoved(_ slider: NSSlider) {
        guard var bands = current.bands, slider.tag < bands.count else { return }
        bands[slider.tag] = slider.integerValue
        current.bands = bands
        let type = NSApp.currentEvent?.type
        bandHeld = type == .leftMouseDown || type == .leftMouseDragged
        changed(now: !bandHeld)
    }

    @objc private func flatClicked() {
        guard let bands = current.bands else { return }
        current.bands = [Int](repeating: 0, count: bands.count)
        changed(now: true)
    }

    @objc private func offPicked() {
        guard off.indexOfSelectedItem >= 0 else { return }
        current.autoOffMinutes = offChoices[off.indexOfSelectedItem]
        changed(now: true)
    }

    private func changed(now: Bool) {
        if refreshing || state == nil { return }
        dirty = true
        sequence += 1
        edited()
        refresh()
        // The test's instructions stay while it runs.
        if microphone == nil { status.show("Applied to the headset") }
        // While a slider moves, sent at most every 120 ms rather than once it stops.
        if now { debounce?.invalidate(); debounce = nil; send() }
        else if debounce == nil {
            debounce = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in self?.debounce = nil; self?.send() }
        }
    }

    // The Windows text: sidetone, the auto-off minutes, then the bands.
    override func presetText() -> String? { current.text }

    // A preset's bands count only on a headset with as many; otherwise the bands stay as they are.
    override func applyPreset(_ text: String) {
        guard var settings = HeadsetSettings.fromText(text) else { return }
        settings.sidetone = max(0, min(100, settings.sidetone))
        let range = state?.range ?? 0
        if let bands = settings.bands, let now = current.bands, bands.count == now.count {
            settings.bands = bands.map { max(-range, min(range, $0)) }
        } else { settings.bands = current.bands }
        current = settings
        changed(now: true)
    }

    override func revertWithoutPreset() {
        guard let state = state else { return }
        current = state.set
        changed(now: true)
        dirty = false
    }

    private func send() {
        guard let state = state else { return }
        let want = current, before = sent, held = bandHeld
        sequence += 1
        let startedAt = sequence
        run({ hidpp in
            if startedAt != self.sequence { return }
            if state.hasSidetone && want.sidetone != before.sidetone { try HeadsetProtocol.setSidetone(hidpp, want.sidetone) }
            if state.hasOff && want.autoOffMinutes >= 0 && want.autoOffMinutes != before.autoOffMinutes {
                try HeadsetProtocol.setOff(hidpp, want.autoOffMinutes)
            }
            if state.frequencies != nil, let bands = want.bands,
               bands != before.bands || !held && bands != self.keptBands {
                try HeadsetProtocol.setEqualizer(hidpp, bands, keep: !held)
                if !held { self.keptBands = bands }
            }
            self.sent = want
        })
    }

    private func load() {
        status.show("Reading the headset…")
        let autoOff = hasAutoOff || device.key.hasPrefix("demo|")
        var read: HeadsetProtocol.State?
        run({ read = try HeadsetProtocol.read($0, autoOff: autoOff) }, done: {
            guard let read = read else { return }
            self.state = read
            self.current = read.set
            self.sent = read.set
            self.keptBands = read.set.bands
            self.dirty = false
            self.refresh()
            self.status.show(!read.hasSidetone && !read.hasOff && read.millivolts == 0 ? "The headset didn't answer. Is it on?" : "Matches the headset",
                             error: !read.hasSidetone && !read.hasOff && read.millivolts == 0)
            self.loaded()
        })
    }

    static func rangeText(_ hertz: Int) -> String {
        hertz < 50 ? "Deep bass" : hertz < 200 ? "Bass" : hertz < 400 ? "Low mids" : hertz < 1500 ? "Mids"
            : hertz < 3000 ? "Upper mids" : hertz < 6000 ? "Presence" : hertz < 12000 ? "Treble" : "Air"
    }

    private func refresh() {
        refreshing = true
        defer { refreshing = false }
        let hasSide = state?.hasSidetone == true, hasOff = state?.hasOff == true
        Ui.dim(sideHead, !hasSide)
        sidetone.isEnabled = hasSide
        testButton.isEnabled = hasSide
        sidetone.integerValue = current.sidetone
        sideValue.stringValue = hasSide ? "\(current.sidetone)%" : ""
        offChoices = current.autoOffMinutes >= 0 && !HeadsetProtocol.offMinutes.contains(current.autoOffMinutes)
            ? (HeadsetProtocol.offMinutes + [current.autoOffMinutes]).sorted() : HeadsetProtocol.offMinutes
        off.removeAllItems()
        off.addItems(withTitles: offChoices.map { $0 == 0 ? "Never" : "\($0) min" })
        off.selectItem(at: hasOff ? offChoices.firstIndex(of: current.autoOffMinutes) ?? -1 : -1)
        off.isEnabled = hasOff
        Ui.dim(offHead, !hasOff)
        let frequencies = state?.frequencies ?? [], range = state?.range ?? 12
        let bandCount = current.bands == nil ? 0 : min(HeadsetPage.maxBands, frequencies.count)
        equalizerBox.isHidden = bandCount == 0
        for i in 0..<HeadsetPage.maxBands {
            bandColumns[i].isHidden = i >= bandCount
            guard i < bandCount, let band = current.bands?[i] else { continue }
            let hertz = frequencies[i]
            bandNames[i].stringValue = hertz >= 1000 ? String(format: "%g", Double(hertz) / 1000) + "k" : "\(hertz)"
            bandNames[i].toolTip = HeadsetPage.rangeText(hertz)
            bandSliders[i].minValue = Double(-range); bandSliders[i].maxValue = Double(range)
            bandSliders[i].integerValue = band
            bandSliders[i].setAccessibilityLabel(hertz >= 1000 ? String(format: "%g kHz", Double(hertz) / 1000) : "\(hertz) Hz")
            bandValues[i].stringValue = (band > 0 ? "+" : "") + "\(band) dB"
        }
        flatButton.isEnabled = current.bands?.contains { $0 != 0 } == true
        firmware.stringValue = device.firmware.isEmpty ? "–" : device.firmware
        let millivolts = state.map { $0.millivolts > 0 ? $0.millivolts : device.millivolts } ?? device.millivolts
        let charging = state?.charging == true
        let percent = !charging ? (millivolts > 0 ? FoundDevice.fromVolts(millivolts) : device.battery)
            : device.battery >= 0 ? device.battery : FoundDevice.fromChargingVolts(millivolts)
        battery.stringValue = percent < 0 ? "–" : "\(percent)%" + (millivolts > 0 ? ", \(millivolts) mV" : "") + (charging ? ", charging" : "")
    }
}
