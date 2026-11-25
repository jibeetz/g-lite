import Foundation

// 0x8070 zones: the G560 speakers and the keyboards with 0x8070 and no 0x8071 (the G213, G413, G512, G513, G PRO, G810, G910, G410),
// from app/ZoneLighting.cs. See docs/keyboards-8070.md, docs/G213.md and docs/G560.md.
enum ZoneLighting {
    // Where a zone is (fn 1 bytes 1-2), kept in its effect map under this key.
    static let place = -1
    static let names = ["Bottom left", "Bottom right", "Top left", "Top right"]
    static let effects = MouseProtocol.effects + [
        EffectInfo(id: 0x04, name: "Wave", speed: true, direction: true, minPeriod: 1000, maxPeriod: 20000, defaultPeriod: 5000),
    ]
    static let directions = [6, 1, 3, 8]
    static let directionNames = ["Left", "Right", "Center out", "Center in"]

    // Drawn by G-Lite on a keyboard, not by it: the loudness of the Mac's sound sets each zone's level, sent as Static (ZonesPage.audioTick).
    // The id is the per-key Audio effect's (LiveEffects), so a lighting text means the same effect on either screen.
    static let audio = EffectInfo(id: 0xE2, name: "Audio", color: true)

    static func effect(_ id: UInt8) -> EffectInfo? { effects.first { $0.id == id } ?? (id == audio.id ? audio : nil) }

    // A live effect's id is known too, so a lighting text holding one, from a keyboard with 0x8080, reads back (app/ZoneLighting.cs,
    // EffectById). Not Screen: on these keyboards it's the speakers' only.
    static func known(_ id: UInt8) -> EffectInfo? { effect(id) ?? (id == 0xFE ? nil : LiveEffects.info(id)) }

    // A 0x8081 lighting id's USB usage (app/GameMode.cs, Usage): the picture's ids are lighting ids.
    static func usage(_ lightingId: Int) -> Int {
        if lightingId >= 0x01 && lightingId <= 0x64 { return lightingId + 3 }
        if lightingId >= 0x68 && lightingId <= 0x6F { return 0xE0 + lightingId - 0x68 }
        return -1
    }

    // 0x8080, per-key colours on the G512 and G513 generation, from OpenLogi (MIT) and g810-led (GPL, facts only), as on Windows: fn 3
    // takes 00 01 (keys, by USB usage), the count as two bytes, then key R G B, three to a message; posted, as neither waits for a
    // reply; fn 5 shows them and its reply is waited for. Untried on a keyboard.
    static func sendKeys(_ hidpp: Hidpp, _ colorById: [Int: Int]) throws {
        let feature = try hidpp.featureIndex(0x8080)
        let keys = colorById.map { (usage($0.key), $0.value) }.filter { $0.0 >= 0 }.sorted { $0.0 < $1.0 }
        for at in stride(from: 0, to: keys.count, by: 3) {
            let batch = keys[at..<min(at + 3, keys.count)]
            var parameters: [UInt8] = [0x00, 0x01, 0x00, UInt8(batch.count)]
            for (usage, color) in batch { parameters += [UInt8(usage), UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)] }
            try hidpp.postUnlogged(feature, 3, parameters)
        }
        _ = try hidpp.callUnlogged(feature, 5)
    }

    // Wave 0x04: OpenRGB's layout for the G915 (docs/G815-G915.md): period low at 6, direction 7, intensity 8, period high 9.
    static func encode(_ light: MouseLight) -> [UInt8] {
        if light.effect != 0x04 { return MouseProtocol.encode(light) }
        var p = [UInt8](repeating: 0, count: 10)
        p[6] = UInt8(light.period & 0xFF); p[7] = UInt8(light.direction & 0xFF)
        p[8] = UInt8(max(1, min(100, light.bright))); p[9] = UInt8(light.period >> 8 & 0xFF)
        return p
    }

    // A zone's colour at a place and time, for the key picture (app/ZoneLighting.cs, ColorAt).
    static func colorAt(_ light: MouseLight, _ x: Double, _ seconds: Double) -> Int {
        if light.effect == 0 { return 0 }
        let period = Double(max(1, light.period)) / 1000, brightness = Double(max(1, min(100, light.bright))) / 100
        func scale(_ rgb: (Double, Double, Double), _ factor: Double) -> Int {
            let f = max(0, min(1, factor))
            return Int(rgb.0 * f * 255) << 16 | Int(rgb.1 * f * 255) << 8 | Int(rgb.2 * f * 255)
        }
        let color = (Double(light.color >> 16 & 0xFF) / 255, Double(light.color >> 8 & 0xFF) / 255, Double(light.color & 0xFF) / 255)
        switch light.effect {
        case 0x01: return scale(color, brightness)
        case 0x0A: return scale(color, brightness * (0.5 - 0.5 * cos(2 * Double.pi * seconds / period)))
        case 0x03: return scale(KeyPicture.hsv(seconds / period, 1, 1), brightness)
        case 0x04:
            let offset = light.direction == 1 ? -x : light.direction == 3 ? -abs(x - 0.5) * 2 : light.direction == 8 ? abs(x - 0.5) * 2 : x
            return scale(KeyPicture.hsv(seconds / period + offset, 1, 1), brightness)
        default: return 0
        }
    }

    // 0x8070 locations: 1 the keys, 2 the logo, 6–11 primary 1 to 6 (the G213's five areas, see docs/G213.md).
    static func isArea(_ place: Int) -> Bool { place >= 6 && place <= 11 }

    static func zoneName(_ place: Int, _ index: Int) -> String {
        place == 1 ? "Keys" : place == 2 ? "Logo" : isArea(place) ? "Zone \(place - 5)" : "Zone \(index + 1)"
    }

    // fn 0 bytes 3–4 are the extended capabilities, and bit 3 says the LEDs have one colour (docs/lighting-control.md): set on a G413
    // Silver, whose backlight is white (docs/reports/g413-c33a.txt), clear on the G213 and the G560.
    static func zones(_ hidpp: Hidpp) throws -> (zones: [[Int: Int]], monochrome: Bool) {
        let feature = try hidpp.featureIndex(0x8070)
        let device = try hidpp.call(feature, 0)
        var zones: [[Int: Int]] = []
        for zone in 0..<Int(device[0]) {
            let info = try hidpp.call(feature, 1, [UInt8(zone), 0xFF, 0])
            var map = [place: Int(info[1]) << 8 | Int(info[2])]
            for effectIndex in 0..<Int(info[3]) {
                let reply = try hidpp.call(feature, 2, [UInt8(zone), UInt8(effectIndex), 0xFF, 0])
                map[Int(reply[2]) << 8 | Int(reply[3])] = effectIndex
            }
            zones.append(map)
        }
        return (zones, device[4] & 0x08 != 0)
    }

    static func setLight(_ hidpp: Hidpp, _ zone: Int, _ effects: [Int: Int], _ light: MouseLight, quiet: Bool = false) throws {
        guard let index = effects[Int(light.effect)] else { return }
        let feature = try hidpp.featureIndex(0x8070), parameters = [UInt8(zone), UInt8(index)] + encode(light)
        if quiet { _ = try hidpp.callUnlogged(feature, 3, parameters) } else { try hidpp.call(feature, 3, parameters) }
    }

    // A Static colour for the Screen effect, kept out of the log (ZoneLighting.SetColor).
    static func setColor(_ hidpp: Hidpp, _ zone: Int, _ effects: [Int: Int], _ color: Int, bright: Int = 100) throws {
        guard let index = effects[0x01] else { return }
        try hidpp.callUnlogged(try hidpp.featureIndex(0x8070), 3,
                               [UInt8(zone), UInt8(index)] + encode(MouseLight(effect: 0x01, color: color, bright: bright)))
    }

    // One light per zone, ";" between zones; one light alone sets every zone. Wave keeps its direction (app/ZoneLighting.cs).
    static func toText(_ lights: [MouseLight?]) -> String {
        lights.map { light in
            guard let light = light else { return "" }
            return "\(light.effect)," + String(format: "%06X", light.color) + ",\(light.period),\(light.bright)"
                + (light.effect == 0x04 || LiveEffects.isLive(light.effect) ? ",\(light.direction)" : "")
        }.joined(separator: ";")
    }

    static func fromText(_ text: String, _ zones: Int) -> [MouseLight?]? {
        let parts = text.components(separatedBy: ";")
        let lights = (0..<zones).map { parse(parts.count == 1 ? parts[0] : $0 < parts.count ? parts[$0] : "") }
        return lights.contains { $0 != nil } ? lights : nil
    }

    static func parse(_ text: String) -> MouseLight? {
        let parts = text.components(separatedBy: ",")
        guard parts.count >= 4, let id = UInt8(parts[0]), let info = known(id), let color = Int(parts[1], radix: 16),
              var period = Int(parts[2]), let bright = Int(parts[3]) else { return nil }
        if info.speed { period = max(info.minPeriod, min(info.maxPeriod, period)) }
        let live = LiveEffects.isLive(id), allowed = live ? LiveEffects.directions : directions
        var direction = parts.count > 4 ? Int(parts[4]) ?? -1 : -1
        if !allowed.contains(direction) { direction = live ? LiveEffects.defaultDirection(id) : 6 }
        return MouseLight(effect: id, color: color & 0xFFFFFF, period: period, bright: max(1, min(100, bright)), direction: direction)
    }
}
