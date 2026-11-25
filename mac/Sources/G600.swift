import Foundation

// The G600 doesn't speak HID++ (app/G600.cs, docs/G600.md). Its vendor collection has feature report F0, the active mode and DPI
// level, and F3 to F5, one 154-byte report per mode. Layout from libratbag's driver-logitech-g600.c and tulth/g600prog (both MIT),
// which agree. Read only until an owner tries a write.
final class G600Mouse: MouseDriver {
    static let activeReport: UInt8 = 0xF0, firstModeReport: UInt8 = 0xF3
    static let modeCount = 3, reportLength = 154, buttonCount = 20
    static let colorAt = 1, effectAt = 4, durationAt = 5, frequencyAt = 11, defaultLevelAt = 13, dpisAt = 14, levelCount = 4
    static let buttonsAt = 31, buttonLength = 3, dpiUnit = 50, minDpi = 200, maxDpi = 8200
    static let shownRates = [125, 250, 500, 1000]

    var effects: [EffectInfo] { MouseProtocol.effects }
    var hasFactory: Bool { false }

    func read(_ hidpp: Hidpp) throws -> MouseProtocol.State {
        let active = try hidpp.getFeature(G600Mouse.activeReport)
        let mode = Int(active[1] >> 4), level = Int(active[1] >> 1 & 3)
        if mode >= G600Mouse.modeCount { throw GLiteError.io("The G600 reported mode \(mode + 1) of \(G600Mouse.modeCount)") }
        let report = try hidpp.getFeature(G600Mouse.firstModeReport + UInt8(mode))
        if report.count < G600Mouse.reportLength || report[0] != G600Mouse.firstModeReport + UInt8(mode) {
            throw GLiteError.io("The G600 sent an unexpected report for mode \(mode + 1)")
        }
        return G600Mouse.decode(report, level)
    }

    static func decode(_ report: [UInt8], _ level: Int) -> MouseProtocol.State {
        // A level of 0 is off; the levels after it aren't used.
        let stages = Array((0..<levelCount).map { Int(report[dpisAt + $0]) * dpiUnit }.prefix { $0 > 0 })
        let stage = level < stages.count ? level : -1
        let state = MouseProtocol.State()
        state.readOnly = true
        state.onboard = true
        state.profile = report
        state.stages = stages
        state.stage = stage
        state.dpi = stage >= 0 ? stages[stage] : stages.first ?? 0
        state.dpis = (minDpi / dpiUnit...maxDpi / dpiUnit).map { $0 * dpiUnit }
        state.rate = 1000 / (Int(report[frequencyAt]) + 1)
        state.rates = Array(Set(shownRates + [state.rate])).sorted()
        state.buttonCount = buttonCount
        state.buttons = (0..<buttonCount).map { binding(report, buttonsAt + buttonLength * $0) }
        state.light = light(report)
        state.zones[0] = [:]
        return state
    }

    // Solid in black is how libratbag turns the light off.
    static func light(_ report: [UInt8]) -> MouseLight? {
        let color = Int(report[colorAt]) << 16 | Int(report[colorAt + 1]) << 8 | Int(report[colorAt + 2])
        // libratbag caps the duration at 15 s; MouseProtocol.effects' periods run from 1 to 20 s.
        let period = min(20000, max(1000, Int(report[durationAt]) * 1000))
        switch report[effectAt] {
        case 0: return color == 0 ? MouseLight(effect: 0x00, color: 0) : MouseLight(effect: 0x01, color: color)
        case 1: return MouseLight(effect: 0x0A, color: color, period: period)
        case 2: return MouseLight(effect: 0x03, color: color, period: period)
        default: return nil
        }
    }

    // DPI up, down, cycle; mode switch (the next mode, like Cycle profile); DPI shift, default DPI, G-shift.
    static let specials: [UInt8: UInt8] = [0x11: 0x03, 0x12: 0x04, 0x13: 0x05, 0x14: 0x0A, 0x15: 0x07, 0x16: 0x06, 0x17: 0x0B]

    // A G600 button is a mouse code, then a modifier and a key that count when the code is 0. Shown as the HID++ binding that does the
    // same.
    static func binding(_ report: [UInt8], _ at: Int) -> [UInt8] {
        let code = report[at], modifiers = report[at + 1], key = report[at + 2]
        if code >= 0x01 && code <= 0x07 { return [0x80, 0x01, 0x00, UInt8(1 << (code - 1))] }
        if let special = specials[code] { return [0x90, special, 0x00, 0x00] }
        if code == 0 { return modifiers == 0 && key == 0 ? [0x80, 0x00, 0x00, 0x00] : [0x80, 0x02, modifiers, key] }
        return [0xA6, code, modifiers, key]
    }

    private func readOnly() -> GLiteError { .refused("G-Lite only reads the G600 for now") }
    func sendDpi(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings, _ sent: MouseSettings?) throws { throw readOnly() }
    func setLight(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ light: MouseLight) throws { throw readOnly() }
    func setRate(_ hidpp: Hidpp, _ hz: Int) throws { throw readOnly() }
    func setInvert(_ hidpp: Hidpp, _ on: Bool) throws { throw readOnly() }
    func readProfile(_ hidpp: Hidpp, _ state: MouseProtocol.State) throws -> [UInt8] { throw readOnly() }
    func setup(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings) throws { throw readOnly() }
    func save(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ want: MouseSettings) throws { throw readOnly() }
    func restore(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ data: [UInt8]?) throws { throw readOnly() }
    func describe(_ profile: [UInt8]) -> String { "mode \(Int(profile[0]) - Int(G600Mouse.firstModeReport) + 1)" }
    func defaultStage(_ profile: [UInt8]) -> Int { max(0, Int(profile[G600Mouse.defaultLevelAt]) - 1) }
}
