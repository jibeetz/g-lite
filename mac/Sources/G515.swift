import Foundation

struct EffectInfo {
    let id: UInt8
    let name: String
    var color = false, speed = false, direction = false, intensity = false
    var minPeriod = 0, maxPeriod = 0, defaultPeriod = 0
}

// The lighting settings, written as text the same way as on Windows (app/KeyboardLighting.cs, Lighting).
struct Lighting: Equatable {
    var effect: UInt8 = 0x01
    var color = 0xFFFFFF, period = 5000, direction = 1, dim = 50, idle = 60, sleep = 300, intensity = 100
    var solid = false

    func toText(_ brightness: Int) -> String {
        [String(effect), String(format: "%06X", color), String(period), String(direction), String(dim), String(idle), String(sleep),
         String(brightness)].joined(separator: ",")
            + (intensity != 100 || solid ? ",\(intensity)" : "") + (solid ? ",1" : "")
    }

    static func fromText(_ text: String) -> (Lighting, Int)? {
        let parts = text.components(separatedBy: ",")
        guard parts.count >= 8, let effect = UInt8(parts[0]), let color = Int(parts[1], radix: 16), let period = Int(parts[2]),
              let direction = Int(parts[3]), let dim = Int(parts[4]), let idle = Int(parts[5]), let sleep = Int(parts[6]),
              let brightness = Int(parts[7]) else { return nil }
        let lighting = Lighting(effect: effect, color: color, period: period, direction: direction, dim: dim, idle: idle, sleep: sleep,
                                intensity: parts.count > 8 ? Int(parts[8]) ?? 100 : 100, solid: parts.count > 9 && parts[9] == "1")
        return (lighting, brightness)
    }
}

// The G515's onboard files (0x8101) and live effects (0x8071), from app/KeyboardLighting.cs (G515Profile).
enum G515Profile {
    // Never write the factory files (CLAUDE.md).
    static let userDirFile = 0x0000, userProfileFile = 0x0008, factoryDirFile = 0x0100, factoryProfileFile = 0x0101

    // A profile file: `01 01`, the idle and sleep times in seconds (big-endian, FFFF for never), then four 11-byte lighting records:
    // two for the lighting, two for it dimmed. Each bit of the record choice picks the first of its pair (bit 0 the lighting, bit 1
    // the dimmed); G-Lite writes the second of each and a choice of 0.
    static let profileLength = 99, idleAt = 2, sleepAt = 4, recordsAt = 30, recordLength = 11, recordChoiceAt = 74

    // A directory file: its CRC32 over the rest (big-endian), a header, the profile's CRC32, the profile's file id, then FF.
    static let dirLength = 16, dirChecksumAt = 0, dirHeaderAt = 4, dirProfileChecksumAt = 10, dirProfileFileAt = 14
    static let dirHeader: [UInt8] = [0x01, 0x01, 0x81, 0x01, 0x40, 0x63]

    static let effects: [EffectInfo] = [
        EffectInfo(id: 0x00, name: "Off"),
        EffectInfo(id: 0x01, name: "Static", color: true),
        EffectInfo(id: 0x0A, name: "Breathe", color: true, speed: true, intensity: true, minPeriod: 1000, maxPeriod: 20000,
                   defaultPeriod: 5000),
        EffectInfo(id: 0x15, name: "Cycle", speed: true, intensity: true, minPeriod: 1000, maxPeriod: 20000, defaultPeriod: 5000),
        EffectInfo(id: 0x16, name: "Wave", speed: true, direction: true, intensity: true, minPeriod: 1000, maxPeriod: 20000,
                   defaultPeriod: 5000),
        EffectInfo(id: 0x17, name: "Ripple", color: true, speed: true, minPeriod: 2, maxPeriod: 200, defaultPeriod: 20),
    ]

    static func effect(_ id: UInt8) -> EffectInfo? { effects.first { $0.id == id } }

    static func scale(_ color: Int, _ percent: Int) -> Int {
        ((color >> 16 & 0xFF) * percent / 100) << 16 | ((color >> 8 & 0xFF) * percent / 100) << 8 | (color & 0xFF) * percent / 100
    }

    static func encode(_ lighting: Lighting, _ percent: Int) -> [UInt8] {
        var parameters = [UInt8](repeating: 0, count: 10)
        let color = scale(lighting.color, percent), intensity = UInt8(max(1, percent))
        func putColor() { parameters[0] = UInt8(color >> 16 & 0xFF); parameters[1] = UInt8(color >> 8 & 0xFF); parameters[2] = UInt8(color & 0xFF) }
        let period = lighting.period
        switch lighting.effect {
        case 0x01: putColor(); parameters[3] = 0x02
        case 0x0A: putColor(); parameters[3] = UInt8(period >> 8 & 0xFF); parameters[4] = UInt8(period & 0xFF); parameters[6] = intensity
        case 0x15, 0x16:
            parameters[1] = 0xFF; parameters[6] = UInt8(period >> 8 & 0xFF); parameters[7] = UInt8(period & 0xFF); parameters[8] = intensity
            if lighting.effect == 0x16 { parameters[9] = UInt8(lighting.direction & 0xFF) }
        case 0x17: putColor(); parameters[3] = 0xFF; parameters[6] = UInt8(period >> 8 & 0xFF); parameters[7] = UInt8(period & 0xFF)
        default: break
        }
        return parameters
    }

    static func rgb(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) << 16 | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) }
    static func max3(_ color: Int) -> Int { max(color >> 16 & 0xFF, color >> 8 & 0xFF, color & 0xFF) }
    static func get16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
    static func put16(_ bytes: inout [UInt8], _ at: Int, _ value: Int) { bytes[at] = UInt8(value >> 8 & 0xFF); bytes[at + 1] = UInt8(value & 0xFF) }
    static func put32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[at + i] = UInt8(value >> (24 - 8 * UInt32(i)) & 0xFF) }
    }
    static func get32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[at + $1]) }
    }

    // nil when the profile holds an effect G-Lite doesn't know (the factory animation).
    static func decode(_ profile: [UInt8]) -> Lighting? {
        let choice = profile[recordChoiceAt]
        let recordAt = recordsAt + (choice & 1 != 0 ? 0 : recordLength)
        let dimAt = recordsAt + (choice & 2 != 0 ? 2 * recordLength : 3 * recordLength)
        let record = Array(profile[recordAt..<recordAt + recordLength]), dim = Array(profile[dimAt..<dimAt + recordLength])
        guard let info = effect(record[0]) else { return nil }
        var lighting = Lighting(effect: record[0])
        let idle = get16(profile, idleAt), sleep = get16(profile, sleepAt)
        lighting.idle = idle == 0xFFFF ? 0 : idle
        lighting.sleep = sleep == 0xFFFF ? 0 : sleep
        if info.color { lighting.color = rgb(record, 1) }
        if info.speed {
            lighting.period = min(info.maxPeriod, max(info.minPeriod, record[0] == 0x0A ? get16(record, 4) : get16(record, 7)))
        }
        if info.direction { lighting.direction = Int(record[10]) }
        if dim[0] == record[0] {
            if info.color && max3(lighting.color) > 0 {
                lighting.dim = (max3(rgb(dim, 1)) * 100 + max3(lighting.color) / 2) / max3(lighting.color)
            } else if record[0] == 0x15 || record[0] == 0x16 { lighting.dim = Int(dim[9]) }
        }
        return lighting
    }

    static func buildProfile(_ base: [UInt8], _ lighting: Lighting) -> [UInt8] {
        var profile = base
        put16(&profile, idleAt, lighting.idle <= 0 ? 0xFFFF : lighting.idle)
        put16(&profile, sleepAt, lighting.sleep <= 0 ? 0xFFFF : lighting.sleep)
        for i in recordsAt..<recordsAt + 4 * recordLength { profile[i] = 0 }
        let recordAt = recordsAt + recordLength, dimAt = recordsAt + 3 * recordLength
        profile[recordAt] = lighting.effect
        profile.replaceSubrange(recordAt + 1..<recordAt + 11, with: encode(lighting, 100))
        profile[dimAt] = lighting.effect
        profile.replaceSubrange(dimAt + 1..<dimAt + 11, with: encode(lighting, lighting.dim))
        profile[recordChoiceAt] = 0
        return profile
    }

    static func buildDirectory(_ factoryDir: [UInt8], _ profile: [UInt8]) -> [UInt8] {
        var directory = factoryDir
        put32(&directory, dirProfileChecksumAt, crc32(profile))
        directory[dirProfileFileAt] = UInt8(userProfileFile)
        put32(&directory, dirChecksumAt, crc32(Array(directory[dirHeaderAt...])))
        return directory
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for value in data {
            crc ^= UInt32(value)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB88320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    static func validProfile(_ profile: [UInt8]?) -> Bool {
        guard let profile = profile else { return false }
        return profile.count == profileLength && profile[0] == 1 && profile[1] == 1
    }

    static func validDir(_ directory: [UInt8]?) -> Bool {
        guard let directory = directory, directory.count == dirLength else { return false }
        return Array(directory[dirHeaderAt..<dirHeaderAt + dirHeader.count]) == dirHeader && directory[dirLength - 1] == 0xFF
            && crc32(Array(directory[dirHeaderAt...])) == get32(directory, dirChecksumAt)
    }

    // ---- device operations ----

    static func readBuffer(_ hidpp: Hidpp, _ size: Int) throws -> [UInt8] {
        let feature = try hidpp.featureIndex(0x8101)
        var collected: [UInt8] = []
        for offset in stride(from: 0, to: size, by: 16) {
            collected += try hidpp.call(feature, 0xC, [UInt8(offset >> 8), UInt8(offset & 0xFF)])
        }
        return Array(collected.prefix(size))
    }

    static func readFile(_ hidpp: Hidpp, _ address: Int, _ size: Int) throws -> [UInt8]? {
        do {
            try hidpp.call(try hidpp.featureIndex(0x8101), 8,
                           [UInt8(address >> 8), UInt8(address & 0xFF), UInt8(size >> 8), UInt8(size & 0xFF)])
        } catch let error as GLiteError {
            if error.code == 4 && address < factoryDirFile { return nil }
            throw error
        }
        return try readBuffer(hidpp, size)
    }

    static func saveFile(_ hidpp: Hidpp, _ address: Int, _ data: [UInt8], _ checksum: UInt32) throws {
        if address != userDirFile && address != userProfileFile { throw GLiteError.refused("refusing to write factory storage") }
        let feature = try hidpp.featureIndex(0x8101)
        try hidpp.call(feature, 2, [0, UInt8(data.count)])
        for offset in stride(from: 0, to: data.count, by: 16) {
            try hidpp.call(feature, 3, Array(data[offset..<min(offset + 16, data.count)]))
        }
        if try readBuffer(hidpp, data.count) != data { throw GLiteError.io("Staging buffer mismatch, nothing written") }
        var crc = [UInt8](repeating: 0, count: 4)
        put32(&crc, 0, checksum)
        try hidpp.call(feature, 7, [UInt8(address >> 8), UInt8(address & 0xFF), 0, UInt8(data.count)] + crc)
        if try readFile(hidpp, address, data.count) != data { throw GLiteError.io("Flash readback mismatch") }
    }

    struct Files { var factoryProfile, factoryDir, userProfile, userDir: [UInt8]? }

    static func read(_ hidpp: Hidpp) throws -> Files {
        Files(factoryProfile: try readFile(hidpp, factoryProfileFile, profileLength),
              factoryDir: try readFile(hidpp, factoryDirFile, dirLength),
              userProfile: try readFile(hidpp, userProfileFile, profileLength),
              userDir: try readFile(hidpp, userDirFile, dirLength))
    }

    static func checkFiles(_ files: Files) throws {
        if !validProfile(files.factoryProfile) || !validDir(files.factoryDir) {
            throw GLiteError.refused("Unknown onboard profile layout, not touching it")
        }
        if files.userProfile == nil && files.userDir == nil { return }
        let ours = files.userDir == nil || (validDir(files.userDir) && files.userDir![dirProfileFileAt] == UInt8(userProfileFile))
        if ours && (files.userProfile == nil || files.userDir == nil) {
            throw GLiteError.halfWritten("User profile is half written, not touching it")
        }
        if !ours || !validProfile(files.userProfile) {
            throw GLiteError.refused("The profiles saved on the keyboard aren't laid out the way G-Lite writes them, not touching them")
        }
        if crc32(files.userProfile!) != get32(files.userDir!, dirProfileChecksumAt) {
            throw GLiteError.halfWritten("User profile doesn't match its directory entry, not touching it")
        }
    }

    static func filesAreValid(_ files: Files) -> Bool { (try? checkFiles(files)) != nil }

    static func snapshot(_ hidpp: Hidpp) throws -> Files {
        let files = try read(hidpp)
        try checkFiles(files)
        return files
    }

    static func brightness(_ hidpp: Hidpp) throws -> Int { get16(try hidpp.call(try hidpp.featureIndex(0x8040), 1), 0) }

    static func setBrightness(_ hidpp: Hidpp, _ value: Int) throws {
        try hidpp.call(try hidpp.featureIndex(0x8040), 2, [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func claim(_ hidpp: Hidpp) throws {
        try hidpp.call(try hidpp.featureIndex(0x8101), 6, [0x05])
        try hidpp.call(try hidpp.featureIndex(0x8071), 5, [0x01, 0x03, 0x04])
    }

    static func release(_ hidpp: Hidpp) throws {
        try hidpp.call(try hidpp.featureIndex(0x8071), 5, [0x01, 0x00, 0x00])
        try hidpp.call(try hidpp.featureIndex(0x8101), 6, [0x03])
    }

    // Each effect's index on the keys' cluster, looked up once per keyboard: a preview runs often during a slider drag.
    private static var effectIndexes: [ObjectIdentifier: [UInt8: Int]] = [:]
    private static let gate = NSLock()

    static func preview(_ hidpp: Hidpp, _ lighting: Lighting, _ level: Int = 100) throws {
        let feature = try hidpp.featureIndex(0x8071)
        gate.lock(); var index = effectIndexes[ObjectIdentifier(hidpp)]?[lighting.effect] ?? -1; gate.unlock()
        if index < 0 {
            for effectIndex in 0..<16 where index < 0 {
                if try hidpp.call(feature, 0, [0, UInt8(effectIndex), 0])[3] == lighting.effect { index = effectIndex }
            }
            if index >= 0 { gate.lock(); effectIndexes[ObjectIdentifier(hidpp), default: [:]][lighting.effect] = index; gate.unlock() }
        }
        if index < 0 { throw GLiteError.notSupported("Effect not supported by this keyboard") }
        try hidpp.call(feature, 1, [0, UInt8(index)] + encode(lighting, level) + [0x01])
    }

    static func store(_ hidpp: Hidpp, _ files: Files, _ lighting: Lighting) throws {
        let profile = buildProfile(files.userProfile ?? files.factoryProfile!, lighting)
        try writeFiles(hidpp, files, profile, buildDirectory(files.factoryDir!, profile))
    }

    static func restore(_ hidpp: Hidpp, _ backup: Files) throws {
        let now = try read(hidpp)
        if !validProfile(now.factoryProfile) || !validDir(now.factoryDir) {
            throw GLiteError.refused("Unknown onboard profile layout, not touching it")
        }
        if backup.factoryProfile != nil && (backup.factoryProfile != now.factoryProfile || backup.factoryDir != now.factoryDir) {
            throw GLiteError.refused("This backup is from a different keyboard, not restoring it")
        }
        guard let userProfile = backup.userProfile else {
            let profile = now.factoryProfile!
            try writeFiles(hidpp, now, profile, buildDirectory(now.factoryDir!, profile))
            return
        }
        try checkFiles(Files(factoryProfile: now.factoryProfile, factoryDir: now.factoryDir, userProfile: userProfile,
                             userDir: backup.userDir))
        try writeFiles(hidpp, now, userProfile, backup.userDir!)
    }

    static func writeFiles(_ hidpp: Hidpp, _ now: Files, _ profile: [UInt8], _ directory: [UInt8]) throws {
        if now.userProfile != profile { try saveFile(hidpp, userProfileFile, profile, crc32(profile)) }
        if now.userDir != directory { try saveFile(hidpp, userDirFile, directory, crc32(Array(directory[dirHeaderAt...]))) }
        try activate(hidpp, profile)
    }

    static func activate(_ hidpp: Hidpp, _ profile: [UInt8]) throws {
        try hidpp.call(try hidpp.featureIndex(0x8071), 5, [0x01, 0x00, 0x00])
        let feature = try hidpp.featureIndex(0x8101)
        try hidpp.call(feature, 6, [0x0B])
        var config: [UInt8] = [0x81, 0x01, 0x01, 0x00, 0x01, 0x00, 0x63, 0, 0, 0, 0]
        put32(&config, 7, crc32(profile))
        try hidpp.call(feature, 9, config)
        let reply = try hidpp.call(feature, 6, [0x00])
        if reply[0] & 1 == 0 || reply[1] != 0 || reply[2] != 1 {
            throw GLiteError.io(String(format: "Unexpected state %02x %02x %02x after activating", reply[0], reply[1], reply[2]))
        }
    }
}

// A copy of what's on a device taken before every save or restore, in the Windows format (app/Backups.cs): one file per backup,
// `<4 hex digits>=<bytes>` per line. It keeps the first backup and the last ten.
enum Backups {
    static let keep = 10
    static var root = Settings.folder.appendingPathComponent("backups")
    private static let utc: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd-HHmmss-SSS'Z'"
        return format
    }()

    struct Entry {
        let file: URL
        let when: Date
        let first: Bool
        let data: [String: [UInt8]?]
        var files: G515Profile.Files {
            G515Profile.Files(factoryProfile: data["0101"] ?? nil, factoryDir: data["0100"] ?? nil,
                              userProfile: data["0008"] ?? nil, userDir: data["0000"] ?? nil)
        }
    }

    static func folder(_ device: String) -> URL { root.appendingPathComponent(device) }

    static func data(_ files: G515Profile.Files) -> [String: [UInt8]?] {
        ["0101": files.factoryProfile, "0100": files.factoryDir, "0008": files.userProfile, "0000": files.userDir]
    }

    static func save(_ device: String, _ files: G515Profile.Files, who: String? = nil) throws {
        try save(device, data: data(files), who: who)
    }

    // Any device's memory: the G515's four files, a mouse's profile sector.
    static func save(_ device: String, data: [String: [UInt8]?], who: String? = nil) throws {
        let list = self.list(device)
        if let last = list.first, last.data == data { return }
        do {
            let dir = folder(device)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var when = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded(.down) / 1000)
            while list.contains(where: { utc.string(from: $0.when) == utc.string(from: when) }) { when.addTimeInterval(0.001) }
            let name = (list.isEmpty ? "first-" : "") + utc.string(from: when) + ".txt"
            let text = data.keys.sorted { order($0) < order($1) }.map { $0 + "=" + Log.hex((data[$0] ?? nil) ?? []) }
                .joined(separator: "\n") + "\n"
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch {
            throw GLiteError.refused("Couldn't make a backup, so nothing was written: \(error.localizedDescription)")
        }
        if let who = who { Log.add(who, "backup", data.count == 1 ? "sector " + data.keys.first! : "\(data.count) files") }
        for old in self.list(device).filter({ !$0.first }).dropFirst(keep) { try? FileManager.default.removeItem(at: old.file) }
    }

    // The G515's files in the order Windows writes them, others after.
    private static func order(_ key: String) -> String { (["0101", "0100", "0008", "0000"].firstIndex(of: key).map { "\($0)" } ?? "9") + key }

    static func list(_ device: String) -> [Entry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder(device), includingPropertiesForKeys: nil) else {
            return []
        }
        var entries: [Entry] = []
        for file in files where file.pathExtension == "txt" {
            var name = file.deletingPathExtension().lastPathComponent
            let first = name.hasPrefix("first-")
            if first { name.removeFirst(6) }
            guard let when = utc.date(from: name), let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var data: [String: [UInt8]?] = [:]
            for line in text.components(separatedBy: .newlines) where line.count > 4 && Array(line)[4] == "=" {
                let hex = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                data[String(line.prefix(4))] = hex.isEmpty ? nil : bytes(hex)
            }
            entries.append(Entry(file: file, when: when, first: first, data: data))
        }
        return entries.sorted { $0.when > $1.when }
    }

    static func bytes(_ hex: String) -> [UInt8] {
        let chars = Array(hex)
        return stride(from: 0, to: chars.count - 1, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }
    }

    static func describe(_ files: G515Profile.Files) -> String {
        if !G515Profile.filesAreValid(files) { return "damaged, can't be restored" }
        guard let profile = files.userProfile else { return "factory lighting" }
        guard let lighting = G515Profile.decode(profile) else { return "factory animation" }
        return G515Profile.effect(lighting.effect)?.name ?? "unknown"
    }
}
