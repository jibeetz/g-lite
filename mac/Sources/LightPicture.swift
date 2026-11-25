import AppKit

// The light seen from the front (app/LightPage.cs, LightPicture): the front panel in its colour temperature, the back light's seven
// zones glowing behind it, and the zone picked underlined; a click picks a zone.
final class LightPicture: NSView {
    var picked: ((Int) -> Void)?
    private var back = false, frontOn = false, backOn = false, front = 0.0, level = 0.0, kelvin = 4000, selected = -1
    private var colors: [Int]?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 58).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        setAccessibilityRole(.image)
        setAccessibilityLabel("Light")
    }

    required init?(coder: NSCoder) { fatalError() }

    // selected: the zone picked (1 to 7), 0 for All, -1 when zones can't be picked.
    func display(back hasBack: Bool, frontOn frontLit: Bool, front frontLevel: Double, kelvin frontKelvin: Int, backOn backLit: Bool,
                 level backLevel: Double, colors zones: [Int]?, selected pick: Int) {
        back = hasBack; frontOn = frontLit; front = frontLevel; kelvin = frontKelvin; backOn = backLit; level = backLevel
        colors = zones; selected = pick
        needsDisplay = true
    }

    private var bar: CGRect {
        let width = bounds.width * 0.64, height = width / 12
        return CGRect(x: (bounds.width - width) / 2, y: bounds.height - height - 4, width: width, height: height)
    }

    static func warmth(_ kelvin: Int) -> NSColor {
        let fraction = max(0, min(1, Double(kelvin - 2700) / 3800))
        return NSColor(rgb: Int(255 - 10 * fraction) << 16 | Int(214 + 36 * fraction) << 8 | Int(170 + 85 * fraction))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = self.bar
        let housing = CGRect(x: bar.minX + bar.height * 0.3, y: bar.minY - bar.height * 0.3, width: bar.width - bar.height * 0.6, height: bar.height)
        if back && backOn, let zones = colors, let context = NSGraphicsContext.current?.cgContext {
            let zoneWidth = housing.width / CGFloat(zones.count)
            for (zone, color) in zones.enumerated() where color >= 0 {
                let glow = CGRect(x: housing.minX + CGFloat(zone) * zoneWidth - zoneWidth * 0.35, y: 0, width: zoneWidth * 1.7,
                                  height: housing.minY * 2 + bar.height * 0.4)
                let tint = NSColor(rgb: color)
                let colorsArray = [tint.withAlphaComponent(CGFloat(max(0.35, level))).cgColor, tint.withAlphaComponent(0).cgColor] as CFArray
                guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colorsArray, locations: [0, 1]) else { continue }
                context.saveGState()
                context.translateBy(x: glow.midX, y: glow.midY)
                context.scaleBy(x: glow.width / 2, y: glow.height / 2)
                context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
                context.restoreGState()
            }
        }
        NSColor(rgb: 0x18181A).setFill()
        NSBezierPath(roundedRect: housing, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        let face = frontOn ? NSColor(rgb: 0x6E6E6E).blended(withFraction: CGFloat(0.55 + 0.45 * front), of: LightPicture.warmth(kelvin)) ?? .white
            : KeyPicture.keyOff
        face.setFill()
        let panel = NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2)
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.stroke()
        if back && selected > 0, let zones = colors {
            let zoneWidth = bar.width / CGFloat(zones.count)
            NSColor.controlAccentColor.setStroke()
            let mark = NSBezierPath(roundedRect: CGRect(x: bar.minX + CGFloat(selected - 1) * zoneWidth + 2, y: bar.maxY + 2, width: zoneWidth - 4, height: 2),
                                    xRadius: 1, yRadius: 1)
            mark.lineWidth = 2
            mark.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard back, selected >= 0, let zones = colors, let picked = picked else { return }
        let point = convert(event.locationInWindow, from: nil), bar = self.bar
        let zone = Int((point.x - bar.minX) / (bar.width / CGFloat(zones.count)))
        if zone >= 0 && zone < zones.count { picked(zone + 1) }
    }
}
