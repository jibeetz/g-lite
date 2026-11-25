import AppKit

// The live key picture (app/KeyPicture.cs): each key of a layout, lit as the effect would light it on the keyboard (display), or in
// the colours a screen gives it (show, for the zones keyboards), or the keys picked for Game mode (picking).
// The shaped keys as on Windows: the logo in its colour (G-Lite's disc with GL cut out), the volume roller's housing, round buttons; in
// the Game view the round buttons get their icons and the roller its grooves.
// Clicks and drags as on Windows: in the Game view a click picks a key; on a live picture a drag draws a rectangle and gives the keys
// it touches when let go (a click, the key under it); on a lit picture a click starts a ripple and picks the bar or the keys.
final class KeyPicture: NSView {
    private var keys: [CGRect] = [], names: [String] = [], ids: [Int] = []
    private var shaped = Set<Int>(), lips: [Int: CGFloat] = [:]
    private(set) var widthInKeys: CGFloat = 0, heightInKeys: CGFloat = 0
    private var effect: UInt8 = 0xFF, parameters = [UInt8](repeating: 0, count: 10), bright = 100
    private var colors: [Int]?
    private var marked: [Bool]?
    private var ripples: [(CGPoint, Double)] = []
    private var lastRipple = 0.0
    private let clock = Date()
    private var timer: Timer?
    private var dragFrom: CGPoint?, dragTo = CGPoint.zero, hovered = -1
    // Keys clicked or dragged over (app/KeyPicture.cs, KeysPicked), by index; nil leaves the picture unclickable.
    var keysPicked: (([Int]) -> Void)?

    // Picking keys by lighting id, for Game mode (app/KeyPicture.cs, Picking): no animation, each key with its name, the picked keys in
    // the accent colour, those always off paler, those that can't be picked faded. The Game key is outlined, so the note's "Game mode"
    // can be found on the picture.
    struct Picking {
        var picked: Set<Int>
        var fixed: Set<Int>
        var canPick: (Int) -> Bool
        // A key's legend from its id and its name in the layout (Windows' Label).
        var label: ((Int, String) -> String)?
    }
    var picking: Picking? { didSet { needsDisplay = true } }

    // The G512 X 75's light bar (app/KeyPicture.cs, Bar and Part): its ids, drawn with the bar's own lighting when it has one; part 1
    // (the keys) or 2 (the bar) dims the other part, 0 none.
    var bar = Set<Int>()
    var part = 0 { didSet { needsDisplay = true } }
    private var barEffect: UInt8?, barParameters = [UInt8](repeating: 0, count: 10)
    func onBar(_ key: Int) -> Bool { bar.contains(ids[key]) }
    func nameOf(_ key: Int) -> String { names[key] }

    static let keyOff = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: 0x2E2E2E) : NSColor(rgb: 0xD6D6D6) }
    static let background = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: 0x151515) : NSColor(rgb: 0xBDBDBD) }

    var count: Int { keys.count }
    func idOf(_ key: Int) -> Int { ids[key] }
    func xOf(_ key: Int) -> Double { Double((keys[key].midX) / widthInKeys) }
    func yOf(_ key: Int) -> Double { Double((keys[key].minY + min(keys[key].height, 1) / 2) / heightInKeys) }

    init(_ layout: KeyLayout) {
        super.init(frame: .zero)
        setLayout(layout)
        heightAnchor.constraint(equalTo: widthAnchor, multiplier: 0.28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setLayout(_ layout: KeyLayout) {
        keys = []; names = []; shaped = []; lips = [:]
        widthInKeys = 0; heightInKeys = 0
        for row in layout.rows {
            var x: CGFloat = 0, tall: CGFloat = 0
            for token in row.components(separatedBy: "|") {
                if token.hasPrefix("_") { x += CGFloat(Double(token.dropFirst()) ?? 0); continue }
                let parts = token.components(separatedBy: ":")
                let width = parts.count > 1 ? CGFloat(Double(parts[1]) ?? 1) : 1
                let height = parts.count > 2 ? CGFloat(Double(parts[2]) ?? 1) : 1
                if parts.count > 3 { lips[keys.count] = CGFloat(Double(parts[3]) ?? 0) }
                if layout.shaped.contains(parts[0]) { shaped.insert(keys.count) }
                keys.append(CGRect(x: x, y: heightInKeys, width: width, height: height))
                names.append(parts[0])
                x += width
                // A key taller than a row (the numpad's + and Enter) hangs into the next one, which leaves a gap for it.
                tall = max(tall, min(height, 1))
                widthInKeys = max(widthInKeys, x)
            }
            heightInKeys += tall > 0 ? tall : x
        }
        ids = layout.keyIds()
        colors = nil
        needsDisplay = true
    }

    // The keyboard's own effect, drawn the way the keyboard shows it (G515 effect ids).
    func display(_ lighting: Lighting?, _ level: Int, bar barLighting: Lighting? = nil) {
        effect = lighting?.effect ?? 0xFF
        parameters = lighting.map { G515Profile.encode($0, 100) } ?? [UInt8](repeating: 0, count: 10)
        barEffect = barLighting?.effect
        barParameters = barLighting.map { G515Profile.encode($0, 100) } ?? [UInt8](repeating: 0, count: 10)
        bright = level
        colors = nil
        needsDisplay = true
    }

    // Each key's colour, from the screen (the zones keyboards), with some keys outlined (the picked zone's).
    func show(_ keyColors: [Int], marked: [Bool]? = nil) {
        colors = keyColors
        self.marked = marked
        bright = 100
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        if window != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self = self, self.window?.isVisible == true, self.colors == nil, self.picking == nil else { return }
                self.needsDisplay = true
            }
        }
    }

    // The colour of an effect at a place and time (app/KeyboardView.cs, EffectColorAt).
    static func colorAt(_ id: UInt8, _ p: [UInt8], x: Double, y: Double, seconds: Double, ripple: Double) -> (Double, Double, Double) {
        if G515Profile.effect(id) == nil { return hsv(seconds / 8 - x, 1, 1) }
        let color = (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
        let period = periodOf(id, p)
        switch id {
        case 0x01: return color
        case 0x0A:
            let factor = 0.5 - 0.5 * cos(2 * Double.pi * seconds / period)
            return (color.0 * factor, color.1 * factor, color.2 * factor)
        case 0x15: return hsv(seconds / period, Double(p[1]) / 255, 1)
        case 0x16:
            let direction = p[9]
            let offset = direction == 6 ? x : direction == 3 ? -abs(x - 0.5) * 2 : direction == 8 ? abs(x - 0.5) * 2
                : direction == 2 ? -y : direction == 7 ? y : -x
            return hsv(seconds / period + offset, Double(p[1]) / 255, 1)
        case 0x17: return (color.0 * ripple, color.1 * ripple, color.2 * ripple)
        default: return (0, 0, 0)
        }
    }

    static func periodOf(_ id: UInt8, _ p: [UInt8]) -> Double {
        var period = Double(id == 0x0A ? Int(p[3]) << 8 | Int(p[4]) : Int(p[6]) << 8 | Int(p[7])) / 1000
        if id == 0x17 { period = Double(Int(p[6]) << 8 | Int(p[7])) / 20 }
        return period <= 0 ? 5 : period
    }

    static func hsv(_ hue: Double, _ saturation: Double, _ value: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let i = Int(h), fraction = h - Double(i)
        let low = value * (1 - saturation), falling = value * (1 - saturation * fraction), rising = value * (1 - saturation * (1 - fraction))
        switch i {
        case 0: return (value, rising, low)
        case 1: return (falling, value, low)
        case 2: return (low, value, rising)
        case 3: return (low, falling, value)
        case 4: return (rising, low, value)
        default: return (value, low, falling)
        }
    }

    // A lit key: its colour at full strength, mixed into the unlit key by how bright it is.
    private func fill(_ rgb: (Double, Double, Double)) -> NSColor {
        let top = max(rgb.0, rgb.1, rgb.2)
        guard top > 0, let off = KeyPicture.keyOff.usingColorSpace(.sRGB) else { return KeyPicture.keyOff }
        let amount = CGFloat(top * Double(bright) / 100)
        let full = (CGFloat(rgb.0 / top), CGFloat(rgb.1 / top), CGFloat(rgb.2 / top))
        return NSColor(srgbRed: off.redComponent + (full.0 - off.redComponent) * amount, green: off.greenComponent + (full.1 - off.greenComponent) * amount,
                       blue: off.blueComponent + (full.2 - off.blueComponent) * amount, alpha: 1)
    }

    // A round button (the G815's and G915's M, Game, light and media keys) is a little narrower than its slot, as on the keyboard.
    private static func disc(_ rect: CGRect) -> CGRect {
        let side = min(rect.width, rect.height) * 0.86
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    private func keyPath(_ index: Int, _ rect: CGRect) -> NSBezierPath {
        if shaped.contains(index) && names[index] == "Wheel" {
            return NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.28, yRadius: rect.height * 0.28)
        }
        if shaped.contains(index) { return NSBezierPath(ovalIn: KeyPicture.disc(rect)) }
        return NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
    }

    // A key in its colour, the logo and the roller in their own shapes (app/KeyPicture.cs, FillKey).
    private func fillKey(_ index: Int, _ path: NSBezierPath, _ rect: CGRect, _ fill: NSColor) {
        if shaped.contains(index) && names[index] == "Logo", let context = NSGraphicsContext.current?.cgContext {
            let side = min(rect.width, rect.height) * 1.04
            Logo.paint(context, CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side), fill, KeyPicture.background)
            return
        }
        if shaped.contains(index) && names[index] == "Wheel" && picking != nil { drawWheel(rect); return }
        fill.setFill()
        path.fill()
    }

    // The volume roller in its housing above the media keys: not lit, not a key.
    private func drawWheel(_ rect: CGRect) {
        let housing = KeyPicture.background.blended(withFraction: 0.55, of: KeyPicture.keyOff) ?? KeyPicture.keyOff
        housing.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.28, yRadius: rect.height * 0.28).fill()
        let roller = CGRect(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.14, width: rect.width * 0.76, height: rect.height * 0.5)
        (KeyPicture.keyOff.blended(withFraction: 0.35, of: .labelColor) ?? .gray).setFill()
        NSBezierPath(roundedRect: roller, xRadius: 2, yRadius: 2).fill()
        (KeyPicture.keyOff.blended(withFraction: 0.15, of: .labelColor) ?? .gray).setStroke()
        for groove in 1..<5 {
            let y = roller.minY + roller.height * CGFloat(groove) / 5, line = NSBezierPath()
            line.move(to: CGPoint(x: roller.minX + 1, y: y)); line.line(to: CGPoint(x: roller.maxX - 1, y: y))
            line.lineWidth = 1
            line.stroke()
        }
    }

    // The round buttons' icons, drawn in the Game view (app/KeyPicture.cs, DrawIcon); false for a key that has none.
    private func drawIcon(_ name: String, _ disc: CGRect, _ color: NSColor) -> Bool {
        let middleX = disc.midX, middleY = disc.midY, size = disc.width
        color.setStroke()
        color.setFill()
        func stroked(_ path: NSBezierPath, _ width: CGFloat = 1.2) {
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        switch name {
        case "Game":
            drawJoystick(disc, color)
        case "Bluetooth":
            let half = size * 0.22, arm = half * 0.45, rune = NSBezierPath()
            rune.move(to: CGPoint(x: middleX - arm, y: middleY - half / 2))
            for point in [CGPoint(x: middleX + arm, y: middleY + half / 2), CGPoint(x: middleX, y: middleY + half), CGPoint(x: middleX, y: middleY - half),
                          CGPoint(x: middleX + arm, y: middleY - half / 2), CGPoint(x: middleX - arm, y: middleY + half / 2)] { rune.line(to: point) }
            stroked(rune)
        case "Lightspeed":
            let originY = middleY + size * 0.12, rays = NSBezierPath()
            for ray in 0..<5 {
                let angle = Double.pi * (1.15 + Double(ray) * 0.175)
                rays.move(to: CGPoint(x: middleX, y: originY))
                rays.line(to: CGPoint(x: middleX + CGFloat(cos(angle)) * size * 0.26, y: originY + CGFloat(sin(angle)) * size * 0.26))
            }
            rays.move(to: CGPoint(x: middleX - size * 0.2, y: originY)); rays.line(to: CGPoint(x: middleX + size * 0.2, y: originY))
            stroked(rays, 1.1)
        case "Light":
            let ring = size * 0.11
            stroked(NSBezierPath(ovalIn: CGRect(x: middleX - ring, y: middleY - ring, width: 2 * ring, height: 2 * ring)))
            let rays = NSBezierPath()
            for ray in 0..<8 {
                let angle = Double(ray) * Double.pi / 4, cosine = CGFloat(cos(angle)), sine = CGFloat(sin(angle))
                rays.move(to: CGPoint(x: middleX + cosine * size * 0.19, y: middleY + sine * size * 0.19))
                rays.line(to: CGPoint(x: middleX + cosine * size * 0.27, y: middleY + sine * size * 0.27))
            }
            stroked(rays)
        case "Prev", "Play", "Next", "Mute":
            drawMedia(name, disc)
        default:
            return false
        }
        return true
    }

    // The Game mode key's icon: a ball on a stick, standing on a round base seen from above.
    private func drawJoystick(_ rect: CGRect, _ color: NSColor) {
        let size = min(rect.width, rect.height) * 0.5, left = rect.minX + (rect.width - size) / 2, top = rect.minY + (rect.height - size) / 2
        let middle = left + size / 2, ball = size * 0.28, depth = size * 0.13
        let face = CGRect(x: left + size * 0.04, y: top + size * 0.56, width: size * 0.92, height: size * 0.3)
        color.setStroke()
        let shape = NSBezierPath(ovalIn: CGRect(x: middle - ball / 2, y: top, width: ball, height: ball))
        shape.move(to: CGPoint(x: middle, y: top + ball)); shape.line(to: CGPoint(x: middle, y: face.midY))
        shape.append(NSBezierPath(ovalIn: face))
        shape.move(to: CGPoint(x: face.minX, y: face.midY)); shape.line(to: CGPoint(x: face.minX, y: face.midY + depth))
        shape.move(to: CGPoint(x: face.maxX, y: face.midY)); shape.line(to: CGPoint(x: face.maxX, y: face.midY + depth))
        // The base's lower edge: the bottom half of the face's ellipse, lowered by its depth (y grows down: 0 to 180 degrees).
        let lower = NSBezierPath()
        lower.appendArc(withCenter: .zero, radius: 1, startAngle: 0, endAngle: 180, clockwise: false)
        lower.transform(using: AffineTransform(scaleByX: face.width / 2, byY: face.height / 2))
        lower.transform(using: AffineTransform(translationByX: face.midX, byY: face.midY + depth))
        shape.append(lower)
        shape.lineWidth = 1.2
        shape.stroke()
    }

    // The media keys' icons: previous, play and pause, next, and a speaker with a cross for mute.
    private func drawMedia(_ name: String, _ disc: CGRect) {
        let size = disc.width * 0.44, height = size * 0.56
        let left = disc.minX + (disc.width - size) / 2, middle = disc.midY
        let top = middle - height / 2, bottom = middle + height / 2, right = left + size, bar = size * 0.12
        func triangle(_ baseX: CGFloat, _ tipX: CGFloat) {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: baseX, y: top)); path.line(to: CGPoint(x: tipX, y: middle)); path.line(to: CGPoint(x: baseX, y: bottom))
            path.close()
            path.fill()
        }
        switch name {
        case "Prev":
            NSBezierPath(rect: CGRect(x: left, y: top, width: bar, height: height)).fill()
            triangle(left + size * 0.56, left + bar)
            triangle(right, left + size * 0.56)
        case "Next":
            triangle(left, left + size * 0.44)
            triangle(left + size * 0.44, right - bar)
            NSBezierPath(rect: CGRect(x: right - bar, y: top, width: bar, height: height)).fill()
        case "Play":
            triangle(left, left + size * 0.56)
            NSBezierPath(rect: CGRect(x: left + size * 0.66, y: top, width: bar, height: height)).fill()
            NSBezierPath(rect: CGRect(x: right - bar, y: top, width: bar, height: height)).fill()
        default:
            NSBezierPath(rect: CGRect(x: left, y: middle - height * 0.22, width: size * 0.18, height: height * 0.44)).fill()
            let cone = NSBezierPath()
            cone.move(to: CGPoint(x: left + size * 0.16, y: middle - height * 0.22)); cone.line(to: CGPoint(x: left + size * 0.46, y: top))
            cone.line(to: CGPoint(x: left + size * 0.46, y: bottom)); cone.line(to: CGPoint(x: left + size * 0.16, y: middle + height * 0.22))
            cone.close()
            cone.fill()
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: left + size * 0.64, y: middle - height * 0.3)); cross.line(to: CGPoint(x: right, y: middle + height * 0.3))
            cross.move(to: CGPoint(x: left + size * 0.64, y: middle + height * 0.3)); cross.line(to: CGPoint(x: right, y: middle - height * 0.3))
            cross.lineWidth = 1.3
            cross.lineCapStyle = .round
            cross.stroke()
        }
    }

    private func drawPicking(_ index: Int, _ rect: CGRect, _ picking: Picking, _ size: CGFloat) {
        let id = ids[index], picked = id >= 0 && picking.picked.contains(id), fixed = id >= 0 && picking.fixed.contains(id)
        let pickable = id >= 0 && picking.canPick(id), gameKey = names[index] == "Game"
        let path = keyPath(index, rect)
        var fill = picked ? NSColor.controlAccentColor : fixed ? NSColor.controlAccentColor.withAlphaComponent(0.35)
            : pickable || gameKey ? KeyPicture.keyOff : KeyPicture.keyOff.withAlphaComponent(0.4)
        if index == hovered { fill = fill.blended(withFraction: 0.2, of: .labelColor) ?? fill }
        fillKey(index, path, rect, fill)
        let ink = picked ? NSColor.white : pickable ? NSColor.labelColor : NSColor.tertiaryLabelColor
        if gameKey {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
            drawJoystick(shaped.contains(index) ? KeyPicture.disc(rect) : rect, .labelColor)
            return
        }
        if shaped.contains(index) {
            if names[index] != "Logo" && names[index] != "Wheel" { _ = drawIcon(names[index], KeyPicture.disc(rect), ink) }
            return
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byClipping
        var font = NSFont.systemFont(ofSize: max(6, min(10, size * 0.28)))
        let label = picking.label.map { $0(id, names[index]) } ?? names[index]
        while (label as NSString).size(withAttributes: [.font: font]).width > rect.width - 2 && font.pointSize > 5 {
            font = NSFont.systemFont(ofSize: font.pointSize - 0.5)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style,
            .foregroundColor: picked ? NSColor.white : pickable ? NSColor.labelColor : NSColor.tertiaryLabelColor]
        let height = (label as NSString).size(withAttributes: attributes).height
        (label as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), withAttributes: attributes)
    }

    private func scale() -> (CGFloat, CGFloat, CGFloat) {
        let pad: CGFloat = 8
        let size = min((bounds.width - 2 * pad) / widthInKeys, (bounds.height - 2 * pad) / heightInKeys)
        return (size, (bounds.width - widthInKeys * size) / 2, (bounds.height - heightInKeys * size) / 2)
    }

    // A key's cap in the view, the top row of an ISO Enter with it.
    private func caps(_ index: Int) -> [CGRect] {
        let (size, offsetX, offsetY) = scale(), box = keys[index]
        func cap(_ box: CGRect) -> CGRect {
            CGRect(x: offsetX + box.minX * size + 1.5, y: offsetY + box.minY * size + 1.5, width: box.width * size - 3, height: box.height * size - 3)
        }
        return [cap(box)] + (lips[index].map { [cap(CGRect(x: box.minX - $0, y: box.minY, width: box.width + $0, height: 1))] } ?? [])
    }

    private func key(at point: CGPoint) -> Int? { keys.indices.first { caps($0).contains { $0.contains(point) } } }

    private var marquee: CGRect {
        guard let from = dragFrom else { return .null }
        return CGRect(x: min(from.x, dragTo.x), y: min(from.y, dragTo.y), width: abs(dragTo.x - from.x), height: abs(dragTo.y - from.y))
    }

    private var dragged: Bool { dragFrom.map { abs(dragTo.x - $0.x) > 4 || abs(dragTo.y - $0.y) > 4 } ?? false }

    private func touched() -> [Int] {
        keys.indices.filter { index in ids[index] >= 0 && caps(index).contains { dragged ? $0.intersects(marquee) : $0.contains(dragTo) } }
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: max(0, min(bounds.width, point.x)), y: max(0, min(bounds.height, point.y)))
    }

    override func mouseDown(with event: NSEvent) {
        guard widthInKeys > 0 else { return }
        let point = self.point(event)
        if let picking = picking {
            if let key = key(at: point), ids[key] >= 0, picking.canPick(ids[key]) { keysPicked?([key]) }
            return
        }
        if colors != nil {
            guard keysPicked != nil else { return }
            dragFrom = point
            dragTo = point
            needsDisplay = true
            return
        }
        let (size, offsetX, offsetY) = scale()
        ripples.append((CGPoint(x: (point.x - offsetX) / size, y: (point.y - offsetY) / size), Date().timeIntervalSince(clock)))
        if let key = key(at: point), ids[key] >= 0 { keysPicked?([key]) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragFrom != nil else { return }
        dragTo = point(event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragFrom != nil else { return }
        dragTo = point(event)
        let hits = touched()
        dragFrom = nil
        needsDisplay = true
        if !hits.isEmpty { keysPicked?(hits) }
    }

    // The Game view lights the key under the pointer, with the hand.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let picking = picking else { return }
        let over = key(at: point(event)).flatMap { ids[$0] >= 0 && picking.canPick(ids[$0]) ? $0 : nil } ?? -1
        (over >= 0 ? NSCursor.pointingHand : NSCursor.arrow).set()
        if over != hovered { hovered = over; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered >= 0 { hovered = -1; needsDisplay = true }
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard widthInKeys > 0 else { return }
        let pad: CGFloat = 8
        let (size, offsetX, offsetY) = scale()
        KeyPicture.background.setFill()
        NSBezierPath(roundedRect: CGRect(x: offsetX - pad, y: offsetY - pad, width: widthInKeys * size + 2 * pad, height: heightInKeys * size + 2 * pad),
                     xRadius: 8, yRadius: 8).fill()
        func cap(_ box: CGRect) -> CGRect {
            CGRect(x: offsetX + box.minX * size + 1.5, y: offsetY + box.minY * size + 1.5, width: box.width * size - 3, height: box.height * size - 3)
        }
        let seconds = Date().timeIntervalSince(clock), period = KeyPicture.periodOf(effect, parameters)
        if colors == nil && effect == 0x17 && seconds - lastRipple > 1.8 && !keys.isEmpty {
            let key = keys[Int.random(in: 0..<keys.count)]
            ripples.append((CGPoint(x: key.midX, y: key.minY + 0.5), seconds))
            lastRipple = seconds
        }
        ripples.removeAll { seconds - $0.1 > 3 }
        let touchedKeys = dragFrom != nil ? Set(touched()) : []
        for (index, box) in keys.enumerated() {
            var color = KeyPicture.keyOff
            if let picking = picking {
                drawPicking(index, cap(box), picking, size)
                continue
            }
            if ids[index] >= 0 {
                if let colors = colors {
                    let value = index < colors.count ? colors[index] : 0
                    color = fill((Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255))
                } else {
                    var glow = 0.0
                    let barKey = onBar(index) && barEffect != nil
                    let keyEffect = barKey ? barEffect! : effect, keyParameters = barKey ? barParameters : parameters
                    if keyEffect == 0x17 {
                        for ripple in ripples {
                            let distance = hypot(Double(box.midX - ripple.0.x), Double(box.minY + 0.5 - ripple.0.y))
                            let front = (seconds - ripple.1) * 8 / period
                            glow = max(glow, max(0, 1 - abs(distance - front)) * max(0, 1 - (seconds - ripple.1) / 3))
                        }
                    }
                    color = fill(KeyPicture.colorAt(keyEffect, keyParameters, x: Double(box.midX / widthInKeys), y: Double(box.minY / heightInKeys),
                                                    seconds: seconds, ripple: glow))
                }
            }
            if part != 0 && part != (onBar(index) ? 2 : 1), let off = KeyPicture.keyOff.usingColorSpace(.sRGB) {
                color = color.usingColorSpace(.sRGB)?.blended(withFraction: 0.7, of: off) ?? color
            }
            let rect = cap(box)
            let path = keyPath(index, rect)
            // An ISO Enter is an L: its first row widened to the left by the lip.
            if !shaped.contains(index), let lip = lips[index] {
                path.append(NSBezierPath(roundedRect: cap(CGRect(x: box.minX - lip, y: box.minY, width: box.width + lip, height: 1)), xRadius: 3, yRadius: 3))
            }
            fillKey(index, path, rect, color)
            if touchedKeys.contains(index) || (marked.map { index < $0.count && $0[index] } ?? false) {
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
        }
        if dragged {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: marquee).fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: marquee.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }
}
