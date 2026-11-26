import AppKit
import AVFoundation

// The headset screen (app/HeadsetPage.cs), in rows: the headset's picture, then Sound (Sidetone, Test sidetone), Power (Turn off
// after) and the equalizer (experimental, a row per band), applied at once; rows the headset doesn't have are left out once it's read.
// The battery shows under the name. Test sidetone opens the headset's microphone for 30 s (the dongle plays sidetone only while an
// app uses it), after the microphone permission.
final class HeadsetPage: DevicePage {
    private var current = HeadsetSettings(), sent = HeadsetSettings()
    private var state: HeadsetProtocol.State?
    private var refreshing = false, dirty = false, sequence = 0
    private var debounce: Timer?
    private var offChoices = HeadsetProtocol.offMinutes

    private let sidetone = Ui.slider(), sideValue = Ui.value()
    private let off = NSPopUpButton()
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private var sideRow: RowView!, testRow: RowView!, offRow: RowView!
    private var power = NSView()
    private var microphone: MicrophoneCapture?, testTimer: Timer?
    private static let maxBands = 15
    private let bandSliders: [NSSlider] = (0..<maxBands).map { _ in Ui.slider() }
    private let bandValues: [NSTextField] = (0..<maxBands).map { _ in Ui.value() }
    private var bandRows: [RowView] = []
    private let flatButton = NSButton(title: "Flat", target: nil, action: nil)
    private var equalizer = NSView()
    // A band being dragged writes RAM only; once let go, RAM and EEPROM (persistence 1). keptBands: the last written to both.
    private var bandHeld = false
    private var keptBands: [Int]?

    override func loadView() {
        sidetone.target = self; sidetone.action = #selector(sidetoneMoved)
        off.target = self; off.action = #selector(offPicked)
        off.widthAnchor.constraint(equalToConstant: Rows.controlWidth).isActive = true
        testButton.target = self; testButton.action = #selector(testClicked)
        testButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        sideRow = Rows.row("Sidetone", "Your own voice, while an app uses the microphone", Rows.slider(sidetone, sideValue))
        testRow = Rows.row("Test sidetone", "Hear yourself for 30 s", testButton)
        offRow = Rows.row("Turn off after", "When the headset isn't used", off)
        for (i, slider) in bandSliders.enumerated() {
            slider.tag = i
            slider.target = self; slider.action = #selector(bandMoved(_:))
            bandRows.append(Rows.row("", "", Rows.slider(slider, bandValues[i])))
        }
        flatButton.target = self; flatButton.action = #selector(flatClicked)
        flatButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        power = Rows.section("Power", [offRow])
        equalizer = Rows.section("Equalizer", [Rows.note("Experimental. The headset stores these bands, but it hasn't been heard to play them "
                                                         + "yet: G HUB applies its equalizer on the PC. Changes are sent to the headset right away.")]
                                 + bandRows + [Rows.row("Flat", "Every band back to 0 dB", flatButton)])
        let picture = HeadsetPicture()
        view = Rows.page(header: header, sticky: picture, sections: [Rows.section("Sound", [sideRow, testRow]), power, equalizer],
                         status: status, buttons: [])
        header.show(device)
        refresh()
        load()
    }

    // For --snapshot: the equalizer's last rows in view.
    func showEqualizer() {
        view.layoutSubtreeIfNeeded()
        guard let scroll = equalizer.enclosingScrollView, let document = scroll.documentView else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
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
        testButton.title = "Stop"
        testButton.keyEquivalent = "\r"
        status.show("Talk now. You hear yourself at the sidetone level. The test stops after 30 s.")
    }

    private func stopTest() {
        testTimer?.invalidate()
        testTimer = nil
        microphone?.stop()
        microphone = nil
        testButton.title = "Test"
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
        let ready = state != nil, hasSide = state?.hasSidetone == true, hasOff = state?.hasOff == true
        // Before the headset is read every row shows but the equalizer's, whose bands it says.
        sideRow.isHidden = ready && !hasSide
        testRow.isHidden = ready && !hasSide
        power.isHidden = ready && !hasOff
        sideRow.enable(hasSide)
        testRow.enable(hasSide)
        sidetone.isEnabled = hasSide
        testButton.isEnabled = hasSide
        sidetone.integerValue = hasSide ? current.sidetone : 0
        sideValue.stringValue = hasSide ? "\(current.sidetone)%" : ""
        offChoices = current.autoOffMinutes >= 0 && !HeadsetProtocol.offMinutes.contains(current.autoOffMinutes)
            ? (HeadsetProtocol.offMinutes + [current.autoOffMinutes]).sorted() : HeadsetProtocol.offMinutes
        off.removeAllItems()
        off.addItems(withTitles: offChoices.map { $0 == 0 ? "Never" : "\($0) min" })
        off.selectItem(at: hasOff ? offChoices.firstIndex(of: current.autoOffMinutes) ?? -1 : -1)
        off.isEnabled = hasOff
        offRow.enable(hasOff)
        let frequencies = state?.frequencies ?? [], range = state?.range ?? 12
        let bandCount = current.bands == nil ? 0 : min(HeadsetPage.maxBands, frequencies.count)
        equalizer.isHidden = bandCount == 0
        for i in 0..<HeadsetPage.maxBands {
            bandRows[i].isHidden = i >= bandCount
            guard i < bandCount, let band = current.bands?[i] else { continue }
            let hertz = frequencies[i]
            let name = hertz >= 1000 ? String(format: "%g kHz", Double(hertz) / 1000) : "\(hertz) Hz"
            bandRows[i].title.stringValue = name
            bandRows[i].hint.stringValue = HeadsetPage.rangeText(hertz)
            bandSliders[i].minValue = Double(-range); bandSliders[i].maxValue = Double(range)
            bandSliders[i].integerValue = band
            bandSliders[i].setAccessibilityLabel(name)
            bandValues[i].stringValue = (band > 0 ? "+" : "") + "\(band) dB"
        }
        flatButton.isEnabled = current.bands?.contains { $0 != 0 } == true
    }
}

// The headset, centred (app/HeadsetPage.cs, HeadsetPicture): the band, the cups, the microphone's boom with its light.
final class HeadsetPicture: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 150).isActive = true
        setAccessibilityRole(.image)
        setAccessibilityLabel("Headset")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height - 16, width = height * 0.9, y: CGFloat = 8, x = (bounds.width - width) / 2
        let cupWidth = width * 0.26, cupHeight = height * 0.42, cupY = y + height * 0.5
        KeyPicture.keyOff.setStroke()
        // The band: the top half of an ellipse from cup to cup.
        let bandRect = CGRect(x: x + cupWidth / 2, y: y + 4, width: width - cupWidth, height: height * 1.05)
        let band = NSBezierPath()
        band.appendArc(withCenter: CGPoint(x: bandRect.midX, y: bandRect.midY), radius: 1, startAngle: 180, endAngle: 360, clockwise: false)
        band.transform(using: {
            var transform = AffineTransform(translationByX: bandRect.midX, byY: bandRect.midY)
            transform.scale(x: bandRect.width / 2, y: bandRect.height / 2)
            transform.translate(x: -bandRect.midX, y: -bandRect.midY)
            return transform
        }())
        band.lineWidth = 9
        band.lineCapStyle = .round
        band.stroke()
        let boom = NSBezierPath()
        boom.move(to: CGPoint(x: x + cupWidth * 0.6, y: cupY + cupHeight * 0.8))
        boom.curve(to: CGPoint(x: x + width * 0.4, y: y + height * 0.96), controlPoint1: CGPoint(x: x + cupWidth * 0.4, y: y + height * 1.02),
                   controlPoint2: CGPoint(x: x + width * 0.28, y: y + height * 0.98))
        boom.lineWidth = 5
        boom.lineCapStyle = .round
        boom.stroke()
        for cupX in [x, x + width - cupWidth] {
            let cup = NSBezierPath(roundedRect: CGRect(x: cupX, y: cupY, width: cupWidth, height: cupHeight), xRadius: cupWidth * 0.42, yRadius: cupWidth * 0.42)
            KeyPicture.keyOff.setFill()
            cup.fill()
            NSColor.separatorColor.setStroke()
            cup.stroke()
            KeyPicture.background.setFill()
            NSBezierPath(roundedRect: CGRect(x: cupX + cupWidth * 0.22, y: cupY + cupHeight * 0.16, width: cupWidth * 0.56, height: cupHeight * 0.68),
                         xRadius: cupWidth * 0.26, yRadius: cupWidth * 0.26).fill()
        }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: x + width * 0.4 - 4, y: y + height * 0.96 - 4, width: 8, height: 8)).fill()
    }
}
