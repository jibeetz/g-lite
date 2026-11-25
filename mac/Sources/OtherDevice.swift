import Foundation

// A set of settings of a Logitech device that isn't a G device, in the Windows text (app/OtherDevice.cs, OtherSettings).
struct OtherSettings: Equatable {
    // Away, Near and Powered are the backlight's fade delays in seconds: hands away from the keys, hands near them, on external power.
    static let bright = 0, dpi = 1, shift = 2, invert = 3, thumb = 4, light = 5, auto = 6, level = 7, away = 8, near = 9, powered = 10
    static let count = 11
    static let delays = [away, near, powered]
    static let keys = ["bright", "dpi", "shift", "invert", "thumb", "light", "auto", "level", "away", "near", "powered"]

    // -1 is a setting the device doesn't have, or one this set leaves alone. Shift is SmartShift's threshold: 1–50, or 255 when it's
    // off (the wheel never switches to free spin).
    private var values = [Int](repeating: -1, count: OtherSettings.count)

    subscript(setting: Int) -> Int {
        get { values[setting] }
        set { values[setting] = newValue }
    }

    mutating func merge(_ over: OtherSettings) {
        for setting in 0..<OtherSettings.count where over[setting] >= 0 { values[setting] = over[setting] }
    }

    func toText() -> String {
        (0..<OtherSettings.count).filter { values[$0] >= 0 }.map { OtherSettings.keys[$0] + ":\(values[$0])" }.joined(separator: ",")
    }

    static func fromText(_ text: String) -> OtherSettings {
        var set = OtherSettings()
        for part in text.components(separatedBy: ",") {
            let pair = part.components(separatedBy: ":")
            guard pair.count == 2, let setting = keys.firstIndex(of: pair[0]), let number = Int(pair[1]), number >= 0 else { continue }
            set[setting] = number
        }
        return set
    }
}

// The settings of Logitech devices that aren't G devices (app/OtherDevice.cs). Bytes from Solaar's settings, OpenLogi's captures of
// an MX Master 3S and MX Keys S, and the MX Creative Keypad's report. See docs/other-devices.md.
enum OtherDevice {
    // 0x1814 alone doesn't get the screen: a device with only Easy-Switch has nothing else to set.
    static let features = [0x8040, 0x2201, 0x2110, 0x2111, 0x2121, 0x2150, 0x1982]

    // shortcut: the Windows version keeps the info page for a device with 0x40A0 and a coarse battery (the K295) and offers its media
    // keys there; the Mac scan doesn't know coarse batteries yet, so such a device gets this screen with what it has.
    static func supports(_ found: FoundDevice) -> Bool { !found.isG && features.contains(where: found.has) }

    struct State {
        var set = OtherSettings()
        var brightMax = 100, shiftDefault = 10, shiftFeature = 0, levels = 0, hosts = 0, host = -1
        var dpis: [Int] = []
        var names: [String?] = []
        var paired: [Bool] = []
        var pairedKnown = false
    }

    static func get16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }

    static func attempt(_ device: Hidpp, _ feature: Int, _ fn: Int, _ parameters: [UInt8] = []) throws -> [UInt8]? {
        do { return try device.call(try device.featureIndex(feature), fn, parameters) } catch let error as GLiteError {
            switch error {
            case .hidpp, .notSupported: return nil
            default: throw error
            }
        }
    }

    static func read(_ device: Hidpp, _ found: FoundDevice) throws -> State {
        var state = State()
        if found.has(0x8040) {
            let info = try attempt(device, 0x8040, 0), now = try attempt(device, 0x8040, 1)
            if let info = info, get16(info, 0) > 0 { state.brightMax = get16(info, 0) }
            if let now = now { state.set[OtherSettings.bright] = min(state.brightMax, get16(now, 0)) }
        }
        if found.has(0x2201) {
            let list = try attempt(device, 0x2201, 1, [0]), now = try attempt(device, 0x2201, 2, [0])
            if let list = list { state.dpis = MouseProtocol.dpiList(list) }
            let dpi = now.map { get16($0, 1) != 0 ? get16($0, 1) : get16($0, 3) } ?? 0
            if dpi > 0 && !state.dpis.isEmpty { state.set[OtherSettings.dpi] = dpi }
        }
        if found.has(0x2111) {
            let capabilities = try attempt(device, 0x2111, 0), now = try attempt(device, 0x2111, 1)
            if let capabilities = capabilities, capabilities[1] > 0 { state.shiftDefault = Int(capabilities[1]) }
            if let now = now, now[1] > 0 { state.set[OtherSettings.shift] = Int(now[1]); state.shiftFeature = 0x2111 }
        } else if found.has(0x2110) {
            // The default is what G-Lite last wrote (it survives a reset); FF is SmartShift off, not a threshold to start the slider at.
            if let now = try attempt(device, 0x2110, 0) {
                if now[2] > 0 && now[2] < 0xFF { state.shiftDefault = Int(now[2]) }
                if now[1] > 0 { state.set[OtherSettings.shift] = Int(now[1]); state.shiftFeature = 0x2110 }
            }
        }
        state.shiftDefault = max(1, min(50, state.shiftDefault))
        if found.has(0x2121) {
            let capabilities = try attempt(device, 0x2121, 0), mode = try attempt(device, 0x2121, 1)
            if let capabilities = capabilities, capabilities[1] & 0x08 != 0, let mode = mode {
                state.set[OtherSettings.invert] = mode[0] & 0x04 != 0 ? 1 : 0
            }
        }
        if found.has(0x2150), let now = try attempt(device, 0x2150, 1) { state.set[OtherSettings.thumb] = Int(now[1] & 1) }
        if found.has(0x1982), let config = try attempt(device, 0x1982, 0) {
            state.set[OtherSettings.light] = Int(config[0] & 1)
            // Mode 2 (temporary manual) is automatic nudged with the keys: the keyboard goes back to automatic at the next power-on
            // (spec x1982 v3).
            let mode = Int(config[1] >> 3 & 3)
            if config[2] & 0x08 != 0 && config[2] & 0x20 != 0 { state.set[OtherSettings.auto] = mode == 1 || mode == 2 ? 1 : 0 }
            // In mode 3 the level is fn 0's b5, the stored setting, like Solaar. Outside it b5 reads 0 (spec x1982 v3), so the slider
            // shows fn 2's b1, the level lit now (it fades when idle).
            if config[2] & 0x20 != 0, let info = try attempt(device, 0x1982, 2), info[0] > 1 {
                state.levels = Int(info[0])
                state.set[OtherSettings.level] = min(Int(info[0]) - 1, Int(mode == 3 ? config[5] : info[1]))
            }
            // Bytes 6–11: the fade delays, little-endian, in units of 5 s (spec x1982 v3, named by Solaar). Offered only when all three
            // read, since an older version of the feature may not have them.
            let delays: [Int] = (0..<3).map { (index: Int) -> Int in Int(config[6 + 2 * index]) | Int(config[7 + 2 * index]) << 8 }
            if delays.allSatisfy({ $0 > 0 }) {
                for (index, setting) in OtherSettings.delays.enumerated() { state.set[setting] = delays[index] * 5 }
            }
        }
        if found.has(0x1814) {
            if let info = try attempt(device, 0x1814, 0), info[0] > 1, info[1] < info[0] {
                state.hosts = min(6, Int(info[0])); state.host = Int(info[1])
            }
            state.names = [String?](repeating: nil, count: state.hosts)
            state.paired = [Bool](repeating: true, count: state.hosts)
            // The names are only shown, so a computer that doesn't answer for them doesn't stop the screen.
            if state.hosts > 0 && found.has(0x1815) {
                do { try readNames(device, &state) } catch GLiteError.timeout { state.pairedKnown = false }
            }
        }
        return state
    }

    static func readNames(_ device: Hidpp, _ state: inout State) throws {
        guard let capabilities = try attempt(device, 0x1815, 0) else { return }
        state.pairedKnown = true
        for host in 0..<state.hosts {
            guard let info = try attempt(device, 0x1815, 1, [UInt8(host)]) else { state.pairedKnown = false; continue }
            state.paired[host] = info[1] == 1 || host == state.host
            if !state.paired[host] || capabilities[0] & 1 == 0 || info[4] == 0 { continue }
            var bytes: [UInt8] = []
            while bytes.count < info[4] {
                guard let part = try attempt(device, 0x1815, 3, [UInt8(host), UInt8(bytes.count)]) else { break }
                bytes += part.dropFirst(2).prefix(min(14, Int(info[4]) - bytes.count))
            }
            if !bytes.isEmpty {
                state.names[host] = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
            }
        }
    }

    static func name(_ setting: Int) -> String {
        ["brightness", "pointer speed", "SmartShift", "invert scrolling", "thumb wheel", "backlight", "backlight", "backlight",
         "backlight", "backlight", "backlight"][setting]
    }

    // Each setting is sent on its own, so one the device refuses doesn't stop the others. Returns the refused settings.
    static func apply(_ device: Hidpp, _ state: State, _ want: OtherSettings, _ sent: OtherSettings) throws -> [Int] {
        var refused: [Int] = []
        func send(_ setting: Int, _ write: () throws -> Void) throws {
            if want[setting] < 0 || want[setting] == sent[setting] { return }
            do { try write() } catch GLiteError.hidpp { refused.append(setting) }
        }
        func index(_ feature: Int) throws -> UInt8 { try device.featureIndex(feature) }
        try send(OtherSettings.bright) {
            try device.call(index(0x8040), 2, [UInt8(want[OtherSettings.bright] >> 8 & 0xFF), UInt8(want[OtherSettings.bright] & 0xFF)])
        }
        try send(OtherSettings.dpi) {
            try device.call(index(0x2201), 3, [0, UInt8(want[OtherSettings.dpi] >> 8 & 0xFF), UInt8(want[OtherSettings.dpi] & 0xFF)])
        }
        // 0 in a SmartShift byte leaves it, so the wheel's mode, set with its button, isn't touched. 0x2110 goes back to its third byte
        // (autoDisengageDefault) at each reset, so it gets the threshold too; 0x2111 keeps its settings and its third byte is the
        // torque (specs x2110, x2111).
        try send(OtherSettings.shift) {
            let threshold = UInt8(want[OtherSettings.shift] & 0xFF), v2 = state.shiftFeature == 0x2111
            try device.call(index(state.shiftFeature), v2 ? 2 : 1, [0, threshold, v2 ? 0 : threshold])
        }
        // Read just before writing: Logi Options+ may have diverted the wheel since (bit 0). Only bit 2 changes. Bit 1 (high
        // resolution) makes Windows scroll many times too fast.
        try send(OtherSettings.invert) {
            let mode = try device.call(index(0x2121), 1)
            try device.call(index(0x2121), 2, [mode[0] & ~0x04 | (want[OtherSettings.invert] == 1 ? 0x04 : 0), mode[1], mode[2]])
        }
        try send(OtherSettings.thumb) {
            let now = try device.call(index(0x2150), 1)
            try device.call(index(0x2150), 2, [now[0], UInt8(want[OtherSettings.thumb]), 0])
        }
        let lightSettings = [OtherSettings.light, OtherSettings.auto, OtherSettings.level] + OtherSettings.delays
        if lightSettings.contains(where: { want[$0] >= 0 && want[$0] != sent[$0] }) {
            do {
                // The keyboard stores this write. Delays not picked go back as read; the level is sent only in mode 3, else 0, like
                // Solaar. Mode 2 can't be set (spec x1982 v3), so a keyboard in it is written back as automatic. Outside mode 3 the
                // stored level reads 0, so going to mode 3 without a level picked takes the level lit now (fn 2 byte 1) rather than
                // turning the backlight off.
                let config = try device.call(index(0x1982), 0)
                let now = Int(config[1] >> 3 & 3)
                let picked = want[OtherSettings.level] >= 0 && want[OtherSettings.level] != sent[OtherSettings.level]
                let mode = want[OtherSettings.auto] == 1 ? 1 : want[OtherSettings.auto] == 0 || picked ? 3 : now == 2 ? 1 : now
                let options = config[1] & ~0x18 | UInt8(mode << 3)
                var level = mode != 3 ? 0 : picked ? want[OtherSettings.level] : now == 3 ? Int(config[5])
                    : Int(try device.call(index(0x1982), 2)[1])
                // A level nobody picked that reads 0 (faded, or never set) would store the backlight off: the middle level instead.
                if mode == 3 && !picked && level == 0 { level = max(1, (state.levels - 1) / 2) }
                let on = want[OtherSettings.light] >= 0 ? want[OtherSettings.light] == 1 : config[0] & 1 != 0
                var delays: [UInt8] = []
                for (index, setting) in OtherSettings.delays.enumerated() {
                    let units = want[setting] > 0 ? want[setting] / 5 : Int(config[6 + 2 * index]) | Int(config[7 + 2 * index]) << 8
                    delays += [UInt8(units & 0xFF), UInt8(units >> 8 & 0xFF)]
                }
                try device.call(index(0x1982), 1, [on ? 1 : 0, options, 0xFF, UInt8(level & 0xFF)] + delays + [0, 0])
            } catch GLiteError.hidpp { refused += lightSettings.filter { want[$0] >= 0 } }
        }
        return refused
    }

    static func switchTo(_ device: Hidpp, _ host: Int) throws {
        try device.sendWithoutReply(try device.featureIndex(0x1814), 1, [UInt8(host)])
    }

    // Keeps only what this device has, in its ranges, so a preset or remembered setting from elsewhere can't send something it lacks.
    static func keepSupported(_ over: OtherSettings, _ state: State) -> OtherSettings {
        var limited = OtherSettings()
        for setting in 0..<OtherSettings.count {
            var value = over[setting]
            if value < 0 || state.set[setting] < 0 { continue }
            switch setting {
            case OtherSettings.bright: value = min(state.brightMax, value)
            case OtherSettings.dpi: value = state.dpis[nearest(state.dpis, value)]
            case OtherSettings.shift: if value > 50 && value != 255 { value = -1 }
            case OtherSettings.level: value = min(state.levels - 1, value)
            // Up to 2 hours (Solaar's note on the spec), in steps of 5 s.
            case OtherSettings.away, OtherSettings.near, OtherSettings.powered: value = max(5, min(7200, value / 5 * 5))
            default: value = value == 1 ? 1 : 0
            }
            limited[setting] = value
        }
        return limited
    }

    static func nearest(_ list: [Int], _ value: Int) -> Int {
        var best = 0
        for index in 1..<max(1, list.count) where abs(list[index] - value) < abs(list[best] - value) { best = index }
        return best
    }
}
