import AppKit

// The Screen effect's rows (app/KeyboardPage.cs, ZonesPage.cs and LightPage.cs, in rows since 0.1.0-beta): Zones (the screen with its
// areas, which a click picks, a drag moves and a drag at a corner resizes), Monitor, Color boost, Update rate, Smooth changes and, on
// the speakers, Brightness; the page puts them after Effect while the effect runs (show). The pause rows (Pause when screen off or
// locked, and on a wireless keyboard Pause on low battery) go at the end of the page's section. changed gets each edit; the page keeps
// the setup as screen.<device>.
final class ScreenBox: NSObject {
    private let preview = ScreenPreview()
    private let monitorPopup = NSPopUpButton()
    private let addButton = NSButton(title: "Add area", target: nil, action: nil)
    private let boost = Ui.slider(), rate = Ui.slider(), bright = Ui.slider()
    private let boostValue = Ui.value(), rateValue = Ui.value(), brightValue = Ui.value()
    private let smooth = Ui.toggle(), pause = Ui.toggle(), lowBattery = Ui.toggle()
    private var monitors: [(id: String, label: String)] = []
    private let reset: () -> [Zone]
    var changed: ((ScreenSettings) -> Void)?
    // The area picked in the preview, which keys clicked on the key picture are given.
    var picked: ((Int) -> Void)?
    var selectedZone: Int { min(preview.selected, setup.zones.count - 1) }
    // A keyboard's keys per area, shown in the areas' tags; set, it also lets areas be added and removed.
    private let counts: ((ScreenSettings) -> [Int])?
    var setup: ScreenSettings { didSet { show() } }
    // The rows after Effect, shown only while the Screen effect runs, and the pause rows, always there.
    private(set) var rows: [RowView] = []
    private(set) var pauseRows: [RowView] = []

    // lit: what the effect lights, for the hints (the keys, the light, the lights); pauseFor: the pause row's hint.
    init(setup: ScreenSettings, brightness: Bool, battery: Bool = false, lit: String, pauseFor: String = "For the Screen effect",
         counts: ((ScreenSettings) -> [Int])? = nil, reset: @escaping () -> [Zone]) {
        self.setup = setup
        self.reset = reset
        self.counts = counts
        super.init()
        rate.maxValue = 9
        rate.numberOfTickMarks = 10
        rate.allowsTickMarkValuesOnly = true
        for control in [monitorPopup, boost, rate, bright, smooth, pause, lowBattery] as [NSControl] { control.target = self; control.action = #selector(edited) }
        monitorPopup.setAccessibilityLabel("Monitor")
        monitorPopup.widthAnchor.constraint(equalToConstant: Rows.controlWidth).isActive = true
        preview.picked = { [weak self] in
            guard let self = self else { return }
            self.show()
            self.picked?(self.selectedZone)
        }
        preview.removed = counts == nil ? nil : { [weak self] index in
            guard let self = self else { return }
            self.setup.remove(index)
            self.pick(max(0, min(index, self.setup.zones.count - 1)))
        }
        preview.moved = { [weak self] zones in
            guard let self = self else { return }
            self.setup.zones = zones
            self.changed?(self.setup)
        }
        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetAreas))
        resetButton.setAccessibilityLabel("Reset the screen areas")
        addButton.target = self
        addButton.action = #selector(addArea)
        let buttons = NSStackView(views: counts == nil ? [resetButton] : [addButton, resetButton])
        buttons.orientation = .vertical
        buttons.alignment = .trailing
        let zonesControl = NSStackView(views: [preview, buttons])
        zonesControl.alignment = .bottom
        zonesControl.spacing = 12
        let zonesRow = Rows.row("Zones", counts == nil ? "" : "Drag to move, the corner to resize", zonesControl)
        rows = [zonesRow, Rows.row("Monitor", "The screen \(lit) follow", monitorPopup),
                Rows.row("Color boost", "Stronger screen colors on \(lit)", Rows.slider(boost, boostValue)),
                Rows.row("Update rate", "How often \(lit) follow the screen", Rows.slider(rate, rateValue))]
        if brightness { rows.append(Rows.row("Brightness", "How bright \(lit) are", Rows.slider(bright, brightValue))) }
        rows.append(Rows.row("Smooth changes", "Colors fade instead of jumping", smooth))
        pauseRows = [Rows.row("Pause when screen off or locked", pauseFor, pause)]
        if battery { pauseRows.append(Rows.row("Pause on low battery", pauseFor + ", on a wireless keyboard", lowBattery)) }
        show()
    }

    // The pause rows apply only while something G-Lite runs can pause; greyed, their switches show off.
    func pausing(_ on: Bool) {
        pauseApplies = on
        for row in pauseRows { row.enable(on); (row.control as? NSSwitch)?.isEnabled = on }
        show()
    }
    private var pauseApplies = true

    // The Screen effect's rows show while it runs, and the preview follows the screen then.
    func showing(_ on: Bool) {
        for row in rows { row.isHidden = !on }
        preview.follow(on ? setup.monitor : nil)
    }

    private func show() {
        monitors = ScreenSource.monitors()
        monitorPopup.removeAllItems()
        monitorPopup.addItems(withTitles: monitors.map { $0.label })
        monitorPopup.selectItem(at: monitors.firstIndex { $0.id == setup.monitor } ?? 0)
        boost.integerValue = setup.boost
        boostValue.stringValue = "\(setup.boost)%"
        rate.integerValue = (1000 - setup.interval) / 100
        rateValue.stringValue = "\(setup.interval) ms"
        bright.integerValue = setup.bright
        brightValue.stringValue = "\(setup.bright)%"
        smooth.state = setup.smooth ? .on : .off
        pause.state = pauseApplies && setup.pauseWhenLocked ? .on : .off
        lowBattery.state = pauseApplies && setup.pauseOnBattery ? .on : .off
        preview.zones = setup.zones
        preview.counts = counts?(setup)
        addButton.isEnabled = setup.zones.count < ScreenSettings.maxZones
    }

    @objc private func edited(_ sender: NSControl) {
        if sender === monitorPopup, monitorPopup.indexOfSelectedItem >= 0 {
            setup.monitor = monitors[monitorPopup.indexOfSelectedItem].id
            preview.follow(setup.monitor)
        }
        if sender === boost { setup.boost = boost.integerValue }
        if sender === rate { setup.interval = 1000 - rate.integerValue * 100 }
        if sender === bright { setup.bright = max(1, bright.integerValue) }
        if sender === smooth { setup.smooth = smooth.state == .on }
        if sender === pause { setup.pauseWhenLocked = pause.state == .on }
        if sender === lowBattery { setup.pauseOnBattery = lowBattery.state == .on }
        changed?(setup)
    }

    // Keys clicked on the key picture (their ids) go to the picked area.
    func give(_ ids: [Int]) {
        for id in ids where id >= 0 { setup.keys[id] = selectedZone }
        changed?(setup)
    }

    @objc private func addArea() {
        if let index = setup.add() { pick(index) }
    }

    private func pick(_ index: Int) {
        preview.selected = index
        show()
        picked?(selectedZone)
        changed?(setup)
    }

    @objc private func resetAreas() {
        setup.zones = reset()
        setup.keys.removeAll()
        pick(0)
    }
}

// The screen, shrunk, with the areas over it in their colours (app/Screen.cs, ScreenPreview).
final class ScreenPreview: NSView {
    var zones: [Zone] = [] { didSet { needsDisplay = true } }
    var counts: [Int]? { didSet { needsDisplay = true } }
    var selected = 0
    var picked: (() -> Void)?
    // Set, the picked area shows a cross that removes it (app/Screen.cs, ZoneList), as Delete does.
    var removed: ((Int) -> Void)?
    var moved: (([Zone]) -> Void)?
    private var image: CGImage?
    private var timer: Timer?
    private var source: ScreenSource?
    private var dragFrom: CGPoint?, dragArea = CGRect.zero, resizing = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 240).isActive = true
        heightAnchor.constraint(equalToConstant: 135).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // Follows a monitor's picture, twice a second, or stops (nil).
    func follow(_ monitor: String?) {
        timer?.invalidate()
        timer = nil
        source?.release(self)
        source = nil
        guard let monitor = monitor else { return }
        let source = ScreenSource.source(monitor)
        source.use(self)
        self.source = source
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.image = self?.source?.image()
            self?.needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    private func cross(_ rect: CGRect) -> CGRect { CGRect(x: rect.maxX - 15, y: rect.minY + 3, width: 12, height: 12) }

    private var removable: Bool { removed != nil && zones.count > 1 && selected < zones.count }

    override func keyDown(with event: NSEvent) {
        if removable, event.keyCode == 51 || event.keyCode == 117 { removed?(selected) } else { super.keyDown(with: event) }
    }

    private func frameRect(_ area: CGRect) -> CGRect {
        CGRect(x: area.minX * bounds.width, y: area.minY * bounds.height, width: area.width * bounds.width, height: area.height * bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        if let image = image, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).addClip()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: bounds)
            context.restoreGState()
        }
        for (index, zone) in zones.enumerated() {
            let rect = frameRect(zone.area), color = NSColor(rgb: zone.markColor)
            color.withAlphaComponent(index == selected ? 0.3 : 0.15).setFill()
            NSBezierPath(rect: rect).fill()
            color.setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            outline.lineWidth = index == selected ? 3 : 1.5
            outline.stroke()
            if index == selected {
                color.setFill()
                NSBezierPath(rect: CGRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)).fill()
            }
            // Clipped to the area, short of the cross: the count on a line of its own, so a narrow area still shows it.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width - (index == selected && removable ? 15 : 2), height: rect.height)).addClip()
            NSAttributedString(string: zone.name, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white])
                .draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 3))
            if let counts = counts, index < counts.count {
                NSAttributedString(string: counts[index] == 1 ? "1 key" : "\(counts[index]) keys",
                                   attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white])
                    .draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 16))
            }
            NSGraphicsContext.restoreGraphicsState()
            if index == selected && removable {
                let mark = cross(rect).insetBy(dx: 3, dy: 3), lines = NSBezierPath()
                lines.move(to: mark.origin); lines.line(to: CGPoint(x: mark.maxX, y: mark.maxY))
                lines.move(to: CGPoint(x: mark.maxX, y: mark.minY)); lines.line(to: CGPoint(x: mark.minX, y: mark.maxY))
                lines.lineWidth = 1.5
                NSColor.white.setStroke()
                lines.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if removable && cross(frameRect(zones[selected].area)).contains(point) {
            removed?(selected)
            return
        }
        // The selected area's corner first, then the topmost area under the click.
        if selected < zones.count {
            let rect = frameRect(zones[selected].area)
            if abs(point.x - rect.maxX) < 9 && abs(point.y - rect.maxY) < 9 {
                begin(point, resizing: true)
                return
            }
        }
        guard let index = zones.indices.reversed().first(where: { frameRect(zones[$0].area).contains(point) }) else { return }
        selected = index
        picked?()
        begin(point, resizing: false)
        needsDisplay = true
    }

    private func begin(_ point: CGPoint, resizing: Bool) {
        dragFrom = point
        dragArea = zones[selected].area
        self.resizing = resizing
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom, selected < zones.count else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = (point.x - from.x) / bounds.width, dy = (point.y - from.y) / bounds.height
        var area = dragArea
        if resizing {
            area.size.width = max(0.04, min(1 - area.minX, dragArea.width + dx))
            area.size.height = max(0.04, min(1 - area.minY, dragArea.height + dy))
        } else {
            area.origin.x = max(0, min(1 - area.width, dragArea.minX + dx))
            area.origin.y = max(0, min(1 - area.height, dragArea.minY + dy))
        }
        zones[selected].area = area
    }

    override func mouseUp(with event: NSEvent) {
        guard dragFrom != nil else { return }
        dragFrom = nil
        moved?(zones)
    }
}
