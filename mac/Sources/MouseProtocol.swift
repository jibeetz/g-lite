import Foundation

// A mouse's light, in the Windows text (app/Mouse.cs, MouseLight).
struct MouseLight: Equatable {
    var effect: UInt8 = 0x01
    var color = 0xFFFFFF, period = 5000, bright = 100
    // Wave's direction, on the zones devices (ZoneLighting); not in the mouse's text.
    var direction = 6

    func toText() -> String { "\(effect)," + String(format: "%06X", color) + ",\(period),\(bright)" }

    static func fromText(_ text: String) -> MouseLight? {
        let parts = text.components(separatedBy: ",")
        guard parts.count >= 4, let effect = UInt8(parts[0]), let color = Int(parts[1], radix: 16), let period = Int(parts[2]),
              let bright = Int(parts[3]) else { return nil }
        return MouseLight(effect: effect, color: color, period: period, bright: bright)
    }
}

// What the mouse screen edits (app/Mouse.cs, MouseSettings).
struct MouseSettings: Equatable {
    var dpi = 800, rate = 0, stage = -1
    var light: MouseLight?
    var buttons: [[UInt8]]?

    // DPI, the light (effect, colour, period, brightness), the rate, then the buttons as hex (app/Mouse.cs, MouseSettings.FromText).
    static func fromText(_ text: String) -> MouseSettings? {
        let parts = text.components(separatedBy: ",")
        guard parts.count >= 5, let dpi = Int(parts[0]), let effect = UInt8(parts[1]), let color = Int(parts[2], radix: 16),
              let period = Int(parts[3]), let bright = Int(parts[4]) else { return nil }
        var settings = MouseSettings(dpi: dpi, light: MouseLight(effect: effect, color: color, period: period, bright: bright))
        settings.rate = parts.count > 5 ? Int(parts[5]) ?? 0 : 0
        if parts.count > 6, parts[6].count % 8 == 0, !parts[6].isEmpty {
            let bytes = Backups.bytes(parts[6])
            settings.buttons = stride(from: 0, to: bytes.count, by: 4).map { Array(bytes[$0..<$0 + 4]) }
        }
        return settings
    }

    func toText() -> String {
        let light = self.light ?? MouseLight()
        var text = "\(dpi),\(light.effect)," + String(format: "%06X", light.color) + ",\(light.period),\(light.bright),\(rate)"
        if let buttons = buttons { text += "," + buttons.map { Log.hex($0, spaced: false).uppercased() }.joined() }
        return text
    }
}

struct ButtonAction {
    let name: String
    let bytes: [UInt8]
    init(_ name: String, _ hex: String) { self.name = name; bytes = Backups.bytes(hex) }
}

// The bindings in a profile, 4 bytes per button (app/Buttons.cs): `80 01` + mouse button bits, `80 02` + modifiers + HID key usage,
// `80 03` + media usage, `90` + a special (DPI, profile, scroll), `80 00` nothing, `00` a macro.
enum Bindings {
    static let leftClick: [UInt8] = [0x80, 0x01, 0x00, 0x01]
    // What a keyboard's G keys offer: the mouse's clicks, media keys and Disabled, without DPI, scrolling, profiles, G-shift and battery.
    static var keyboardActions: [ButtonAction] { mouseActions.filter { $0.bytes[0] == 0x80 } }

    static let mouseActions = [
        ButtonAction("Left click", "80010001"), ButtonAction("Right click", "80010002"), ButtonAction("Middle click", "80010004"),
        ButtonAction("Back", "80010008"), ButtonAction("Forward", "80010010"),
        ButtonAction("DPI up", "90030000"), ButtonAction("DPI down", "90040000"),
        ButtonAction("DPI cycle", "90050000"), ButtonAction("DPI shift", "90070000"),
        ButtonAction("Scroll left", "90010000"), ButtonAction("Scroll right", "90020000"),
        ButtonAction("Next profile", "90080000"), ButtonAction("Previous profile", "90090000"),
        ButtonAction("G-shift", "900B0000"), ButtonAction("Battery level", "900C0000"),
        ButtonAction("Play or pause", "800300CD"), ButtonAction("Next track", "800300B5"), ButtonAction("Previous track", "800300B6"),
        ButtonAction("Volume up", "800300E9"), ButtonAction("Volume down", "800300EA"), ButtonAction("Mute", "800300E2"),
        ButtonAction("Disabled", "80000000"),
    ]

    static let modifiers = ["Ctrl", "Shift", "Alt", "Win"]

    static func hasLeft(_ buttons: [[UInt8]]?, _ count: Int) -> Bool {
        guard let buttons = buttons else { return false }
        return buttons.prefix(count).contains(leftClick)
    }

    // Factory profiles store a special's last two bytes as FF FF (G502 HERO) or FF 00 (a G502 X LIGHTSPEED), G HUB as 00 00, and "no
    // action" as 80 00 FF FF (Solaar): only the first two bytes say what the button does (g502-hub's docs/protocol.md, facts only). G HUB
    // also writes "no action" as the special 90 00 (a G502 X's profile, docs/G502X.md): shown as Disabled.
    static func find(_ actions: [ButtonAction], _ binding: [UInt8]?) -> Int {
        guard let binding = binding else { return -1 }
        if let exact = actions.firstIndex(where: { $0.bytes == binding }) { return exact }
        guard binding.count >= 2, binding[0] == 0x90 || (binding[0] == 0x80 && binding[1] == 0x00) else { return -1 }
        let kind: UInt8 = binding[0] == 0x90 && binding[1] == 0x00 ? 0x80 : binding[0], function = binding[1]
        return actions.firstIndex { $0.bytes[0] == kind && $0.bytes[1] == function } ?? -1
    }

    static let specials: [UInt8: String] = [0x06: "Default DPI", 0x0A: "Cycle profile", 0x0E: "Mode switch", 0x0F: "Host button",
                                            0x10: "Scroll down", 0x11: "Scroll up"]

    static func key(_ modifiers: Int, _ usage: Int) -> [UInt8] { [0x80, 0x02, UInt8(modifiers), UInt8(usage)] }

    static func keyName(_ usage: Int) -> String {
        if (0x04...0x1D).contains(usage) { return String(UnicodeScalar(UInt8(65 + usage - 0x04))) }
        if (0x1E...0x26).contains(usage) { return String(usage - 0x1E + 1) }
        if (0x3A...0x45).contains(usage) { return "F\(usage - 0x39)" }
        let names: [Int: String] = [
            0x27: "0", 0x28: "Enter", 0x29: "Esc", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space", 0x2D: "-", 0x2E: "=", 0x2F: "[",
            0x30: "]", 0x31: "\\", 0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/", 0x39: "Caps Lock",
            0x46: "Print Screen", 0x47: "Scroll Lock", 0x48: "Pause", 0x49: "Insert", 0x4A: "Home", 0x4B: "Page Up", 0x4C: "Delete",
            0x4D: "End", 0x4E: "Page Down", 0x4F: "Right", 0x50: "Left", 0x51: "Down", 0x52: "Up",
        ]
        return names[usage] ?? String(format: "key %02X", usage)
    }

    static func describe(_ binding: [UInt8]?) -> String {
        guard let binding = binding, binding.count >= 4 else { return "" }
        let index = find(mouseActions, binding)
        if index >= 0 { return mouseActions[index].name }
        if binding[0] == 0x80 && binding[1] == 0x02 {
            var parts: [String] = []
            for bit in 0..<8 where binding[2] >> bit & 1 != 0 && !parts.contains(modifiers[bit % 4]) { parts.append(modifiers[bit % 4]) }
            if binding[3] != 0 { parts.append(keyName(Int(binding[3]))) }
            return parts.joined(separator: " + ")
        }
        if binding[0] == 0x80 && binding[1] == 0x01 { return String(format: "Mouse button %04X", Int(binding[2]) << 8 | Int(binding[3])) }
        if binding[0] == 0x80 && binding[1] == 0x03 { return String(format: "Media key %04X", Int(binding[2]) << 8 | Int(binding[3])) }
        if binding[0] == 0x90, let special = specials[binding[1]] { return special }
        if binding[0] == 0x90 && binding[1] == 0x0D { return "Profile \(binding[3])" }
        if binding[0] == 0x90 { return String(format: "Special %02X", binding[1]) }
        if binding[0] == 0x00 { return "Macro" }
        if binding[0] == 0xFF { return "Not set" }
        return Log.hex(binding, spaced: true)
    }

    // The buttons' names, by model (app/Buttons.cs, Names); others are numbered. The G502 HERO (USB C08B) has the G502 LIGHTSPEED's
    // slots (g502-hub's docs/hardware-notes.md, from its button spy).
    static func names(_ device: FoundDevice, _ count: Int) -> [String] {
        let wireless = device.models.contains("C08B") ? 0x407F : device.wirelessId
        let known: [String]
        if device.isG600 {
            // libratbag's and g600prog's order: G4 and G5 tilt the wheel, G6 is under the ring finger, G7 and G8 are behind the wheel,
            // G9 to G20 the thumb's keypad.
            known = ["Left button", "Right button", "Wheel click", "Wheel tilt left", "Wheel tilt right", "Ring finger (G6)"] + (7...20).map { "G\($0)" }
        } else if wireless == 0x407F {
            known = ["Left button", "Right button", "Wheel click", "Thumb, back", "Thumb, front", "Sniper", "G7", "G8", "G9",
                     "Wheel tilt right", "Wheel tilt left"]
        } else if wireless == 0x409F {
            // The G502 X LIGHTSPEED's slots, from its factory bindings (docs/reports/g502x-409f.txt).
            known = ["Left button", "Right button", "Wheel click", "Thumb, back (G4)", "Sniper (G6)", "Thumb, front (G5)",
                     "Wheel tilt left", "Wheel tilt right", "G9", "G8", "G7"]
        } else if wireless == 0x4079 {
            known = ["Left button", "Right button", "Wheel click", "Left side, back", "Left side, front", "DPI, underneath",
                     "Right side, back", "Right side, front"]
        } else {
            known = ["Left button", "Right button", "Wheel click"]
        }
        return (0..<count).map { $0 < known.count ? known[$0] : "Button \($0 + 1)" }
    }
}

// The mice's HID++ 2.0 calls and their onboard profiles (app/MouseProtocol.cs).
enum MouseProtocol {
    static let effects: [EffectInfo] = [
        EffectInfo(id: 0x00, name: "Off"),
        EffectInfo(id: 0x01, name: "Static", color: true),
        EffectInfo(id: 0x0A, name: "Breathe", color: true, speed: true, minPeriod: 1000, maxPeriod: 20000, defaultPeriod: 5000),
        EffectInfo(id: 0x03, name: "Cycle", speed: true, minPeriod: 1000, maxPeriod: 20000, defaultPeriod: 8000),
    ]

    static func effect(_ id: UInt8) -> EffectInfo? { effects.first { $0.id == id } }

    final class State {
        var dpi = 0, stage = -1, rate = 0
        var dpis: [Int] = [], stages: [Int] = [], rates: [Int] = []
        var onboard = false, profileOk = true, fresh = false, canInvert = false, inverted = false, wired = false
        // A G9x-like mouse: its profiles are flash pages, written page by page (G9xRegisters).
        var flash = false
        // Shown, not changed: the G600, whose writes aren't tried yet.
        var readOnly = false
        // Nothing is set live: every change waits for Save to mouse, which writes the whole profile (the G300's report).
        var saveOnly = false
        var effects = MouseProtocol.effects
        var profilesFeature: UInt8 = 0
        var light: MouseLight?
        // Zone -> (effect id -> effect index), from 0x8070.
        var zones: [Int: [UInt8: Int]] = [:]
        var sector = -1, sectorSize = 0, format = 0, buttonCount = 0
        // 0x8100 fn 0 byte 4; -1 until read. OMM offers no restore on a mouse that has none.
        var factoryProfiles = -1
        var buttons: [[UInt8]]?
        var current: [UInt8]?, profile: [UInt8]?

        var writable: Bool {
            if saveOnly { return profile != nil }
            if readOnly { return false }
            // Pages 1–16 are the flash; 17 and up hold the G500's and G700s's factory profiles (cvuchener's g500 doc/memory.md).
            if flash { return sector >= 2 && sector <= 16 && sectorSize == G9xRegisters.pageSize && current != nil }
            return onboard && (State.classicFormat(format) || State.wideFormat(format)) && sectorSize >= 0xF0
                && ((sector > 0 && sector < 0x100) || fresh)
        }
        var savable: Bool { writable && profileOk }
        var key: String { String(format: "%04X", sector) }

        // Format 7 (PRO X SUPERLIGHT 2, PRO X 2 DEX), written by Featherweight and logitech-onboard-memory and read back; 6 and 8 have
        // the same layout at every byte BuildWide writes, per OMM's builders (docs/newer-mice.md, docs/research/omm).
        static func wideFormat(_ format: Int) -> Bool { format >= 6 && format <= 8 }
        // Format 2 (G502 HERO, G303, G502 Proteus Spectrum) has format 3's layout up to the LED blocks: only these get their LED
        // records written and a profile set up from the factory one.
        static func knownFormat(_ format: Int) -> Bool { format == 2 || format == 3 }
        // Formats 4 (PRO X SUPERLIGHT) and 5 (G502 X PLUS) share format 3's layout up to 0xD0; their LED records are left as read.
        static func classicFormat(_ format: Int) -> Bool { knownFormat(format) || format == 4 || format == 5 }
    }

    static let romSector = 0x0101

    // Formats 2 and 3 (libratbag, Solaar and cvuchener's hidpp agree): the report interval in ms, the default DPI stage, five 2-byte
    // stages (little-endian), 4 bytes per button, the name in UTF-16, then an 11-byte LED record per zone. The CRC is in the last two.
    static let reportIntervalAt = 0x00, defaultStageAt = 0x01, stagesAt = 0x03, stageCount = 5, buttonsAt = 0x20, buttonLength = 4
    static let nameAt = 0xA0, nameLength = 0x30, lightRecordsAt = 0xD0, lightRecordLength = 11

    // Formats 6 to 8: the rate as a 0x8061 index, the receiver's at 0 and the cable's at 1, the default stage at 2, five 5-byte stage
    // records from 4 (X and Y little-endian, lift-off), the buttons from 0x30 (docs/newer-mice.md).
    static let wideRateAt = 0, wideWiredRateAt = 1, wideDefaultStageAt = 2, wideStagesAt = 4, wideStageLength = 5, wideButtonsAt = 0x30
    static let wideRateValues = [125, 250, 500, 1000, 2000, 4000, 8000]

    static func get16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }

    static func crc(_ data: [UInt8], _ length: Int) -> Int {
        var crc = 0xFFFF
        for i in 0..<length {
            crc ^= Int(data[i]) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1 ^ 0x1021) & 0xFFFF : crc << 1 & 0xFFFF }
        }
        return crc
    }

    static func valid(_ profile: [UInt8]?) -> Bool {
        guard let profile = profile, profile.count >= 0xF0 else { return false }
        return crc(profile, profile.count - 2) == get16(profile, profile.count - 2)
    }

    static func writeChecksum(_ profile: inout [UInt8]) {
        let value = crc(profile, profile.count - 2)
        profile[profile.count - 2] = UInt8(value >> 8)
        profile[profile.count - 1] = UInt8(value & 0xFF)
    }

    static func stagesOf(_ profile: [UInt8]) -> [Int] {
        Array((0..<stageCount).map { Int(profile[stagesAt + 2 * $0]) | Int(profile[stagesAt + 1 + 2 * $0]) << 8 }
            .prefix { $0 != 0 && $0 != 0xFFFF })
    }

    static func wideStages(_ profile: [UInt8], _ dpis: [Int]) -> [Int] {
        let stages = Array((0..<stageCount)
            .map { Int(profile[wideStagesAt + wideStageLength * $0]) | Int(profile[wideStagesAt + 1 + wideStageLength * $0]) << 8 }
            .prefix { $0 != 0 && $0 != 0xFFFF })
        guard let low = dpis.first, let high = dpis.last else { return [] }
        return stages.allSatisfy { $0 >= low && $0 <= high } ? stages : []
    }

    static func wideStagesOf(_ profile: [UInt8]) -> [Int] { wideStages(profile, [1, 0xFFFE]) }

    static func buttonsOf(_ profile: [UInt8], _ at: Int, _ count: Int) -> [[UInt8]] {
        (0..<count).map { Array(profile[at + buttonLength * $0..<at + buttonLength * ($0 + 1)]) }
    }

    static func wideRates(_ bits: UInt8) -> [Int] { (0..<7).filter { bits >> $0 & 1 != 0 }.map { 125 << $0 } }

    static func rateList(_ bits: UInt8) -> [Int] { (0..<8).filter { bits >> $0 & 1 != 0 }.map { 1000 / ($0 + 1) }.sorted() }

    // 0x2201 fn 1: a list of DPIs, where E000 | step means every step up to the next value.
    static func dpiList(_ reply: [UInt8]) -> [Int] {
        var dpis: [Int] = []
        var at = 1
        while at + 1 < reply.count {
            let value = get16(reply, at)
            if value == 0 { break }
            if value & 0xE000 == 0xE000 {
                let step = value & 0x1FFF
                if dpis.isEmpty || step == 0 || at + 3 >= reply.count { break }
                let end = get16(reply, at + 2)
                var dpi = dpis[dpis.count - 1] + step
                while dpi < end { dpis.append(dpi); dpi += step }
                at += 2
                continue
            }
            dpis.append(value)
            at += 2
        }
        return dpis
    }

    static func readWideDpi(_ hidpp: Hidpp, _ state: State) throws {
        let feature = try hidpp.featureIndex(0x2202)
        var list: [UInt8] = [0]
        var ended = false
        var page = 0
        while page < 16 && !ended {
            list += try hidpp.call(feature, 2, [0, 0, UInt8(page)]).dropFirst(3).prefix(13)
            var at = 1
            while at + 1 < list.count { if list[at] == 0 && list[at + 1] == 0 { ended = true }; at += 2 }
            page += 1
        }
        state.dpis = dpiList(list)
        if state.dpis.count > 1000 { state.dpis = state.dpis.filter { $0 % 50 == 0 } }
        state.dpi = get16(try hidpp.call(feature, 5, [0]), 1)
    }

    static func describe(_ profile: [UInt8]) -> String {
        if !valid(profile) { return "damaged, can't be restored" }
        let stages = stagesOf(profile)
        let at = lightRecordsAt + lightRecordLength
        let light = decode(Array(profile[at..<at + lightRecordLength]))
        let defaultStage = Int(profile[defaultStageAt]), interval = Int(profile[reportIntervalAt])
        return (defaultStage < stages.count ? "\(stages[defaultStage]) DPI" : "DPI stages")
            + ", " + (light.flatMap { effect($0.effect)?.name } ?? "lighting") + ", " + (interval > 0 ? "\(1000 / interval) Hz" : "")
    }

    static func describeWide(_ profile: [UInt8]) -> String {
        if !valid(profile) { return "damaged, can't be restored" }
        let stages = wideStagesOf(profile), defaultStage = Int(profile[wideDefaultStageAt])
        return defaultStage < stages.count ? "\(stages[defaultStage]) DPI" : "DPI stages"
    }

    static func build(_ old: [UInt8], _ want: MouseSettings, _ zones: Int) throws -> [UInt8] {
        var built = old
        let stages = stagesOf(built)
        if stages.isEmpty { throw GLiteError.refused("The profile on the mouse has no DPI stages, not touching it") }
        var i = want.stage >= 0 && want.stage < stages.count ? want.stage : stages.firstIndex(of: want.dpi) ?? -1
        if i < 0 { i = min(Int(built[defaultStageAt]), stages.count - 1) }
        built[stagesAt + 2 * i] = UInt8(want.dpi & 0xFF)
        built[stagesAt + 1 + 2 * i] = UInt8(want.dpi >> 8 & 0xFF)
        built[defaultStageAt] = UInt8(i)
        if want.rate > 0 && want.rate <= 1000 { built[reportIntervalAt] = UInt8(1000 / want.rate) }
        if let buttons = want.buttons { try copyButtons(&built, buttons, buttonsAt) }
        if let light = want.light {
            for zone in 0..<min(zones, 2) {
                let at = lightRecordsAt + lightRecordLength * zone
                built[at] = light.effect
                built.replaceSubrange(at + 1..<at + 11, with: encode(light))
            }
        }
        writeChecksum(&built)
        return built
    }

    // Formats 6 to 8: only the DPI stages, the default stage, the rate for the link in use and the buttons change.
    static func buildWide(_ old: [UInt8], _ want: MouseSettings, wired: Bool) throws -> [UInt8] {
        var built = old
        let stages = wideStagesOf(built)
        if stages.isEmpty { throw GLiteError.refused("The profile on the mouse has no DPI stages, not touching it") }
        var i = want.stage >= 0 && want.stage < stages.count ? want.stage : stages.firstIndex(of: want.dpi) ?? -1
        if i < 0 { i = min(Int(built[wideDefaultStageAt]), stages.count - 1) }
        // The stage is only rewritten when its DPI changed, and a Y set apart from X (in G HUB) keeps its ratio to X.
        let at = wideStagesAt + wideStageLength * i, x = stages[i], y = Int(built[at + 2]) | Int(built[at + 3]) << 8
        if want.dpi != x {
            let newY = y == x || y == 0 || y == 0xFFFF ? want.dpi : Int((Double(y) * Double(want.dpi) / Double(x)).rounded())
            built[at] = UInt8(want.dpi & 0xFF); built[at + 1] = UInt8(want.dpi >> 8 & 0xFF)
            built[at + 2] = UInt8(newY & 0xFF); built[at + 3] = UInt8(newY >> 8 & 0xFF)
        }
        built[wideDefaultStageAt] = UInt8(i)
        if let rate = wideRateValues.firstIndex(of: want.rate) { built[wired ? wideWiredRateAt : wideRateAt] = UInt8(rate) }
        if let buttons = want.buttons { try copyButtons(&built, buttons, wideButtonsAt) }
        writeChecksum(&built)
        return built
    }

    static func copyButtons(_ built: inout [UInt8], _ buttons: [[UInt8]], _ at: Int) throws {
        let count = min(buttons.count, 16)
        if Bindings.hasLeft(buttonsOf(built, at, count), count) && !Bindings.hasLeft(buttons, count) {
            throw GLiteError.refused("No button is set to Left click, not saving")
        }
        for button in 0..<count { built.replaceSubrange(at + buttonLength * button..<at + buttonLength * (button + 1), with: buttons[button]) }
    }

    // OMM restores a profile by copying a factory one over it, so the factory profiles have the user layout. The SUPERLIGHT 2's reads
    // with no valid CRC, so its rate bytes, stages and default stage tell it's a profile; the checksum is written here.
    static func factory(_ rom: [UInt8], _ current: [UInt8], _ state: State) throws -> [UInt8] {
        let usable: Bool
        if State.wideFormat(state.format) {
            let stages = wideStages(rom, state.dpis).count
            usable = rom[wideRateAt] < wideRateValues.count && rom[wideWiredRateAt] < wideRateValues.count && stages > 0
                && Int(rom[wideDefaultStageAt]) < stages
        } else {
            usable = rom[reportIntervalAt] >= 1 && rom[reportIntervalAt] <= 8 && !stagesOf(rom).isEmpty
        }
        if !usable {
            throw GLiteError.refused("Couldn't read the mouse's factory profile, not restoring it (it starts "
                + Log.hex(Array(rom.prefix(13)), spaced: true) + ")")
        }
        var built = rom
        if valid(current) { built.replaceSubrange(nameAt..<nameAt + nameLength, with: current[nameAt..<nameAt + nameLength]) }
        writeChecksum(&built)
        return built
    }

    static func memory(_ hidpp: Hidpp, _ feature: UInt8, _ sector: Int, _ offset: Int) throws -> [UInt8] {
        try hidpp.call(feature, 5, [UInt8(sector >> 8 & 0xFF), UInt8(sector & 0xFF), UInt8(offset >> 8 & 0xFF), UInt8(offset & 0xFF)])
    }

    static func readSector(_ hidpp: Hidpp, _ sector: Int, _ size: Int) throws -> [UInt8] {
        let feature = try hidpp.featureIndex(0x8100)
        var data = [UInt8](repeating: 0, count: size)
        for offset in stride(from: 0, to: size, by: 16) {
            let at = min(offset, size - 16)
            let chunk = try memory(hidpp, feature, sector, at)
            for i in 0..<min(16, size - offset) { data[offset + i] = chunk[offset - at + i] }
        }
        return data
    }

    static func writeSector(_ hidpp: Hidpp, _ sector: Int, _ profile: [UInt8]) throws {
        if sector <= 0 || sector >= 0x100 { throw GLiteError.refused("Refusing to write that part of the mouse's memory") }
        if !valid(profile) { throw GLiteError.refused("Refusing to write a profile with a bad checksum") }
        try write(hidpp, sector, profile)
    }

    private static func write(_ hidpp: Hidpp, _ sector: Int, _ profile: [UInt8]) throws {
        let feature = try hidpp.featureIndex(0x8100)
        try hidpp.call(feature, 6, [UInt8(sector >> 8 & 0xFF), UInt8(sector & 0xFF), 0, 0, UInt8(profile.count >> 8), UInt8(profile.count & 0xFF)])
        for i in stride(from: 0, to: profile.count, by: 16) {
            var chunk = [UInt8](repeating: 0, count: 16)
            for j in 0..<min(16, profile.count - i) { chunk[j] = profile[i + j] }
            try hidpp.call(feature, 7, chunk)
        }
        try hidpp.call(feature, 8)
        if try readSector(hidpp, sector, profile.count) != profile {
            throw GLiteError.io("The profile on the mouse didn't read back the same after saving")
        }
    }

    // An empty directory, or a sector never written: all 00 on a G502 HERO (Solaar #2313), all FF on a G502 X LIGHTSPEED (omalogi).
    static func unwritten(_ directory: [UInt8]) -> Bool {
        (valid(directory) && get16(directory, 0) == 0xFFFF) || directory.allSatisfy { $0 == 0 } || directory.allSatisfy { $0 == 0xFF }
    }

    static func directory(_ size: Int, _ profiles: Int) throws -> [UInt8] {
        if profiles < 1 || profiles > 8 || size < 0xF0 { throw GLiteError.refused("Refusing to build that profile directory") }
        var directory = [UInt8](repeating: 0xFF, count: size)
        for i in 0..<profiles { directory.replaceSubrange(4 * i..<4 * i + 4, with: [0, UInt8(i + 1), i == 0 ? 1 : 0, 0]) }
        directory[4 * profiles + 2] = 0
        directory[4 * profiles + 3] = 0
        writeChecksum(&directory)
        return directory
    }

    // The first save on a mouse that only runs its factory profile: the profile to 0x0001, then the directory, then load 0x0001
    // (libratbag's hidpp20_onboard_profiles_write_dict layout).
    static func setup(_ hidpp: Hidpp, _ state: State, _ profile: [UInt8]) throws {
        if !state.fresh || !State.knownFormat(state.format) || profile.count != state.sectorSize {
            throw GLiteError.refused("Saving isn't supported on this mouse")
        }
        try writeSector(hidpp, 1, profile)
        try write(hidpp, 0x0000, try directory(state.sectorSize, 1))
        do { try hidpp.call(try hidpp.featureIndex(0x8100), 3, [0x00, 0x01]) } catch GLiteError.hidpp {}
        if let label = hidpp.deviceLabel {
            Log.add(label, "sent", "Onboard memory set up: the profile at 0001, built from the factory profile at "
                    + String(format: "%04X", state.sector) + ", and the directory at 0000", "ok")
        }
    }

    static func store(_ hidpp: Hidpp, _ state: State, _ profile: [UInt8]) throws {
        if !state.writable || state.fresh || profile.count != state.sectorSize {
            throw GLiteError.refused("Saving isn't supported on this mouse")
        }
        try writeSector(hidpp, state.sector, profile)
        do { try hidpp.call(try hidpp.featureIndex(0x8100), 3, state.current ?? []) } catch GLiteError.hidpp {}
    }

    static func encode(_ light: MouseLight) -> [UInt8] {
        var parameters = [UInt8](repeating: 0, count: 10)
        var color = light.color
        let brightness = max(1, min(100, light.bright))
        if light.effect == 0x01 {
            color = ((color >> 16 & 0xFF) * brightness / 100) << 16 | ((color >> 8 & 0xFF) * brightness / 100) << 8
                | (color & 0xFF) * brightness / 100
        }
        let rgb = [UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)]
        switch light.effect {
        case 0x01: parameters.replaceSubrange(0..<3, with: rgb)
        case 0x0A:
            parameters.replaceSubrange(0..<3, with: rgb)
            parameters[3] = UInt8(light.period >> 8 & 0xFF); parameters[4] = UInt8(light.period & 0xFF); parameters[6] = UInt8(brightness)
        case 0x03:
            parameters[5] = UInt8(light.period >> 8 & 0xFF); parameters[6] = UInt8(light.period & 0xFF); parameters[7] = UInt8(brightness)
        default: break
        }
        return parameters
    }

    static func decode(_ record: [UInt8]) -> MouseLight? {
        guard let info = effect(record[0]) else { return nil }
        var light = MouseLight(effect: record[0])
        switch record[0] {
        case 0x01:
            let top = Int(max(record[1], record[2], record[3]))
            if top == 0 { light.bright = 100; break }
            light.color = (Int(record[1]) * 255 / top) << 16 | (Int(record[2]) * 255 / top) << 8 | Int(record[3]) * 255 / top
            light.bright = max(1, (top * 100 + 127) / 255)
        case 0x0A:
            light.color = Int(record[1]) << 16 | Int(record[2]) << 8 | Int(record[3])
            light.period = get16(record, 4)
            light.bright = record[7] == 0 ? 100 : Int(record[7])
        case 0x03:
            light.period = get16(record, 6)
            light.bright = record[8] == 0 ? 100 : Int(record[8])
        default: break
        }
        if info.speed { light.period = max(info.minPeriod, min(info.maxPeriod, light.period)) }
        light.bright = min(100, light.bright)
        return light
    }

    static func read(_ hidpp: Hidpp) throws -> State {
        let state = State()
        state.wired = hidpp.direct
        do {
            let dpiFeature = try hidpp.featureIndex(0x2201)
            state.dpis = dpiList(try hidpp.call(dpiFeature, 1, [0]))
            state.dpi = get16(try hidpp.call(dpiFeature, 2, [0]), 1)
        } catch GLiteError.notSupported { try readWideDpi(hidpp, state) }
        do {
            let rateFeature = try hidpp.featureIndex(0x8060)
            state.rates = rateList(try hidpp.call(rateFeature, 0)[0])
            let interval = Int(try hidpp.call(rateFeature, 1)[0])
            state.rate = interval > 0 ? 1000 / interval : 0
        } catch GLiteError.notSupported {
            do {
                let rateFeature = try hidpp.featureIndex(0x8061)
                state.rates = wideRates(try hidpp.call(rateFeature, 1)[1])
                let index = Int(try hidpp.call(rateFeature, 2, [hidpp.direct ? 0 : 1])[0])
                state.rate = index < 7 ? 125 << index : 0
            } catch GLiteError.notSupported {} catch GLiteError.hidpp {}
        } catch GLiteError.hidpp {}
        var logo = -1
        do {
            let lightFeature = try hidpp.featureIndex(0x8070)
            // The original PRO X SUPERLIGHT flags 0x8070 internal and hidden: its status light, which refuses fn 1 with error 5.
            let zones = hidpp.hidden(0x8070) ? 0 : Int(try hidpp.call(lightFeature, 0)[0])
            for zone in 0..<zones {
                let info = try hidpp.call(lightFeature, 1, [UInt8(zone), 0xFF, 0])
                if get16(info, 1) == 2 { logo = zone }
                var map: [UInt8: Int] = [:]
                for effectIndex in 0..<Int(info[3]) {
                    let id = get16(try hidpp.call(lightFeature, 2, [UInt8(zone), UInt8(effectIndex), 0xFF, 0]), 2)
                    if id <= 0xFF { map[UInt8(id)] = effectIndex }
                }
                state.zones[zone] = map
            }
        } catch GLiteError.notSupported {} catch GLiteError.hidpp { state.zones.removeAll() }
        if logo < 0 { logo = state.zones.count - 1 }
        do {
            let wheelFeature = try hidpp.featureIndex(0x2121)
            state.canInvert = try hidpp.call(wheelFeature, 0)[1] & 0x08 != 0
            state.inverted = try hidpp.call(wheelFeature, 1)[0] & 0x04 != 0
        } catch GLiteError.notSupported {} catch GLiteError.hidpp { state.canInvert = false }
        do {
            let profilesFeature = try hidpp.featureIndex(0x8100)
            state.profilesFeature = profilesFeature
            state.onboard = try hidpp.call(profilesFeature, 2)[0] == 1
            if state.onboard {
                let info = try hidpp.call(profilesFeature, 0)
                state.profileOk = false
                state.buttonCount = min(16, Int(info[5]))
                state.format = Int(info[1])
                state.factoryProfiles = Int(info[4])
                // Formats 2 to 5 keep the rate as an interval in ms, so a faster rate couldn't be saved.
                if State.classicFormat(state.format) { state.rates = state.rates.filter { $0 <= 1000 } }
                state.sectorSize = get16(info, 7)
                let current = try hidpp.call(profilesFeature, 4)
                state.current = [current[0], current[1]]
                state.sector = get16(current, 0)
                if state.sectorSize >= 0xF0 && state.sectorSize <= 0x1000 {
                    let profile = try readSector(hidpp, state.sector, state.sectorSize)
                    state.profile = profile
                    state.profileOk = valid(profile) || state.sector >= 0x100
                    if state.format >= 6 {
                        let wide = State.wideFormat(state.format)
                        // Their buttons take 48 bytes from 0x30, then reserved bytes up to the G-shift layer at 0x70 (OMM's builders).
                        if wide { state.buttonCount = min(12, state.buttonCount) }
                        // Format 10 has format 1's layout with other fields: read at these offsets its stages can come out wrong but in
                        // range, so formats past 8 show none.
                        if state.profileOk && wide {
                            state.stages = wideStages(profile, state.dpis)
                            state.buttons = buttonsOf(profile, wideButtonsAt, state.buttonCount)
                        }
                        state.profile = nil
                        if !wide { state.profileOk = true }
                    } else {
                        state.stages = stagesOf(profile)
                        state.buttons = buttonsOf(profile, buttonsAt, state.buttonCount)
                        if logo >= 0 && logo < 2 {
                            let at = lightRecordsAt + lightRecordLength * logo
                            state.light = decode(Array(profile[at..<at + lightRecordLength]))
                        }
                    }
                }
                if state.sector >= 0x100 && State.knownFormat(state.format) && info[3] >= 1
                    && state.sectorSize >= 0xF0 && state.sectorSize <= 0x1000 {
                    do { state.fresh = unwritten(try readSector(hidpp, 0x0000, state.sectorSize)) } catch let error as GLiteError {
                        state.fresh = error.code == 2
                    }
                }
                state.stage = Int(try hidpp.call(profilesFeature, 0xB)[0])
                if state.stage >= state.stages.count { state.stage = -1 }
            }
        } catch GLiteError.notSupported {} catch GLiteError.hidpp {}
        return state
    }

    // After the mouse's own DPI button, which 0x8100 reports as event fn 1 (MyHUB, docs/research/more-references.md).
    static func readDpiAndStage(_ hidpp: Hidpp, _ state: State) throws -> (Int, Int) {
        let now = State()
        do { now.dpi = get16(try hidpp.call(try hidpp.featureIndex(0x2201), 2, [0]), 1) } catch GLiteError.notSupported {
            try readWideDpi(hidpp, now)
        }
        var stage = Int(try hidpp.call(state.profilesFeature, 0xB)[0])
        if stage >= state.stages.count { stage = -1 }
        return (now.dpi, stage)
    }

    static func setDpi(_ hidpp: Hidpp, _ dpi: Int) throws {
        let high = UInt8(dpi >> 8 & 0xFF), low = UInt8(dpi & 0xFF)
        do { try hidpp.call(try hidpp.featureIndex(0x2201), 3, [0, high, low]); return } catch GLiteError.notSupported {}
        let feature = try hidpp.featureIndex(0x2202)
        let both = try hidpp.call(feature, 1, [0])[2] & 1 != 0
        let lift = try hidpp.call(feature, 5, [0])[9]
        do { try hidpp.call(feature, 6, [0, high, low, both ? high : 0, both ? low : 0, lift]) } catch GLiteError.hidpp {
            throw GLiteError.refused("The mouse refused this DPI. It may only take its saved DPI stages.")
        }
    }

    // Only bit 2 changes; never bit 0, which diverts the wheel to software (CLAUDE.md).
    static func setInvert(_ hidpp: Hidpp, _ on: Bool) throws {
        let feature = try hidpp.featureIndex(0x2121)
        let mode = try hidpp.call(feature, 1)
        if (mode[0] & 0x04 != 0) == on { return }
        try hidpp.call(feature, 2, [on ? mode[0] | 0x04 : mode[0] & ~0x04, mode[1], mode[2]])
    }

    static func setStage(_ hidpp: Hidpp, _ stage: Int) throws { try hidpp.call(try hidpp.featureIndex(0x8100), 0xC, [UInt8(stage)]) }

    static func setRate(_ hidpp: Hidpp, _ hz: Int) throws {
        do { try hidpp.call(try hidpp.featureIndex(0x8060), 2, [UInt8(1000 / hz)]); return } catch GLiteError.notSupported {}
        guard let index = wideRateValues.firstIndex(of: hz) else { throw GLiteError.refused("This mouse has no \(hz) Hz rate") }
        try hidpp.call(try hidpp.featureIndex(0x8061), 3, [UInt8(index)])
    }

    static func setLight(_ hidpp: Hidpp, _ state: State, _ light: MouseLight) throws {
        let feature = try hidpp.featureIndex(0x8070)
        for (zone, map) in state.zones.sorted(by: { $0.key < $1.key }) {
            guard let effectIndex = map[light.effect] else { continue }
            try hidpp.call(feature, 3, [UInt8(zone), UInt8(effectIndex)] + encode(light))
        }
    }
}

// The HID++ 2.0 mouse driver (app/Mouse.cs, HidppMouse): what the mouse screen calls, deciding by profile format.
final class HidppMouse: MouseDriver {
    var effects: [EffectInfo] { MouseProtocol.effects }
    func setLight(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ light: MouseLight) throws { try MouseProtocol.setLight(hidpp, state, light) }
    func setRate(_ hidpp: Hidpp, _ hz: Int) throws { try MouseProtocol.setRate(hidpp, hz) }
    func setInvert(_ hidpp: Hidpp, _ on: Bool) throws { try MouseProtocol.setInvert(hidpp, on) }

    private var format = 0, factoryProfiles = -1
    private var wide: Bool { MouseProtocol.State.wideFormat(format) }

    var hasFactory: Bool { factoryProfiles != 0 }

    func read(_ hidpp: Hidpp) throws -> MouseProtocol.State {
        let state = try MouseProtocol.read(hidpp)
        format = state.format
        factoryProfiles = state.factoryProfiles
        return state
    }

    // A format 7 mouse refuses a DPI that isn't one of its stages while it runs its profile (logi-cli, OpenGMice), and 6 and 8 are
    // taken to do the same: an edited stage goes on the mouse when saved, so only the stage is picked.
    func sendDpi(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings, _ sent: MouseSettings?) throws {
        if let sent = sent, want.dpi == sent.dpi && want.stage == sent.stage { return }
        let staged = state.onboard && want.stage >= 0 && want.stage < state.stages.count
        let saved = staged && state.stages[want.stage] == want.dpi
        if saved { try MouseProtocol.setStage(hidpp, want.stage) }
        else if wide && state.savable {
            if staged && sent?.stage != want.stage { try MouseProtocol.setStage(hidpp, want.stage) }
        } else { try MouseProtocol.setDpi(hidpp, want.dpi) }
    }

    func readProfile(_ hidpp: Hidpp, _ state: MouseProtocol.State) throws -> [UInt8] {
        try MouseProtocol.readSector(hidpp, state.sector, state.sectorSize)
    }

    // The LED records of formats 4 and 5 aren't checked, so they're kept: a zone count of 0 leaves them.
    private func build(_ now: [UInt8], _ want: MouseSettings, _ state: MouseProtocol.State) throws -> [UInt8] {
        if wide { return try MouseProtocol.buildWide(now, want, wired: state.wired) }
        return try MouseProtocol.build(now, want, MouseProtocol.State.knownFormat(format) ? state.zones.count : 0)
    }

    func setup(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings) throws {
        try MouseProtocol.setup(hidpp, state,
                                try MouseProtocol.build(try MouseProtocol.readSector(hidpp, state.sector, state.sectorSize), want, state.zones.count))
    }

    func save(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ want: MouseSettings) throws {
        try MouseProtocol.store(hidpp, state, try build(now, want, state))
    }

    // Reloading the active profile (fn 3) leaves a G305's DPI as it was set live, so the restored default stage is set too. Live
    // changes the restored profile doesn't hold stay too: leaving onboard mode and coming back drops them (fn 1 `02` then `01`, tried
    // by PeriHub on a G502 HERO), done only when the mouse runs its onboard profiles.
    func restore(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ data: [UInt8]?) throws {
        let restored = try data ?? MouseProtocol.factory(try MouseProtocol.readSector(hidpp, MouseProtocol.romSector, state.sectorSize),
                                                         now, state)
        try MouseProtocol.store(hidpp, state, restored)
        if state.onboard {
            let profiles = try hidpp.featureIndex(0x8100)
            var left = false
            do { try hidpp.call(profiles, 1, [0x02]); left = true } catch GLiteError.hidpp {}
            // Tried twice and not swallowed: a mouse left out of onboard mode would ignore its profiles.
            if left { do { try hidpp.call(profiles, 1, [0x01]) } catch GLiteError.hidpp { try hidpp.call(profiles, 1, [0x01]) } }
        }
        let stage = defaultStage(restored)
        if stage < (wide ? MouseProtocol.wideStagesOf(restored) : MouseProtocol.stagesOf(restored)).count {
            do { try MouseProtocol.setStage(hidpp, stage) } catch GLiteError.hidpp {}
        }
    }

    func describe(_ profile: [UInt8]) -> String { wide ? MouseProtocol.describeWide(profile) : MouseProtocol.describe(profile) }
    func defaultStage(_ profile: [UInt8]) -> Int { Int(profile[wide ? MouseProtocol.wideDefaultStageAt : MouseProtocol.defaultStageAt]) }
}
