import Foundation

// Sidetone (0x8300) and auto-off (0x1F20 fn 1 and 2, in minutes, 0 is never) on the PRO X Wireless and the headsets like it
// (app/HeadsetProtocol.cs). 0x1F20 fn 0 is the battery voltage, and byte 2 is 3 while charging.
struct HeadsetSettings: Equatable {
    var sidetone = 0, autoOffMinutes = -1
}

enum HeadsetProtocol {
    static let offMinutes = [0, 5, 10, 15, 30, 60, 90]

    struct State {
        var hasSidetone = false, hasOff = false, charging = false
        var millivolts = 0
        var set = HeadsetSettings()
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
        if !autoOff { return state }
        do { state.set.autoOffMinutes = Int(try hidpp.call(try hidpp.featureIndex(0x1F20), 1)[0]); state.hasOff = true }
        catch GLiteError.notSupported {} catch GLiteError.hidpp {}
        return state
    }

    static func setSidetone(_ hidpp: Hidpp, _ level: Int) throws {
        try hidpp.call(try hidpp.featureIndex(0x8300), 1, [UInt8(max(0, min(100, level)))])
    }

    static func setOff(_ hidpp: Hidpp, _ minutes: Int) throws {
        try hidpp.call(try hidpp.featureIndex(0x1F20), 2, [UInt8(max(0, min(90, minutes)))])
    }
}
