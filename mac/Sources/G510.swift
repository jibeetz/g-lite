import Foundation

// The G510 and G510s backlight (app/G510.cs, docs/G510.md): one colour for the whole keyboard in feature report 0x05 (`05 R G B`),
// with no brightness or effects of its own, so brightness scales the colour and G-Lite runs Breathe and Cycle by sending frames.
// From the Linux driver hid-lg-g15 (facts only) and an owner's report.
struct G510Settings: Equatable {
    static let staticEffect = 0, breathe = 1, cycle = 2, minPeriod = 1000, maxPeriod = 20000
    static let effects = ["Off", "Static", "Breathe", "Cycle"]
    var on = true
    var color = 0xFFFFFF, bright = 100, effect = 0, period = 5000

    // Static ignores the period.
    func same(_ other: G510Settings?) -> Bool {
        guard let other = other else { return false }
        return on == other.on && color == other.color && bright == other.bright && effect == other.effect
            && (effect == G510Settings.staticEffect || period == other.period)
    }

    func toText() -> String {
        "\(on ? 1 : 0)," + String(format: "%06X", color) + ",\(bright)" + (effect == G510Settings.staticEffect ? "" : ",\(effect),\(period)")
    }

    static func fromText(_ text: String) -> G510Settings? {
        let parts = text.components(separatedBy: ",")
        guard parts.count >= 3, let color = Int(parts[1], radix: 16), let bright = Int(parts[2]) else { return nil }
        var effect = staticEffect, period = 5000
        if parts.count >= 5, let readEffect = Int(parts[3]), readEffect >= staticEffect, readEffect <= cycle, let readPeriod = Int(parts[4]) {
            effect = readEffect; period = readPeriod
        }
        return G510Settings(on: parts[0] != "0", color: color & 0xFFFFFF, bright: max(1, min(100, bright)), effect: effect,
                            period: max(minPeriod, min(maxPeriod, period)))
    }
}

enum G510Lighting {
    static let backlight: UInt8 = 0x05

    static func read(_ hidpp: Hidpp) throws -> Int {
        let report = try hidpp.getFeature(backlight)
        guard report.count >= 4 else { throw GLiteError.io("The keyboard's backlight report is too short") }
        return Int(report[1]) << 16 | Int(report[2]) << 8 | Int(report[3])
    }

    static func scale(_ color: Int, _ factor: Double) -> Int {
        Int(Double(color >> 16 & 0xFF) * factor) << 16 | Int(Double(color >> 8 & 0xFF) * factor) << 8 | Int(Double(color & 0xFF) * factor)
    }

    static func frame(_ settings: G510Settings, _ milliseconds: Double) -> Int {
        if !settings.on { return 0 }
        let brightness = Double(settings.bright) / 100
        let phase = milliseconds.truncatingRemainder(dividingBy: Double(settings.period)) / Double(settings.period)
        if settings.effect == G510Settings.breathe { return scale(settings.color, brightness * (0.5 - 0.5 * cos(2 * Double.pi * phase))) }
        if settings.effect == G510Settings.cycle { return scale(LitraProtocol.hue(phase), brightness) }
        return scale(settings.color, brightness)
    }

    static func set(_ hidpp: Hidpp, _ color: Int, quiet: Bool = false) throws {
        try hidpp.setFeature([backlight, UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)], quiet: quiet)
    }
}
