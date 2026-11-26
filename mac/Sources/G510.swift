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

// The G510's G keys and Game mode switch. Input report 0x03 (hid-lg-g15, facts only): G1–G8 in byte 1, G9–G16 in byte 2, G17 and
// G18 bits 0 and 1 of byte 3, the Game mode switch bit 2 (the keyboard turns its Windows keys off itself), M1–M3 and MR bits 4 to 7.
// The keyboard keeps no bindings: G-Lite keeps three sets, one per M key, as `gkeys.<device>.m1` to `.m3`, a binding (Buttons.cs's
// four bytes) per key in hex. Nothing reads the G keys yet, so the bindings do nothing until G-Lite listens to report 0x03.
enum G510Keys {
    static let count = 18, banks = 3
    static let keysReport: UInt8 = 0x03
    static let names = (1...count).map { "G\($0)" }
    static let unbound: [UInt8] = [0x80, 0x00, 0x00, 0x00]

    static func fromText(_ text: String) -> [[UInt8]] {
        let parts = text.split(separator: " ")
        return (0..<count).map { i in
            guard i < parts.count, parts[i].count == 8, let value = UInt32(parts[i], radix: 16) else { return unbound }
            return [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
    }

    static func toText(_ bindings: [[UInt8]]) -> String {
        bindings.map { $0.map { String(format: "%02X", $0) }.joined() }.joined(separator: " ")
    }

    // Feature 0x04 lights the M keys, one bit each: M1 0x80, M2 0x40, M3 0x20, MR 0x10 (hid-lg-g15; an owner's report reads 80).
    static let bankLights: UInt8 = 0x04

    static func lightBank(_ hidpp: Hidpp, _ bank: Int) throws { try hidpp.setFeature([bankLights, UInt8(0x80 >> bank)]) }

    // The M key lit, or fallback when none of M1 to M3 is.
    static func litBank(_ hidpp: Hidpp, _ fallback: Int) throws -> Int {
        let mask = Int(try hidpp.getFeature(bankLights)[1])
        return (0..<banks).first { mask & 0x80 >> $0 != 0 } ?? fallback
    }

    // Asked for once (GET_REPORT), not listened to.
    static func gameMode(_ hidpp: Hidpp) throws -> Bool {
        let report = try hidpp.getInput(keysReport)
        if report.count < 4 { throw GLiteError.io(String(format: "Input report %02X is too short", keysReport)) }
        return report[3] & 0x04 != 0
    }
}
