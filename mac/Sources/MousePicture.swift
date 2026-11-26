import AppKit

// The live mouse picture (app/MousePage.cs, MousePicture): a mouse with its light glowing as the effect runs, and beside it the DPI,
// the stage and the report rate.
// The PRO family's shape (the G Pro Wireless, the PRO X SUPERLIGHTs), from a photo: a dome at each end, nearly straight sides, the
// buttons in grooves set in from the sides, the wheel in its slot, side buttons on both sides, the DPI dots and the light on the palm,
// drawn as G-Lite's logo. dex: the PRO X 2 DEX, right-handed, from its photo: narrower at the front than at the rear, a slight waist on
// the left below the side buttons. g502: the G502 family's, traced from a schematic of the G502 LIGHTSPEED: the buttons as blades
// either side of a strip with the wheel, the mode button and G9, G7 and G8 on the left, the thumb rest bulging at the left rear, the
// palm with the logo and the DPI lights, both lit in the mouse's colour. Other mice get a plain rounded shape.
final class MousePicture: NSView {
    private static let textGap: CGFloat = 70, textWidth: CGFloat = 220
    private static let border = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: 0x4A4A4A) : NSColor(rgb: 0xA8A8A8) }
    var pro = false, dex = false, g502 = false
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

    // Points across (0 left, 1 right) and down (0 front, 1 rear) a box.
    private static func point(_ box: CGRect) -> (CGFloat, CGFloat) -> CGPoint {
        { across, down in CGPoint(x: box.minX + box.width * across, y: box.minY + box.height * down) }
    }

    private static func lines(_ path: NSBezierPath, _ points: [CGPoint]) { for point in points { path.line(to: point) } }

    // The outline in its box: the G502's, the DEX's, the PRO family's (a little wider at the rear), or a plain rounded one.
    private func body(_ box: CGRect) -> NSBezierPath {
        if g502 { return MousePicture.g502Body(box) }
        if !pro { return NSBezierPath(roundedRect: box, xRadius: box.width / 2, yRadius: box.width / 2) }
        if dex { return MousePicture.dexBody(box) }
        let at = MousePicture.point(box)
        let path = NSBezierPath()
        path.move(to: at(0.5, 0))
        path.curve(to: at(0.985, 0.22), controlPoint1: at(0.79, 0), controlPoint2: at(0.98, 0.07))
        path.line(to: at(1, 0.7))
        path.curve(to: at(0.5, 1), controlPoint1: at(1, 0.92), controlPoint2: at(0.78, 1))
        path.curve(to: at(0, 0.7), controlPoint1: at(0.22, 1), controlPoint2: at(0, 0.92))
        path.line(to: at(0.015, 0.22))
        path.curve(to: at(0.5, 0), controlPoint1: at(0.02, 0.07), controlPoint2: at(0.21, 0))
        path.close()
        return path
    }

    // The two button blades at the front with the strip's notch between them, the right side, the rear, and the left side's thumb rest
    // and side buttons back up to the left blade.
    private static func g502Body(_ box: CGRect) -> NSBezierPath {
        let at = point(box)
        let path = NSBezierPath()
        path.move(to: at(0.21, 0.095))
        lines(path, [at(0.477, 0.018), at(0.485, 0.093), at(0.64, 0.095), at(0.621, 0.002), at(0.858, 0.089)])
        path.curve(to: at(0.966, 0.292), controlPoint1: at(0.9, 0.12), controlPoint2: at(0.95, 0.2))
        lines(path, [at(0.992, 0.704), at(0.975, 0.745)])
        path.curve(to: at(0.533, 1), controlPoint1: at(0.96, 0.9), controlPoint2: at(0.75, 1))
        path.curve(to: at(0.025, 0.698), controlPoint1: at(0.35, 1), controlPoint2: at(0.18, 0.85))
        path.line(to: at(0.005, 0.67))
        path.curve(to: at(0.08, 0.453), controlPoint1: at(0, 0.55), controlPoint2: at(0.01, 0.47))
        lines(path, [at(0.1, 0.45), at(0.084, 0.382), at(0.115, 0.328), at(0.098, 0.28), at(0.21, 0.095)])
        path.close()
        return path
    }

    private static func dexBody(_ box: CGRect) -> NSBezierPath {
        let at = point(box)
        let path = NSBezierPath()
        path.move(to: at(0.5, 0))
        path.curve(to: at(0.93, 0.18), controlPoint1: at(0.78, 0), controlPoint2: at(0.92, 0.06))
        path.curve(to: at(0.995, 0.72), controlPoint1: at(0.95, 0.4), controlPoint2: at(0.99, 0.55))
        path.curve(to: at(0.5, 1), controlPoint1: at(1, 0.92), controlPoint2: at(0.78, 1))
        path.curve(to: at(0.005, 0.75), controlPoint1: at(0.2, 1), controlPoint2: at(0, 0.9))
        path.curve(to: at(0.07, 0.5), controlPoint1: at(0.01, 0.62), controlPoint2: at(0.07, 0.58))
        path.curve(to: at(0.05, 0.2), controlPoint1: at(0.07, 0.38), controlPoint2: at(0.04, 0.28))
        path.curve(to: at(0.5, 0), controlPoint1: at(0.06, 0.06), controlPoint2: at(0.22, 0))
        path.close()
        return path
    }

    private static func fill(_ rect: CGRect, _ radius: CGFloat, _ color: NSColor, _ edge: NSColor? = nil) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
        if let edge = edge { edge.setStroke(); path.lineWidth = 1; path.stroke() }
    }

    private static func line(_ from: CGPoint, _ to: CGPoint, _ width: CGFloat = 1.5) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.stroke()
    }

    // The wheel in its slot, ridged.
    private static func wheel(_ slot: CGRect, slotRound: CGFloat, width: CGFloat, round: CGFloat) {
        fill(slot, slot.width * slotRound, KeyPicture.background)
        let wheel = CGRect(x: slot.minX + slot.width * (1 - width) / 2, y: slot.minY + slot.height * 0.08, width: slot.width * width,
                           height: slot.height * 0.84)
        fill(wheel, wheel.width * round, border)
        KeyPicture.background.setStroke()
        for ridge in 1..<8 {
            let y = wheel.minY + wheel.height * CGFloat(ridge) / 8
            line(CGPoint(x: wheel.minX + 1, y: y), CGPoint(x: wheel.maxX - 1, y: y), 1)
        }
    }

    // The plain shape and the PRO family's: their outline, the buttons' grooves, the wheel and the PRO's side buttons and DPI dots.
    private func drawBody(_ box: CGRect) {
        let x = box.minX, y = box.minY, width = box.width, height = box.height
        // Where the buttons end.
        let split = height * (dex ? 0.46 : pro ? 0.45 : 0.4)
        // Side buttons: both sides on the G Pro's family (ambidextrous), the left only on the DEX.
        if pro {
            for side: CGFloat in dex ? [0] : [0, 1] {
                for buttonTop: CGFloat in dex ? [0.28, 0.45] : [0.44, 0.53] {
                    MousePicture.fill(CGRect(x: x + (dex ? width * 0.05 : side * width) - 2.5, y: y + height * buttonTop, width: 5,
                                             height: height * (dex ? 0.16 : 0.085)), 2, KeyPicture.keyOff, MousePicture.border)
                }
            }
        }
        let path = body(box)
        KeyPicture.keyOff.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        KeyPicture.background.setStroke()
        MousePicture.line(CGPoint(x: x + width / 2, y: y), CGPoint(x: x + width / 2, y: y + split))
        if pro {
            // The buttons' outer grooves, from the notch near the front to where they end (the DEX's, from its photo); their rear
            // corners are rounded, as on the mouse.
            let notch: CGFloat = dex ? 0.12 : 0.1, leftTop: CGFloat = dex ? 0.12 : 0.07, leftBottom: CGFloat = dex ? 0.15 : 0.1
            let rightTop: CGFloat = dex ? 0.91 : 0.93, rightBottom: CGFloat = dex ? 0.89 : 0.9
            let corner = width * 0.06, left = x + width * leftBottom, right = x + width * rightBottom, bottom = y + split
            let grooves = NSBezierPath()
            grooves.move(to: CGPoint(x: x, y: y + height * notch))
            grooves.line(to: CGPoint(x: x + width * leftTop, y: y + height * notch))
            grooves.line(to: CGPoint(x: left, y: bottom - corner))
            grooves.curve(to: CGPoint(x: left + corner, y: bottom), controlPoint1: CGPoint(x: left, y: bottom - corner * 0.45),
                          controlPoint2: CGPoint(x: left + corner * 0.45, y: bottom))
            grooves.line(to: CGPoint(x: right - corner, y: bottom))
            grooves.curve(to: CGPoint(x: right, y: bottom - corner), controlPoint1: CGPoint(x: right - corner * 0.45, y: bottom),
                          controlPoint2: CGPoint(x: right, y: bottom - corner * 0.45))
            grooves.line(to: CGPoint(x: x + width * rightTop, y: y + height * notch))
            grooves.line(to: CGPoint(x: x + width, y: y + height * notch))
            grooves.lineWidth = 1.5
            grooves.stroke()
        } else {
            MousePicture.line(CGPoint(x: x, y: y + split), CGPoint(x: x + width, y: y + split))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        if pro {
            let slot = dex ? CGRect(x: x + width * 0.43, y: y + height * 0.135, width: width * 0.15, height: height * 0.165)
                : CGRect(x: x + width * 0.415, y: y + height * 0.11, width: width * 0.17, height: height * 0.17)
            MousePicture.wheel(slot, slotRound: 0.35, width: 0.5, round: 0.5)
        }
        if pro && !dex {
            MousePicture.border.setFill()
            for dot in 0..<3 {
                NSBezierPath(ovalIn: CGRect(x: x + width / 2 - 1.5, y: y + height * (0.485 + CGFloat(dot) * 0.03), width: 3, height: 3)).fill()
            }
        }
        if !pro {
            MousePicture.fill(CGRect(x: x + width / 2 - 4, y: y + height * 0.12, width: 8, height: height * 0.17), 4, KeyPicture.background)
        }
    }

    // The G502, in points across its box, traced from the schematic.
    private func drawG502(_ box: CGRect) {
        let at = MousePicture.point(box)
        let path = body(box)
        KeyPicture.keyOff.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        KeyPicture.background.setStroke()
        // The strip between the buttons, each button's rear edge, and its outer edge along G7 and G8.
        MousePicture.line(at(0.485, 0.093), at(0.523, 0.549))
        MousePicture.line(at(0.64, 0.095), at(0.658, 0.52))
        MousePicture.line(at(0.255, 0.563), at(0.52, 0.5))
        MousePicture.line(at(0.66, 0.47), at(0.905, 0.513))
        let edges = NSBezierPath()
        edges.move(to: at(0.234, 0.095)); MousePicture.lines(edges, [at(0.22, 0.43), at(0.255, 0.563)])
        // The palm: its front edge across to the right side, its rear edge round the logo, and the rear's split.
        edges.move(to: at(0.192, 0.624)); MousePicture.lines(edges, [at(0.659, 0.527), at(0.88, 0.546), at(0.878, 0.668)])
        edges.curve(to: at(0.975, 0.745), controlPoint1: at(0.9, 0.7), controlPoint2: at(0.95, 0.71))
        edges.move(to: at(0.209, 0.626))
        edges.curve(to: at(0.523, 0.833), controlPoint1: at(0.215, 0.72), controlPoint2: at(0.27, 0.78))
        edges.line(to: at(0.523, 1))
        edges.lineWidth = 1.5
        edges.lineJoinStyle = .round
        edges.stroke()
        MousePicture.line(at(0.105, 0.274), at(0.23, 0.262))
        MousePicture.line(at(0.109, 0.289), at(0.25, 0.561))
        MousePicture.line(at(0.586, 0.835), at(0.611, 1))
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        // The wheel in its slot, then the mode button and G9 below it; the arrows either side for its tilt.
        let origin = at(0.505, 0.16)
        MousePicture.wheel(CGRect(x: origin.x, y: origin.y, width: box.width * 0.135, height: box.height * 0.175), slotRound: 0.3, width: 0.56, round: 0.3)
        for (corner, size) in [(at(0.515, 0.357), CGSize(width: box.width * 0.125, height: box.height * 0.066)),
                               (at(0.52, 0.435), CGSize(width: box.width * 0.12, height: box.height * 0.078))] {
            MousePicture.fill(CGRect(origin: corner, size: size), 2, KeyPicture.keyOff, KeyPicture.background)
        }
        MousePicture.border.setFill()
        for arrow in [[at(0.405, 0.25), at(0.44, 0.237), at(0.44, 0.263)], [at(0.73, 0.25), at(0.695, 0.237), at(0.695, 0.263)]] {
            let triangle = NSBezierPath()
            triangle.move(to: arrow[0]); MousePicture.lines(triangle, [arrow[1], arrow[2]]); triangle.close()
            triangle.fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // The mouse and its text centred together, the text counted at a fixed width so the picture doesn't move as the DPI does.
        let height = bounds.height - 16, width = height * (g502 ? 0.57 : dex ? 0.54 : pro ? 0.5 : 0.6), y: CGFloat = 8
        let x = max(8, (bounds.width - width - MousePicture.textGap - MousePicture.textWidth) / 2)
        let box = CGRect(x: x, y: y, width: width, height: height)
        if g502 { drawG502(box) } else { drawBody(box) }

        let rgb = glow(Date().timeIntervalSince(clock)), top = max(rgb.0, rgb.1, rgb.2)
        let radius = width * (g502 ? 0.09 : dex ? 0.1 : pro ? 0.12 : 0.17)
        let center = CGPoint(x: x + width * (g502 ? 0.4 : 0.5), y: y + height * (g502 ? 0.686 : dex ? 0.74 : pro ? 0.75 : 0.68))
        var fill: NSColor = pro || g502 ? MousePicture.border : KeyPicture.background
        if top > 0 {
            let full = NSColor(srgbRed: CGFloat(rgb.0 / top), green: CGFloat(rgb.1 / top), blue: CGFloat(rgb.2 / top), alpha: 1)
            fill = KeyPicture.background.blended(withFraction: CGFloat(top), of: full) ?? full
            // The light's glow on the shell, fading out from the logo.
            NSGraphicsContext.saveGraphicsState()
            body(box).addClip()
            NSGradient(starting: full.withAlphaComponent(CGFloat(110.0 / 255 * top)), ending: full.withAlphaComponent(0))?
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius * 2.4, options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
        if g502 {
            fill.setStroke()
            for dpiLight in 0..<3 {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: x + width * 0.183, y: y + height * (0.459 + CGFloat(dpiLight) * 0.036)))
                path.line(to: CGPoint(x: x + width * 0.168, y: y + height * (0.483 + CGFloat(dpiLight) * 0.036)))
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.stroke()
            }
        }
        let logo = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
        if (pro || g502), let context = NSGraphicsContext.current?.cgContext {
            Logo.paint(context, logo, fill, KeyPicture.keyOff)
        } else {
            fill.setFill()
            NSBezierPath(ovalIn: logo).fill()
        }

        let textX = x + width + MousePicture.textGap, textTop = bounds.height / 2 - 46
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
