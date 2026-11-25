import AppKit

// The live mouse picture (app/MousePage.cs, MousePicture): a mouse with its light glowing as the effect runs, and beside it the DPI,
// the stage and the report rate.
final class MousePicture: NSView {
    private var light: MouseLight?
    private var dpi = 0
    private var stage = "", rate = ""
    private let clock = Date()
    private var timer: Timer?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 150).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // light nil: no lighting known, drawn cycling as the Windows picture does.
    func display(_ newLight: MouseLight?, dpi newDpi: Int, stage newStage: String, rate newRate: String) {
        light = newLight
        dpi = newDpi
        stage = newStage
        rate = newRate
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = window == nil ? nil : Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isVisible == true else { return }
            self.needsDisplay = true
        }
    }

    private func glow(_ seconds: Double) -> (Double, Double, Double) {
        guard let light = light else { return KeyPicture.hsv(seconds / 8, 1, 1) }
        let color = (Double(light.color >> 16 & 0xFF) / 255, Double(light.color >> 8 & 0xFF) / 255, Double(light.color & 0xFF) / 255)
        let brightness = Double(light.bright) / 100, period = max(1, Double(light.period) / 1000)
        func scale(_ rgb: (Double, Double, Double), _ factor: Double) -> (Double, Double, Double) {
            let f = max(0, min(1, factor))
            return (rgb.0 * f, rgb.1 * f, rgb.2 * f)
        }
        switch light.effect {
        case 0x01: return scale(color, brightness)
        case 0x0A: return scale(color, brightness * (0.5 - 0.5 * cos(2 * Double.pi * seconds / period)))
        case 0x03: return scale(KeyPicture.hsv(seconds / period, 1, 1), brightness)
        default: return (0, 0, 0)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height - 16, width = height * 0.6, x: CGFloat = 70, y: CGFloat = 8
        let body = CGRect(x: x, y: y, width: width, height: height)
        let shell = NSBezierPath(roundedRect: body, xRadius: width / 2, yRadius: width / 2)
        KeyPicture.keyOff.setFill()
        shell.fill()
        // The buttons' seam and the line between them.
        NSGraphicsContext.saveGraphicsState()
        shell.addClip()
        KeyPicture.background.setStroke()
        let seams = NSBezierPath()
        seams.lineWidth = 1.5
        seams.move(to: CGPoint(x: x + width / 2, y: y)); seams.line(to: CGPoint(x: x + width / 2, y: y + height * 0.4))
        seams.move(to: CGPoint(x: x, y: y + height * 0.4)); seams.line(to: CGPoint(x: x + width, y: y + height * 0.4))
        seams.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        shell.stroke()
        // The wheel.
        KeyPicture.background.setFill()
        NSBezierPath(roundedRect: CGRect(x: x + width / 2 - 4, y: y + height * 0.12, width: 8, height: height * 0.17), xRadius: 4, yRadius: 4).fill()

        let rgb = glow(Date().timeIntervalSince(clock)), top = max(rgb.0, rgb.1, rgb.2)
        let radius = width * 0.17, center = CGPoint(x: x + width / 2, y: y + height * 0.68)
        var fill = KeyPicture.background
        if top > 0 {
            let full = NSColor(srgbRed: CGFloat(rgb.0 / top), green: CGFloat(rgb.1 / top), blue: CGFloat(rgb.2 / top), alpha: 1)
            fill = KeyPicture.background.blended(withFraction: CGFloat(top), of: full) ?? full
            // The light's glow on the shell, fading out from the logo.
            NSGraphicsContext.saveGraphicsState()
            shell.addClip()
            NSGradient(starting: full.withAlphaComponent(CGFloat(110.0 / 255 * top)), ending: full.withAlphaComponent(0))?
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius * 2.4, options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
        fill.setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)).fill()

        let textX = x + width + 70, textTop = bounds.height / 2 - 46
        let big = NSAttributedString(string: dpi > 0 ? "\(dpi)" : "–", attributes: [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.labelColor])
        big.draw(at: CGPoint(x: textX, y: textTop))
        NSAttributedString(string: "DPI", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                       .foregroundColor: NSColor.secondaryLabelColor])
            .draw(at: CGPoint(x: textX + big.size().width + 8, y: textTop + big.size().height - 22))
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        NSAttributedString(string: stage, attributes: small).draw(at: CGPoint(x: textX, y: textTop + 58))
        NSAttributedString(string: rate, attributes: small).draw(at: CGPoint(x: textX, y: textTop + 80))
    }
}
