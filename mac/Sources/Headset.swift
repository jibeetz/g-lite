import Foundation

// Sidetone (0x8300) and auto-off (0x1F20 fn 1 and 2, in minutes, 0 is never) on the PRO X Wireless and the headsets like it
// (app/HeadsetProtocol.cs). 0x1F20 fn 0 is the battery voltage, and byte 2 is 3 while charging.
struct HeadsetSettings: Equatable {
    var sidetone = 0, autoOffMinutes = -1
    // The equalizer's bands in dB, nil without one. In a preset after a second comma, space-separated (older presets have none).
    var bands: [Int]?

    var text: String { "\(sidetone),\(autoOffMinutes)" + (bands.map { "," + $0.map(String.init).joined(separator: " ") } ?? "") }

    static func fromText(_ text: String) -> HeadsetSettings? {
        let parts = text.components(separatedBy: ",")
        guard parts.count == 2 || parts.count == 3, let sidetone = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        var bands: [Int]?
        if parts.count == 3 {
            let values = parts[2].split(separator: " ").map { Int($0) }
            if values.contains(nil) { return nil }
            bands = values.compactMap { $0 }
        }
        return HeadsetSettings(sidetone: sidetone, autoOffMinutes: minutes, bands: bands)
    }
}

enum HeadsetProtocol {
    static let offMinutes = [0, 5, 10, 15, 30, 60, 90]

    struct State {
        var hasSidetone = false, hasOff = false, charging = false
        var millivolts = 0
        var set = HeadsetSettings()
        // The equalizer (0x8310), when the headset has one: each band's frequency in Hz, and the most dB a band goes up or down.
        var frequencies: [Int]?
        var range = 0
    }

    static func read(_ hidpp: Hidpp, autoOff: Bool) throws -> State {
        var state = State()
        do { state.set.sidetone = Int(try hidpp.call(try hidpp.featureIndex(0x8300), 0)[0]); state.hasSidetone = true }
        catch GLiteError.notSupported {} catch GLiteError.hidpp {}
        do {
            let reply = try hidpp.call(try hidpp.featureIndex(0x1F20), 0)
            state.millivolts = Int(reply[0]) << 8 | Int(reply[1])
            state.charging = reply[2] == 3
        } catch GLiteError.notSupported {} catch GLiteError.hidpp {}
        do { try readEqualizer(hidpp, &state) } catch GLiteError.notSupported {} catch GLiteError.hidpp {}
        if !autoOff { return state }
        do { state.set.autoOffMinutes = Int(try hidpp.call(try hidpp.featureIndex(0x1F20), 1)[0]); state.hasOff = true }
        catch GLiteError.notSupported {} catch GLiteError.hidpp {}
        return state
    }

    // 0x8310, from Logitech's spec (x8310) and the PRO X's report: fn 0 gives the band count and the dB range, fn 1 the frequencies
    // from a band (7 per call, big endian), fn 2 one signed byte per band (location 0, the stored equalizer). The PRO X stored bands
    // written with persistence 2 without applying them (CLAUDE.md); this writes persistence 1, RAM and EEPROM, and 0 while a band is
    // dragged. Experimental.
    static func readEqualizer(_ hidpp: Hidpp, _ state: inout State) throws {
        let feature = try hidpp.featureIndex(0x8310)
        let info = try hidpp.call(feature, 0)
        // fn 3 writes a persistence byte before the bands, in a 16-byte report.
        let count = min(Int(info[0]), 15)
        if count == 0 { return }
        var frequencies = [Int](repeating: 0, count: count)
        for start in stride(from: 0, to: count, by: 7) {
            let reply = try hidpp.call(feature, 1, [UInt8(start)])
            for i in 0..<7 where start + i < count { frequencies[start + i] = Int(reply[1 + 2 * i]) << 8 | Int(reply[2 + 2 * i]) }
        }
        let bands = try hidpp.call(feature, 2, [0])
        state.range = max(1, Int(info[1]))
        state.set.bands = (0..<count).map { max(-state.range, min(state.range, Int(Int8(bitPattern: bands[$0])))) }
        state.frequencies = frequencies
    }

    // keep: persistence 1, RAM and EEPROM; otherwise 0, RAM only (while a band is dragged, sparing the EEPROM).
    static func setEqualizer(_ hidpp: Hidpp, _ bands: [Int], keep: Bool) throws {
        try hidpp.call(try hidpp.featureIndex(0x8310), 3, [keep ? 1 : 0] + bands.map { UInt8(bitPattern: Int8($0)) })
    }

    static func setSidetone(_ hidpp: Hidpp, _ level: Int) throws {
        try hidpp.call(try hidpp.featureIndex(0x8300), 1, [UInt8(max(0, min(100, level)))])
    }

    static func setOff(_ hidpp: Hidpp, _ minutes: Int) throws {
        try hidpp.call(try hidpp.featureIndex(0x1F20), 2, [UInt8(max(0, min(90, minutes)))])
    }
}
