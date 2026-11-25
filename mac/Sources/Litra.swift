import Foundation

// The Litra lights (app/LitraProtocol.cs, docs/Litra.md): the front light on 0x1990 (fn 0/1 on/off, fn 2/7 the lumen and kelvin
// ranges, fn 3/4 lumen, fn 8/9 kelvin) and, on the Beam LX, the back light on 0x8040 (fn 1/2 brightness as `00 <percent>`, fn 3/4
// on/off) and 0x8081 (fn 1, four `<id 1–7> R G B` per message, then fn 7 `00 00 01 00 00`).
struct LightRange {
    var min: Int, max: Int, step: Int

    func snap(_ value: Int) -> Int {
        Swift.max(min, Swift.min(max, min + Int((Double(value - min) / Double(step)).rounded()) * step))
    }
}

struct LightState: Equatable {
    static let zones = 7, staticEffect = 0, breathe = 1, cycle = 2, wave = 3
    static let effects = ["Static", "Breathe", "Cycle", "Wave"]
    static let minPeriod = 1000, maxPeriod = 20000
    var frontOn = false, backOn = true
    var lumen = 0, kelvin = 0, backLevel = 100, effect = 0, period = 5000
    var colors = [Int](repeating: 0xFFFFFF, count: LightState.zones)

    func frontText() -> String { "\(frontOn ? 1 : 0),\(lumen),\(kelvin)" }

    func backText() -> String {
        "\(backOn ? 1 : 0),\(backLevel)," + colors.map { String(format: "%06X", $0) }.joined(separator: "/") + ",\(effect),\(period)"
    }

    mutating func readFront(_ text: String) -> Bool {
        let parts = text.components(separatedBy: ",")
        guard parts.count == 3, let lumen = Int(parts[1]), let kelvin = Int(parts[2]) else { return false }
        frontOn = parts[0] == "1"; self.lumen = lumen; self.kelvin = kelvin
        return true
    }

    mutating func readBack(_ text: String) -> Bool {
        let parts = text.components(separatedBy: ",")
        guard parts.count == 3 || parts.count == 5, let level = Int(parts[1]) else { return false }
        var effect = LightState.staticEffect, period = 5000
        if parts.count == 5 {
            guard let readEffect = Int(parts[3]), let readPeriod = Int(parts[4]), readEffect >= 0, readEffect < LightState.effects.count else {
                return false
            }
            effect = readEffect; period = readPeriod
        }
        let parsed = parts[2].components(separatedBy: "/").compactMap { Int($0, radix: 16) }
        guard parsed.count == LightState.zones, parts[2].components(separatedBy: "/").count == LightState.zones else { return false }
        backOn = parts[0] == "1"
        backLevel = max(1, min(100, level))
        colors = parsed.map { $0 & 0xFFFFFF }
        self.effect = effect
        self.period = max(LightState.minPeriod, min(LightState.maxPeriod, period))
        return true
    }
}

enum LitraProtocol {
    static func front(_ hidpp: Hidpp) throws -> UInt8 { try hidpp.featureIndex(0x1990) }

    static func frontOn(_ hidpp: Hidpp) throws -> Bool { try hidpp.call(try front(hidpp), 0)[0] & 1 != 0 }

    static func setFrontOn(_ hidpp: Hidpp, _ on: Bool) throws { try hidpp.call(try front(hidpp), 1, [on ? 1 : 0]) }

    static func range(_ hidpp: Hidpp, _ fn: Int, fallback: LightRange, lowest: Int, highest: Int) throws -> LightRange {
        let reply = try hidpp.call(try front(hidpp), fn)
        let min = Int(reply[1]) << 8 | Int(reply[2]), max = Int(reply[3]) << 8 | Int(reply[4]), resolution = Int(reply[5]) << 8 | Int(reply[6])
        if min < lowest || max > highest || max <= min { return fallback }
        return LightRange(min: min, max: max, step: resolution > 0 && resolution <= max - min ? resolution : 1)
    }

    static func lumens(_ hidpp: Hidpp) throws -> LightRange {
        try range(hidpp, 2, fallback: LightRange(min: 30, max: 400, step: 1), lowest: 1, highest: 5000)
    }

    static func kelvins(_ hidpp: Hidpp) throws -> LightRange {
        try range(hidpp, 7, fallback: LightRange(min: 2700, max: 6500, step: 100), lowest: 1000, highest: 12000)
    }

    static func get(_ hidpp: Hidpp, _ fn: Int) throws -> Int { let reply = try hidpp.call(try front(hidpp), fn); return Int(reply[0]) << 8 | Int(reply[1]) }

    static func set(_ hidpp: Hidpp, _ fn: Int, _ value: Int) throws {
        try hidpp.call(try front(hidpp), fn, [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func backLevel(_ hidpp: Hidpp) throws -> Int {
        let reply = try hidpp.call(try hidpp.featureIndex(0x8040), 1)
        return Int(reply[0]) << 8 | Int(reply[1])
    }

    static func setBackLevel(_ hidpp: Hidpp, _ level: Int) throws { try hidpp.call(try hidpp.featureIndex(0x8040), 2, [0, UInt8(level & 0xFF)]) }

    static func backOn(_ hidpp: Hidpp) throws -> Bool? {
        do { return try hidpp.call(try hidpp.featureIndex(0x8040), 3)[0] & 1 != 0 } catch GLiteError.hidpp { return nil }
    }

    static func setBackOn(_ hidpp: Hidpp, _ on: Bool) throws {
        do { try hidpp.call(try hidpp.featureIndex(0x8040), 4, [on ? 1 : 0]) } catch GLiteError.hidpp {}
    }

    // Always all seven zones, each channel at least 1 (0 turns a zone off on the Beam LX).
    static func colors(_ hidpp: Hidpp, _ colors: [Int], quiet: Bool = false) throws {
        func call(_ feature: UInt8, _ fn: Int, _ parameters: [UInt8]) throws {
            if quiet { try hidpp.callUnlogged(feature, fn, parameters) } else { try hidpp.call(feature, fn, parameters) }
        }
        let feature = try hidpp.featureIndex(0x8081)
        for start in stride(from: 0, to: colors.count, by: 4) {
            var parameters: [UInt8] = []
            for i in start..<start + 4 {
                if i >= colors.count { parameters += [0xFF, 0, 0, 0]; continue }
                let color = colors[i]
                let channels: [Int] = [color >> 16 & 0xFF, color >> 8 & 0xFF, color & 0xFF]
                parameters.append(UInt8(i + 1))
                parameters += channels.map { (channel: Int) -> UInt8 in UInt8(max(1, channel)) }
            }
            try call(feature, 1, parameters)
        }
        try call(feature, 7, [0, 0, 1, 0, 0])
    }

    // Try effect (app/LitraProtocol.cs): the light's own 0x8071 effects, one picked from the groups fn 0 lists, to learn what each does.
    static func effectName(_ id: UInt8) -> String {
        switch id {
        case 0x00: return "Off"
        case 0x01: return "Static"
        case 0x03: return "Colour cycle"
        case 0x04: return "Colour wave"
        case 0x0A: return "Breathe"
        case 0x13: return "Streaming"
        case 0x15: return "Smooth colour cycle"
        case 0x16: return "Smooth colour wave"
        case 0x18: return "Two colours"
        default: return String(format: "Effect %02X", id)
        }
    }

    static func effectBytes(_ group: Int, _ index: Int, _ id: UInt8, _ state: LightState) -> [UInt8] {
        var parameters = [UInt8](repeating: 0, count: 13)
        parameters[0] = UInt8(group); parameters[1] = UInt8(index)
        let color = state.colors[0], other = state.colors[LightState.zones - 1], period = state.period
        // The keyboards' encoding: smooth cycle and wave (0x15, 0x16) take 00 FF, the period at bytes 6-7 and the intensity at 8, not
        // the older cycle's layout, which the Beam LX ignored (owner's report, 2026-11).
        if [0x01, 0x03, 0x04, 0x0A, 0x0B, 0x15, 0x16].contains(id) {
            parameters.replaceSubrange(2..<12, with: G915Lighting.encode(id, Lighting(effect: id, color: color, period: period)))
        } else {
            parameters[2] = UInt8(color >> 16 & 0xFF); parameters[3] = UInt8(color >> 8 & 0xFF); parameters[4] = UInt8(color & 0xFF)
            // Two colours, the period at parameters 7-8 and the intensity at 9 (spec x8071 v4, effect 24).
            if id == 0x18 {
                parameters[5] = UInt8(other >> 16 & 0xFF); parameters[6] = UInt8(other >> 8 & 0xFF); parameters[7] = UInt8(other & 0xFF)
                parameters[8] = UInt8(period >> 8 & 0xFF); parameters[9] = UInt8(period & 0xFF)
                parameters[10] = 100
            }
        }
        parameters[12] = 1
        return parameters
    }

    // 0x8071 fn 1 needs software control of the clusters (fn 5 bit 0) first: without it the Beam LX answers 0x05 (an owner's report,
    // docs/lighting-control.md).
    static func tryEffect(_ hidpp: Hidpp, _ group: Int, _ index: Int, _ id: UInt8, _ state: LightState) throws {
        try hidpp.call(try hidpp.featureIndex(0x8071), 5, [0x01, 0x01, 0x00])
        try hidpp.call(try hidpp.featureIndex(0x8071), 1, effectBytes(group, index, id, state))
    }

    static func release(_ hidpp: Hidpp) {
        do { try hidpp.call(try hidpp.featureIndex(0x8071), 5, [0x01, 0x00, 0x00]) } catch {}
    }

    // Breathe, Cycle and Wave are G-Lite's own frames: the light keeps a colour per zone, not an effect.
    static func frame(_ state: LightState, _ milliseconds: Double) -> [Int] {
        let phase = milliseconds.truncatingRemainder(dividingBy: Double(state.period)) / Double(state.period)
        return (0..<LightState.zones).map { zone in
            switch state.effect {
            case LightState.breathe: return scale(state.colors[zone], 0.5 - 0.5 * cos(2 * Double.pi * phase))
            case LightState.cycle: return hue(phase)
            case LightState.wave: return hue(phase - Double(zone) / Double(LightState.zones))
            default: return state.colors[zone]
            }
        }
    }

    static func scale(_ color: Int, _ factor: Double) -> Int {
        Int((Double(color >> 16 & 0xFF) * factor).rounded()) << 16 | Int((Double(color >> 8 & 0xFF) * factor).rounded()) << 8
            | Int((Double(color & 0xFF) * factor).rounded())
    }

    static func hue(_ turn: Double) -> Int {
        let position = (turn.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let sector = Int(position) % 6
        let rise = Int(((position - position.rounded(.down)) * 255).rounded()), fall = 255 - rise
        let rgb = [[255, rise, 0], [fall, 255, 0], [0, 255, rise], [0, fall, 255], [rise, 0, 255], [255, 0, fall]][sector]
        return rgb[0] << 16 | rgb[1] << 8 | rgb[2]
    }
}
