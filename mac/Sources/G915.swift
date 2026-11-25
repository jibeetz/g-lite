import Foundation

// Live lighting on the 0x8071 keyboards other than the G515 (the G915, G915 TKL, G815, G512 X 75 and other RGB keyboards), and the
// onboard profile of the G915 family, format 4 (app/KeyboardLighting.cs, G915Lighting; docs/G815-G915.md).
enum G915Lighting {
    // The G515's effect ids and the older ones that do the same (0x03 Cycle, 0x04 Wave, 0x0B Ripple).
    static let alike: [UInt8: [UInt8]] = [0x00: [0x00], 0x01: [0x01], 0x0A: [0x0A], 0x15: [0x15, 0x03], 0x16: [0x16, 0x04], 0x17: [0x17, 0x0B]]
    // On a cluster without the effect (the logo), a close one.
    static let instead: [UInt8: UInt8] = [0x16: 0x15, 0x17: 0x01]

    // verticalWave: a Wave (0x0016) lists a vertical direction among its capabilities (bytes 4-5): 0x0040 vertical (direction 2, Down)
    // or 0x0800 reverse vertical (7, Up), per Logitech's x8071 spec as PeriHub reads it.
    static func clusters(_ hidpp: Hidpp) throws -> (clusters: [[UInt8]], verticalWave: Bool) {
        let feature = try hidpp.featureIndex(0x8071)
        var all: [[UInt8]] = []
        var vertical = false
        for cluster in 0..<8 {
            var ids: [UInt8] = []
            for effectIndex in 0..<32 {
                let info: [UInt8]
                do { info = try hidpp.call(feature, 0, [UInt8(cluster), UInt8(effectIndex), 0]) } catch GLiteError.hidpp { break }
                ids.append(info[3])
                if info[2] == 0 && info[3] == 0x16 && (Int(info[4]) << 8 | Int(info[5])) & 0x0840 != 0 { vertical = true }
            }
            if ids.isEmpty { break }
            all.append(ids)
        }
        if all.isEmpty { throw GLiteError.notSupported("The keyboard lists no lighting effects") }
        return (all, vertical)
    }

    // The keys are the cluster with the most effects.
    static func keys(_ clusters: [[UInt8]]) -> Int {
        var largest = 0
        for cluster in 1..<max(1, clusters.count) where clusters[cluster].count > clusters[largest].count { largest = cluster }
        return largest
    }

    static func pick(_ want: UInt8, _ has: [UInt8], loose: Bool) -> Int {
        var wanted = want
        while true {
            for id in alike[wanted] ?? [] { if let index = has.firstIndex(of: id) { return index } }
            guard loose, let next = instead[wanted] else { return -1 }
            wanted = next
        }
    }

    static func encode(_ id: UInt8, _ lighting: Lighting) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 10)
        // 0 shows as 100 on the G815, so the slider's 0 is sent as 1.
        let color = lighting.color, intensity = UInt8(max(1, min(100, lighting.intensity))), period = lighting.period
        let rgb = [UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)]
        switch id {
        case 0x03:
            p[5] = UInt8(period >> 8 & 0xFF); p[6] = UInt8(period & 0xFF); p[7] = intensity
        case 0x04:
            p[6] = UInt8(period & 0xFF); p[7] = UInt8(lighting.direction & 0xFF); p[8] = intensity; p[9] = UInt8(period >> 8 & 0xFF)
        case 0x0A:
            p.replaceSubrange(0..<3, with: rgb); p[3] = UInt8(period >> 8 & 0xFF); p[4] = UInt8(period & 0xFF); p[6] = intensity
        case 0x0B:
            p.replaceSubrange(0..<3, with: rgb); p[4] = UInt8(period >> 8 & 0xFF); p[5] = UInt8(period & 0xFF)
        default:
            var copy = lighting
            copy.effect = id
            return G515Profile.encode(copy, 100)
        }
        return p
    }

    // The G915 TKL turns itself off after its timeout even while G-Lite holds the power modes, and wakes in mode 3 (off) on its own
    // lighting, ignoring effects until fn 8 sets full power again (tested on an owner's keyboard).
    static func claim(_ hidpp: Hidpp) throws {
        let feature = try hidpp.featureIndex(0x8071)
        try hidpp.call(feature, 5, [0x01, 0x03, 0x04])
        do { try hidpp.call(feature, 8, [0x01, 0x01, 0x00]) } catch GLiteError.hidpp {}
    }

    static func release(_ hidpp: Hidpp) throws { try hidpp.call(try hidpp.featureIndex(0x8071), 5, [0x01, 0x00, 0x00]) }

    // Format 4, from a G915 TKL's report: power save and off after (seconds, little-endian), then four 11-byte lighting records: one
    // per cluster, then the same dimmed for power save. The CRC is in the last two bytes, as on the mice.
    static let powerSaveAt = 0x1C, offAt = 0x1E, idleTimesLength = 4, recordsAt = 0xD0, recordLength = 11
    static let recordsLength = 4 * recordLength

    // The enabled profiles' sectors, from the directory (sector 0000: `00 <sector> <enabled> FF` each, then FF FF), and the one
    // running (fn 4). Sector N is the key MN (docs/on-board-memory.md). No slots when the keyboard isn't in onboard mode.
    static func slots(_ hidpp: Hidpp) throws -> (slots: [Int], running: Int, onboard: Bool) {
        let feature = try hidpp.featureIndex(0x8100)
        if try hidpp.call(feature, 2)[0] != 1 { return ([], 0, false) }
        let current = try hidpp.call(feature, 4)
        let running = Int(current[0]) << 8 | Int(current[1])
        var slots: [Int] = []
        for offset in stride(from: 0, to: 64, by: 16) {
            let chunk = try hidpp.call(feature, 5, [0, 0, 0, UInt8(offset)])
            for at in stride(from: 0, to: 16, by: 4) {
                if chunk[at] == 0xFF { return (slots, running, true) }
                let sector = Int(chunk[at]) << 8 | Int(chunk[at + 1])
                if chunk[at + 2] != 0 && sector > 0 && sector < 0x100 { slots.append(sector) }
            }
        }
        return (slots, running, true)
    }

    // buttons: the profile's button slots, from 0x8100 fn 0 byte 5 (8 on the G815: G1-G5 and M1-M3; 15 on the G915 TKL).
    static func readProfile(_ hidpp: Hidpp) throws -> (profile: [UInt8], sector: Int, buttons: Int) {
        let feature = try hidpp.featureIndex(0x8100)
        if try hidpp.call(feature, 2)[0] != 1 { throw GLiteError.refused("The keyboard isn't on its onboard profiles") }
        let info = try hidpp.call(feature, 0)
        let size = Int(info[7]) << 8 | Int(info[8])
        if info[1] != 4 || size < recordsAt + recordsLength + 2 || size > 0x1000 {
            throw GLiteError.refused("Saving isn't supported on this keyboard (profile format \(info[1]))")
        }
        let current = try hidpp.call(feature, 4)
        let sector = Int(current[0]) << 8 | Int(current[1])
        if sector == 0 || sector >= 0x100 { throw GLiteError.refused("The keyboard runs a factory profile") }
        let profile = try MouseProtocol.readSector(hidpp, sector, size)
        if !MouseProtocol.valid(profile) { throw GLiteError.refused("The keyboard's profile has a bad checksum") }
        return (profile, sector, Int(info[5]))
    }

    // The G keys are the profile's first buttons, 4 bytes each from 0x20, in the mice's format (Bindings); M1-M3 follow them
    // (docs/G815-G915.md).
    static let buttonsAt = 0x20

    static func readButtons(_ profile: [UInt8], _ count: Int) -> [[UInt8]] {
        (0..<count).map { Array(profile[buttonsAt + 4 * $0..<buttonsAt + 4 * $0 + 4]) }
    }

    // Only the buttons that differ from were (nil: all), so a change made elsewhere since the read, to another key, stays.
    static func withButtons(_ profile: [UInt8], _ buttons: [[UInt8]], _ were: [[UInt8]]? = nil) -> [UInt8] {
        var built = profile
        for (i, binding) in buttons.enumerated() where were == nil || i >= were!.count || binding != were![i] {
            built.replaceSubrange(buttonsAt + 4 * i..<buttonsAt + 4 * i + 4, with: binding)
        }
        MouseProtocol.writeChecksum(&built)
        return built
    }

    // The profile with its first count buttons (the G keys) as its factory copy has them; the rest stays.
    static func factoryButtons(_ hidpp: Hidpp, _ sector: Int, _ profile: [UInt8], _ count: Int) throws -> [UInt8] {
        let rom = try MouseProtocol.readSector(hidpp, 0x100 + sector, profile.count)
        let buttons = readButtons(rom, count)
        if buttons.contains(where: { $0.allSatisfy { $0 == 0xFF } }) { throw GLiteError.refused("Couldn't read the keyboard's factory G keys") }
        return withButtons(profile, buttons)
    }

    static func level(_ record: [UInt8]) -> Int {
        switch record[0] {
        case 0x03: return Int(record[8])
        case 0x04: return Int(record[9])
        case 0x0A: return Int(record[7])
        default: return Int(max(record[1], record[2], record[3]))
        }
    }

    // nil when the keys hold an effect G-Lite doesn't know. The intensity is read only when the screen shows it (else G-Lite sends
    // 100); G HUB saves 0, which shows as 100.
    static func decode(_ profile: [UInt8], _ keys: Int, intensity: Bool = false) -> Lighting? {
        let at = recordsAt + recordLength * keys
        let record = Array(profile[at..<at + recordLength])
        var lighting = Lighting()
        lighting.idle = Int(profile[powerSaveAt]) | Int(profile[powerSaveAt + 1]) << 8
        lighting.sleep = Int(profile[offAt]) | Int(profile[offAt + 1]) << 8
        lighting.color = Int(record[1]) << 16 | Int(record[2]) << 8 | Int(record[3])
        switch record[0] {
        case 0x00: lighting.effect = 0x00
        case 0x01: lighting.effect = 0x01
        case 0x0A: lighting.effect = 0x0A; lighting.period = Int(record[4]) << 8 | Int(record[5])
        case 0x03: lighting.effect = 0x15; lighting.period = Int(record[6]) << 8 | Int(record[7])
        case 0x04: lighting.effect = 0x16; lighting.period = Int(record[10]) << 8 | Int(record[7]); lighting.direction = Int(record[8])
        case 0x0B: lighting.effect = 0x17; lighting.period = Int(record[5]) << 8 | Int(record[6])
        default: return nil
        }
        if lighting.effect != 0x01 && lighting.effect != 0x0A && lighting.effect != 0x17 { lighting.color = 0xFFFFFF }
        let hasIntensity = record[0] == 0x03 || record[0] == 0x04 || record[0] == 0x0A
        if intensity && hasIntensity && level(record) > 0 { lighting.intensity = min(100, level(record)) }
        let dimAt = recordsAt + recordLength * (2 + keys)
        let dim = Array(profile[dimAt..<dimAt + recordLength])
        lighting.dim = dim[0] == record[0] && level(record) > 0 ? min(100, level(dim) * 100 / level(record)) : 50
        return lighting
    }

    // The dimmed records keep the colour and lower the intensity, as the keyboard's own profiles do; Static and Ripple have no
    // intensity, so their colour is scaled.
    static func dimmed(_ id: UInt8, _ parameters: [UInt8], _ percent: Int) -> [UInt8] {
        var p = parameters
        func lower(_ at: Int) { p[at] = UInt8(max(1, Int(p[at]) * percent / 100)) }
        switch id {
        case 0x03: lower(7)
        case 0x04: lower(8)
        case 0x0A: lower(6)
        default: for i in 0..<3 { p[i] = UInt8(Int(p[i]) * percent / 100) }
        }
        return p
    }

    static func build(_ profile: [UInt8], _ clusters: [[UInt8]], _ lighting: Lighting, _ others: Lighting?, idleTimes: Bool) throws -> [UInt8] {
        if clusters.count != 2 {
            throw GLiteError.refused("Saving isn't supported on this keyboard (\(clusters.count) lighting clusters)")
        }
        if idleTimes && (lighting.idle <= 0 || lighting.sleep <= 0) {
            throw GLiteError.refused("This keyboard can't keep its lighting on forever: 0 dims and turns it off at once")
        }
        var built = profile
        let keysCluster = keys(clusters)
        for cluster in 0..<2 {
            let light = cluster == keysCluster || others == nil ? lighting : others!
            let effectIndex = pick(light.effect, clusters[cluster], loose: cluster != keysCluster)
            if effectIndex < 0 { throw GLiteError.refused("This keyboard doesn't have that effect") }
            let id = clusters[cluster][effectIndex]
            let parameters = encode(id, light)
            let recordAt = recordsAt + recordLength * cluster, dimAt = recordsAt + recordLength * (2 + cluster)
            built[recordAt] = id
            built.replaceSubrange(recordAt + 1..<recordAt + 11, with: parameters)
            built[dimAt] = id
            built.replaceSubrange(dimAt + 1..<dimAt + 11, with: dimmed(id, parameters, idleTimes ? lighting.dim : 100))
        }
        if idleTimes {
            built[powerSaveAt] = UInt8(lighting.idle & 0xFF); built[powerSaveAt + 1] = UInt8(lighting.idle >> 8 & 0xFF)
            built[offAt] = UInt8(lighting.sleep & 0xFF); built[offAt + 1] = UInt8(lighting.sleep >> 8 & 0xFF)
        }
        MouseProtocol.writeChecksum(&built)
        return built
    }

    // The lighting and idle times of the factory copy of the profile at sector (0101 for 0001 on the G915 TKL), into a copy of
    // profile. Only those: a whole factory profile would drop what else the user changed, like G-shift macros.
    static func factoryLighting(_ hidpp: Hidpp, _ sector: Int, _ profile: [UInt8]) throws -> [UInt8] {
        let rom = try MouseProtocol.readSector(hidpp, 0x100 + sector, profile.count)
        if rom[recordsAt..<recordsAt + recordsLength].allSatisfy({ $0 == 0xFF }) || rom[powerSaveAt] == 0xFF {
            throw GLiteError.refused("Couldn't read the keyboard's factory lighting")
        }
        var built = profile
        built.replaceSubrange(powerSaveAt..<powerSaveAt + idleTimesLength, with: rom[powerSaveAt..<powerSaveAt + idleTimesLength])
        built.replaceSubrange(recordsAt..<recordsAt + recordsLength, with: rom[recordsAt..<recordsAt + recordsLength])
        MouseProtocol.writeChecksum(&built)
        return built
    }

    // Writes the profile (writeSector refuses 0000 and the factory sectors, and reads it back), loads it again and gives the lighting
    // back, so the keyboard runs it. The G815 acks fn 3 but keeps running its old copy until it leaves onboard mode and comes back
    // (fn 1 02, then 01), tried on an owner's G815.
    static func store(_ hidpp: Hidpp, _ sector: Int, _ profile: [UInt8], reloadThroughHostMode: Bool = false) throws {
        try MouseProtocol.writeSector(hidpp, sector, profile)
        let feature = try hidpp.featureIndex(0x8100)
        do { try hidpp.call(feature, 3, [UInt8(sector >> 8 & 0xFF), UInt8(sector & 0xFF)]) } catch GLiteError.hidpp {}
        try release(hidpp)
        if !reloadThroughHostMode { return }
        defer { _ = try? hidpp.call(feature, 1, [0x01]) }
        try hidpp.call(feature, 1, [0x02])
    }

    static func preview(_ hidpp: Hidpp, _ clusters: [[UInt8]], _ lighting: Lighting, _ others: Lighting? = nil) throws {
        let feature = try hidpp.featureIndex(0x8071)
        let keysCluster = keys(clusters)
        if pick(lighting.effect, clusters[keysCluster], loose: false) < 0 {
            throw GLiteError.refused("This keyboard doesn't have that effect")
        }
        for cluster in 0..<clusters.count {
            let light = cluster == keysCluster || others == nil ? lighting : others!
            let effectIndex = pick(light.effect, clusters[cluster], loose: cluster != keysCluster)
            if effectIndex < 0 { continue }
            try hidpp.call(feature, 1, [UInt8(cluster), UInt8(effectIndex)] + encode(clusters[cluster][effectIndex], light) + [0x01])
        }
    }
}

// What differs between the keyboards that use live lighting (app/KeyboardKinds.cs), given by their entry.
struct KeyboardKind {
    // Saves into the onboard profile (format 4): the G915 family.
    var profile = false
    // The G815 is wired: its profiles hold 0 for both idle times, and G HUB writes the power-save records as copies of the others.
    var noIdleTimes = false
    // The G815 runs a profile written again only after leaving onboard mode and coming back.
    var reloadThroughHostMode = false
    // The brightness levels 0x8040 keeps; any other value drops to the one below (the G815, tried on an owner's keyboard). Nil for any.
    var brightnessLevels: [Int]?
    // An Intensity slider for the effects that have one (0x8071's intensity byte).
    var intensity = false
    // The G keys, the profile's first buttons. The G915 TKL's (F1-F12) come from one report and the G915's are inferred from the
    // G815's, so they're experimental and read only when fn 0 counts them and M1-M3 (app/KeyboardKinds.cs).
    var gKeys: [String]?
    var gKeysExperimental = false
    // The Game view (app/KeyboardKinds.cs, GameMode): tried on the G815; the G915s, the G915 X and the G512 X 75 aren't.
    var gameMode = false
    var gameModeExperimental = true
    // The G512 X 75's light bar, ids A0-C0 (app/KeyboardKinds.cs, Bar): a lighting of its own with Per zone.
    var bar = Set<Int>()

    static func of(_ device: FoundDevice) -> KeyboardKind {
        let upper = device.name.uppercased()
        if device.isG915 && upper.contains("G815") {
            return KeyboardKind(profile: true, noIdleTimes: true, reloadThroughHostMode: true, brightnessLevels: [0, 12, 25, 50, 100], intensity: true,
                                gKeys: (1...5).map { "G\($0)" }, gameMode: true, gameModeExperimental: false)
        }
        if device.isG915 && upper.contains("TKL") {
            return KeyboardKind(profile: true, gKeys: (1...12).map { "F\($0)" }, gKeysExperimental: true, gameMode: true)
        }
        if device.isG915 { return KeyboardKind(profile: true, gKeys: (1...5).map { "G\($0)" }, gKeysExperimental: true, gameMode: true) }
        return KeyboardKind(gameMode: upper.contains("G915 X") || upper.contains("G512 X"), bar: upper.contains("G512 X 75") ? Set(0xA0...0xC0) : [])
    }
}
