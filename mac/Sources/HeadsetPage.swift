import AppKit
import AVFoundation

// The headset screen (app/HeadsetPage.cs): sidetone and auto-off, applied at once; the battery from its voltage.
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
        view = Ui.page(header: header, body: [Ui.box("Sound", sound), Ui.box("Power", power)], status: status, buttons: [])
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

    // The Windows text: sidetone, then the auto-off minutes.
    override func presetText() -> String? { "\(current.sidetone),\(current.autoOffMinutes)" }

    override func applyPreset(_ text: String) {
        let values = text.components(separatedBy: ",").compactMap { Int($0) }
        guard values.count == 2 else { return }
        current = HeadsetSettings(sidetone: max(0, min(100, values[0])), autoOffMinutes: values[1])
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
        let want = current, before = sent
        sequence += 1
        let startedAt = sequence
        run({ hidpp in
            if startedAt != self.sequence { return }
            if state.hasSidetone && want.sidetone != before.sidetone { try HeadsetProtocol.setSidetone(hidpp, want.sidetone) }
            if state.hasOff && want.autoOffMinutes >= 0 && want.autoOffMinutes != before.autoOffMinutes {
                try HeadsetProtocol.setOff(hidpp, want.autoOffMinutes)
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
            self.dirty = false
            self.refresh()
            self.status.show(!read.hasSidetone && !read.hasOff && read.millivolts == 0 ? "The headset didn't answer. Is it on?" : "Matches the headset",
                             error: !read.hasSidetone && !read.hasOff && read.millivolts == 0)
            self.loaded()
        })
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
        firmware.stringValue = device.firmware.isEmpty ? "–" : device.firmware
        let millivolts = state.map { $0.millivolts > 0 ? $0.millivolts : device.millivolts } ?? device.millivolts
        let charging = state?.charging == true
        let percent = !charging ? (millivolts > 0 ? FoundDevice.fromVolts(millivolts) : device.battery)
            : device.battery >= 0 ? device.battery : FoundDevice.fromChargingVolts(millivolts)
        battery.stringValue = percent < 0 ? "–" : "\(percent)%" + (millivolts > 0 ? ", \(millivolts) mV" : "") + (charging ? ", charging" : "")
    }
}
