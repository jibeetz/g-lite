import Foundation

// A set of settings of a Logitech device that isn't a G device, in the Windows text (app/OtherDevice.cs, OtherSettings).
struct OtherSettings: Equatable {
    // Away, Near and Powered are the backlight's fade delays in seconds: hands away from the keys, hands near them, on external power.
    // Effect is a 0x1982 effect id, Saver the backlight's battery saving, MediaKeys 0x40A3's state (1: F1–F12 are media keys) and
    // Disabled 0x4521's bits (1 Caps Lock, 2 Num Lock, 4 Scroll Lock, 8 Insert, 16 Windows).
    static let bright = 0, dpi = 1, shift = 2, invert = 3, thumb = 4, light = 5, auto = 6, level = 7, away = 8, near = 9, powered = 10
    static let effect = 11, saver = 12, mediaKeys = 13, disabled = 14
    static let count = 15
    static let delays = [away, near, powered]
    static let keys = ["bright", "dpi", "shift", "invert", "thumb", "light", "auto", "level", "away", "near", "powered", "effect", "saver",
                       "mediakeys", "disabled"]

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
// an MX Master 3S and MX Keys S, and the reports of an MX Creative Keypad and an MX Mechanical Mini. See docs/other-devices.md.
enum OtherDevice {
    // 0x1814 alone doesn't get the screen: a device with only Easy-Switch has nothing else to set.
    static let features = [0x8040, 0x2201, 0x2110, 0x2111, 0x2121, 0x2150, 0x1982, 0x40A3, 0x4521]

    // 0x1982's effects, in Logi Options+'s order; 1 (none) isn't offered.
    static let effectIds = [0, 3, 2, 6, 4, 5]
    static let effectNames = ["Static", "Contrast", "Breathing", "Waves", "Reaction", "Random"]

    static let disableBits = [1, 2, 4, 8, 16]
    static let disableNames = ["Caps Lock", "Num Lock", "Scroll Lock", "Insert", "Windows key"]

    // The keyboards drawn on their screen, matched by name; the layout comes from a photo.
    static func picture(_ found: FoundDevice) -> String? {
        let name = found.shortName.lowercased()
        return name.hasPrefix("mx mechanical mini") ? "mx-mechanical-mini.json" : name.hasPrefix("mx keys s") ? "mx-keys-s.json" : nil
    }

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
        // 0x1982's effect bits (bit n is effect n) and 0x4521's keys that can be disabled.
        var effects = 0, disableable = 0
        // The computer 0x40A3 is read and set for: this one's Easy-Switch index, read before any switch.
        var fnKeysHost: UInt8 = 0xFF
        // 0x4540's layout code, read only for a keyboard with a picture (KeyLayout.isIso).
        var layoutCode = -1
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
            // b2 bit 2: battery saving is supported, b1 bit 2 it's on (off below 10%, Logi Options+); b3–4 the effects, a bit each
            // (OpenLogi's notes on x1982 v3). Only Static and None (the MX Keys S) is no choice.
            if config[2] & 0x04 != 0 { state.set[OtherSettings.saver] = config[1] & 0x04 != 0 ? 1 : 0 }
            state.effects = Int(config[3]) | Int(config[4]) << 8
            let effects = state.effects & ~3 != 0
            let info = config[2] & 0x20 != 0 || effects ? try attempt(device, 0x1982, 2) : nil
            // fn 2 b3 is the effect shown now. One the list doesn't have (None, maybe, while the backlight is off) reads as FF: the row
            // stays, with nothing picked, and fn 1 takes FF as unchanged.
            if effects, let info = info {
                let shown = Int(info[3])
                state.set[OtherSettings.effect] = shown < 16 && state.effects >> shown & 1 != 0 && effectIds.contains(shown) ? shown : 0xFF
            }
            if config[2] & 0x20 != 0, let info = info, info[0] > 1 {
                state.levels = Int(info[0])
                state.set[OtherSettings.level] = min(Int(info[0]) - 1, Int(mode == 3 ? config[5] : info[1]))
                // Faded, it reads 0, which turning Automatic off would store as off.
                if mode != 3 && state.set[OtherSettings.level] == 0 { state.set[OtherSettings.level] = max(1, (Int(info[0]) - 1) / 2) }
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
        // fn 0 `<host>` asks for a computer's: host, state (1: F1–F12 are media keys, as Logi Options+ shows it), default, capabilities
        // (an MX Mechanical Mini answers `FF 01 01 01`; OpenLogi's notes); fn 1 `<host> <state> 00` sets it. The MX Keys S takes FF but
        // ignores it, and reads 00 for it (2026-11-26): the computer's Easy-Switch index works on it and on the Mini, so FF is only for
        // a device that doesn't say it.
        if found.has(0x40A3) {
            state.fnKeysHost = state.host >= 0 ? UInt8(state.host) : 0xFF
            if let fnKeys = try attempt(device, 0x40A3, 0, [state.fnKeysHost, 0, 0]) { state.set[OtherSettings.mediaKeys] = Int(fnKeys[1] & 1) }
        }
        // fn 0 the keys that can be disabled, fn 1 those that are (OpenLogi's notes; the MX Mechanical Mini answers 1D: no Num Lock).
        if found.has(0x4521), let keys = try attempt(device, 0x4521, 0), keys[0] & 0x1F != 0, let disabled = try attempt(device, 0x4521, 1) {
            state.disableable = Int(keys[0] & 0x1F)
            state.set[OtherSettings.disabled] = Int(disabled[0]) & state.disableable
        }
        if picture(found) != nil && found.has(0x4540), let layout = try attempt(device, 0x4540, 0) { state.layoutCode = Int(layout[0]) }
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
         "backlight", "backlight", "backlight", "backlight", "backlight", "F1–F12 setting", "disabled keys"][setting]
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
        try send(OtherSettings.mediaKeys) {
            try device.call(index(0x40A3), 1, [state.fnKeysHost, UInt8(want[OtherSettings.mediaKeys] & 0xFF), 0])
        }
        try send(OtherSettings.disabled) { try device.call(index(0x4521), 2, [UInt8(want[OtherSettings.disabled] & 0xFF)]) }
        let lightSettings = [OtherSettings.light, OtherSettings.auto, OtherSettings.level, OtherSettings.effect, OtherSettings.saver]
            + OtherSettings.delays
        if lightSettings.contains(where: { want[$0] >= 0 && want[$0] != sent[$0] }) {
            do {
                // The keyboard stores this write. Delays not picked go back as read; the level is sent only in mode 3, else 0, like
                // Solaar. Mode 2 can't be set (spec x1982 v3), so a keyboard in it is written back as automatic. Outside mode 3 the
                // stored level reads 0, which is off, so going to mode 3 without a level picked takes the one the screen shows, else
                // the level lit now (fn 2 byte 1). Not fn 2 first: in automatic it's the room's level, and the screen still shows the
                // one picked before (seen on an MX Mechanical Mini, 2026-11-26).
                let config = try device.call(index(0x1982), 0)
                let now = Int(config[1] >> 3 & 3)
                let picked = want[OtherSettings.level] >= 0 && want[OtherSettings.level] != sent[OtherSettings.level]
                let mode = want[OtherSettings.auto] == 1 ? 1 : want[OtherSettings.auto] == 0 || picked ? 3 : now == 2 ? 1 : now
                var options = config[1] & ~0x18 | UInt8(mode << 3)
                if want[OtherSettings.saver] >= 0 { options = options & ~0x04 | (want[OtherSettings.saver] == 1 ? 0x04 : 0) }
                // FF leaves the effect as it is.
                let effect = want[OtherSettings.effect] >= 0 && want[OtherSettings.effect] != sent[OtherSettings.effect]
                // Already in mode 3, a level not picked is the stored one, which the keyboard's own keys may have changed since.
                let fromLitNow = mode == 3 && !picked && now != 3 && want[OtherSettings.level] < 0
                let on = want[OtherSettings.light] >= 0 ? want[OtherSettings.light] == 1 : config[0] & 1 != 0
                var level = mode != 3 ? 0 : picked ? want[OtherSettings.level] : now == 3 ? Int(config[5])
                    : !fromLitNow ? want[OtherSettings.level] : Int(try device.call(index(0x1982), 2)[1])
                // A level the screen doesn't show that reads 0 (faded, or never set) would store the backlight off: the middle one.
                if fromLitNow && level == 0 { level = max(1, (state.levels - 1) / 2) }
                // Turned off, the MX Mechanical Mini reads its stored level as 0 (seen on one, 2026-11-26), so turning it on again kept
                // it dark: the level the screen shows instead, else the middle one.
                if mode == 3 && !picked && now == 3 && level == 0 && on && config[0] & 1 == 0 {
                    level = want[OtherSettings.level] > 0 ? want[OtherSettings.level] : max(1, (state.levels - 1) / 2)
                }
                var delays: [UInt8] = []
                for (index, setting) in OtherSettings.delays.enumerated() {
                    let units = want[setting] > 0 ? want[setting] / 5 : Int(config[6 + 2 * index]) | Int(config[7 + 2 * index]) << 8
                    delays += [UInt8(units & 0xFF), UInt8(units >> 8 & 0xFF)]
                }
                try device.call(index(0x1982), 1, [on ? 1 : 0, options, effect ? UInt8(want[OtherSettings.effect] & 0xFF) : 0xFF,
                                                   UInt8(level & 0xFF)] + delays + [0, 0])
            } catch GLiteError.hidpp { refused += lightSettings.filter { want[$0] >= 0 } }
        }
        return refused
    }

    static func switchTo(_ device: Hidpp, _ host: Int) throws {
        try device.sendWithoutReply(try device.featureIndex(0x1814), 1, [UInt8(host)])
    }

    // Keys an app like Logi Options+ diverted to itself (0x1B04) do nothing while it isn't running, until the device reconnects
    // (docs/mx-key-bindings.md). This gives them back: fn 3 with the valid bit (one above) of each diversion flag that's on (diverted
    // 0x01, persistently 0x04, raw XY 0x10, force raw XY 0x40) and the flag off, remap 0 (unchanged). It never diverts. Returns how many.
    static func releaseDiverted(_ device: Hidpp) throws -> Int {
        let feature = try device.featureIndex(0x1B04)
        let count = Int(try device.callUnlogged(feature, 0)[0])
        var released = 0
        for index in 0..<min(count, 48) {
            // A control the device refuses doesn't keep the others diverted.
            do {
                let info = try device.callUnlogged(feature, 1, [UInt8(index)])
                // Neither divertable (0x20, 0x40) nor raw XY (0x100, 0x200): nothing can have diverted it.
                if info[4] & 0x60 == 0 && info[8] & 0x03 == 0 { continue }
                let reporting = try device.callUnlogged(feature, 2, [info[0], info[1]])
                let clear = [0x01, 0x04, 0x10, 0x40].filter { Int(reporting[2]) & $0 != 0 }.reduce(0) { $0 + ($1 << 1) }
                if clear == 0 { continue }
                try device.call(feature, 3, [info[0], info[1], UInt8(clear), 0, 0])
                released += 1
            } catch GLiteError.hidpp {}
        }
        return released
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
            case OtherSettings.effect: if value > 15 || state.effects >> value & 1 == 0 { value = -1 }
            case OtherSettings.disabled: value &= state.disableable
            // Up to 2 hours (Solaar's note on the spec), in steps of 5 s.
            case OtherSettings.away, OtherSettings.near, OtherSettings.powered: value = max(5, min(7200, value / 5 * 5))
            default: value = value == 1 ? 1 : 0
            }
            if value < 0 { continue }
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
