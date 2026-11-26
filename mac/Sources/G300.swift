import Foundation

// The G300 doesn't speak HID++ either (app/G300.cs, docs/G300.md): like the G600, feature reports on its FF80 collection. F0 holds
// the active profile (high nibble) and DPI level (bits 1-2); F3 to F5 one 35-byte report per profile. Layout and save from PeriHub
// (MIT), which saved on a real G300, and libratbag's driver. Nothing changes live: a change applies when the profile report is saved,
// then read back and compared.
final class G300Mouse: MouseDriver {
    static let activeReport: UInt8 = 0xF0, firstProfileReport: UInt8 = 0xF3
    static let profileCount = 3, reportLength = 35, buttonCount = 9
    static let lightAt = 1, rateAt = 2, levelsAt = 3, levelCount = 4, buttonsAt = 8, buttonLength = 3, dpiUnit = 250, maxUnits = 10
    static let defaultFlag: UInt8 = 0x80
    // By rate code: 00 is 1000 Hz.
    static let rateByCode = [1000, 125, 250, 500]

    // Each of red, green and blue is on or off: Off, or Static in one of eight colours.
    static let offAndStatic = MouseProtocol.effects.filter { $0.id == 0x00 || $0.id == 0x01 }
    var effects: [EffectInfo] { G300Mouse.offAndStatic }
    var hasFactory: Bool { false }

    // F0 also gives the level in use (bits 1-2), which isn't shown: the stage on the screen is the profile's default level, the one
    // Save writes, so a save doesn't move the default to whatever level the DPI buttons left the mouse on.
    func read(_ hidpp: Hidpp) throws -> MouseProtocol.State {
        let active = try hidpp.getFeature(G300Mouse.activeReport)
        let profile = Int(active[1] >> 4)
        if profile >= G300Mouse.profileCount { throw GLiteError.io("The G300 reported profile \(profile + 1) of \(G300Mouse.profileCount)") }
        return G300Mouse.decode(try G300Mouse.readReport(hidpp, profile))
    }

    static func readReport(_ hidpp: Hidpp, _ profile: Int) throws -> [UInt8] {
        let report = try hidpp.getFeature(firstProfileReport + UInt8(profile))
        if report.count < reportLength || report[0] != firstProfileReport + UInt8(profile) {
            throw GLiteError.io("The G300 sent an unexpected report for profile \(profile + 1)")
        }
        return Array(report.prefix(reportLength))
    }

    static func decode(_ report: [UInt8]) -> MouseProtocol.State {
        let stages = (0..<levelCount).map { Int(report[levelsAt + $0] & 0x7F) * dpiUnit }
        let stage = defaultStageOf(report)
        let state = MouseProtocol.State()
        // The report id names the profile, for the backups.
        state.saveOnly = true
        state.onboard = true
        state.profile = report
        state.sector = Int(report[0])
        state.sectorSize = reportLength
        state.stages = stages
        state.stage = stage
        state.dpi = stages[stage]
        state.dpis = Array(Set((1...maxUnits).map { $0 * dpiUnit } + stages)).sorted()
        state.rate = Int(report[rateAt]) < rateByCode.count ? rateByCode[Int(report[rateAt])] : 0
        state.rates = rateByCode.sorted()
        state.buttonCount = buttonCount
        state.buttons = (0..<buttonCount).map { binding(report, buttonsAt + buttonLength * $0) }
        state.light = light(report[lightAt])
        state.effects = offAndStatic
        state.zones[0] = [:]
        return state
    }

    static func defaultStageOf(_ report: [UInt8]) -> Int {
        (0..<levelCount).first { report[levelsAt + $0] & defaultFlag != 0 } ?? 0
    }

    static func light(_ bits: UInt8) -> MouseLight {
        if bits & 7 == 0 { return MouseLight(effect: 0x00, color: 0xFFFFFF) }
        return MouseLight(effect: 0x01, color: (bits & 1 != 0 ? 0xFF0000 : 0) | (bits & 2 != 0 ? 0x00FF00 : 0) | (bits & 4 != 0 ? 0x0000FF : 0))
    }

    // The nearest of the eight: a channel is on from half the brightest one, so a dark red stays red. Brightness has no say; black,
    // which has no hue, is white.
    static func colorBits(_ light: MouseLight) -> UInt8 {
        if light.effect == 0 { return 0 }
        let red = light.color >> 16 & 0xFF, green = light.color >> 8 & 0xFF, blue = light.color & 0xFF
        let brightest = max(red, green, blue)
        if brightest == 0 { return 7 }
        return (red * 2 >= brightest ? 1 : 0) | (green * 2 >= brightest ? 2 : 0) | (blue * 2 >= brightest ? 4 : 0)
    }

    // DPI up, down, cycle; next profile; DPI shift; default DPI.
    static let specials: [UInt8: UInt8] = [0x0A: 0x03, 0x0B: 0x04, 0x0C: 0x05, 0x0D: 0x08, 0x0E: 0x07, 0x0F: 0x06]

    // A button is a function, then a modifier and a key that count when the function is 0. Shown as the HID++ binding that does the
    // same; entry turns it back.
    static func binding(_ report: [UInt8], _ at: Int) -> [UInt8] {
        let code = report[at], modifiers = report[at + 1], key = report[at + 2]
        if code >= 0x01 && code <= 0x09 {
            let mask = 1 << (Int(code) - 1)
            return [0x80, 0x01, UInt8(mask >> 8), UInt8(mask & 0xFF)]
        }
        if let special = specials[code] { return [0x90, special, 0x00, 0x00] }
        if code == 0 { return modifiers == 0 && key == 0 ? [0x80, 0x00, 0x00, 0x00] : [0x80, 0x02, modifiers, key] }
        return [0xA6, code, modifiers, key]
    }

    // The G300 entry for a binding, or nil when the G300 has nothing for it.
    static func entry(_ binding: [UInt8]) -> [UInt8]? {
        guard binding.count >= 4 else { return nil }
        if binding[0] == 0x80 && binding[1] == 0x00 { return [0, 0, 0] }
        if binding[0] == 0x80 && binding[1] == 0x01 {
            let mask = Int(binding[2]) << 8 | Int(binding[3])
            return (1...9).first { mask == 1 << ($0 - 1) }.map { [UInt8($0), 0, 0] }
        }
        if binding[0] == 0x80 && binding[1] == 0x02 { return [0x00, binding[2], binding[3]] }
        if binding[0] == 0x90 {
            // Cycle profile does what Next profile does with three profiles.
            let special = binding[1] == 0x0A ? 0x08 : binding[1]
            if let code = specials.first(where: { $0.value == special })?.key { return [code, 0, 0] }
        }
        if binding[0] == 0xA6 { return [binding[1], binding[2], binding[3]] }
        return nil
    }

    // The profile with what's wanted: the stage's DPI, that stage as the default, the rate, the colour and buttons 3 to 9. The left
    // and right buttons keep theirs, as in LGS and PeriHub; the light byte's other bits and the DPI shift stay as read, and so does a
    // button whose binding didn't change.
    static func build(_ old: [UInt8], _ want: MouseSettings) throws -> [UInt8] {
        var built = old
        let stage = want.stage >= 0 && want.stage < levelCount ? want.stage : defaultStageOf(built)
        let units = want.dpi / dpiUnit
        // A level's DPI as read stays, even outside 250 to 2500, so a save that changes something else isn't refused.
        if want.dpi != Int(old[levelsAt + stage] & 0x7F) * dpiUnit {
            if units < 1 || units > maxUnits || units * dpiUnit != want.dpi { throw GLiteError.refused("The G300 takes 250 to 2500 DPI in steps of 250") }
            built[levelsAt + stage] = UInt8(units)
        }
        for i in 0..<levelCount { built[levelsAt + i] = built[levelsAt + i] & 0x7F | (i == stage ? defaultFlag : 0) }
        if want.rate > 0 {
            guard let code = rateByCode.firstIndex(of: want.rate) else { throw GLiteError.refused("The G300 takes 125, 250, 500 or 1000 Hz") }
            built[rateAt] = UInt8(code)
        }
        if let light = want.light { built[lightAt] = built[lightAt] & ~7 | colorBits(light) }
        if let buttons = want.buttons {
            for i in 0..<min(buttonCount, buttons.count) {
                let at = buttonsAt + buttonLength * i
                if binding(old, at) == buttons[i] { continue }
                if i < 2 { throw GLiteError.refused("The G300's left and right buttons keep what they do") }
                guard let entry = entry(buttons[i]) else { throw GLiteError.refused("Button \(i + 1): the G300 can't do that") }
                built.replaceSubrange(at..<at + buttonLength, with: entry)
            }
        }
        return built
    }

    // One write of the whole report, as libratbag and PeriHub do, then read back: PeriHub waits half a second, and reads a few times
    // since the mouse is slow to take it.
    static func write(_ hidpp: Hidpp, _ report: [UInt8]) throws {
        if report.count != reportLength || report[0] < firstProfileReport || report[0] >= firstProfileReport + UInt8(profileCount) {
            throw GLiteError.refused("Not a G300 profile")
        }
        try hidpp.setFeature(report)
        for attempt in 0..<3 {
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.5 : 0.1)
            if try readReport(hidpp, Int(report[0] - firstProfileReport)) == report { return }
        }
        throw GLiteError.io("The G300 reads back something else than what was saved")
    }

    func sendDpi(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings, _ sent: MouseSettings?) throws {}
    func setLight(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ light: MouseLight) throws {}
    func setRate(_ hidpp: Hidpp, _ hz: Int) throws {}
    func setInvert(_ hidpp: Hidpp, _ on: Bool) throws { throw GLiteError.notSupported("The G300 can't invert its wheel") }
    func readProfile(_ hidpp: Hidpp, _ state: MouseProtocol.State) throws -> [UInt8] {
        try G300Mouse.readReport(hidpp, Int(state.profile![0] - G300Mouse.firstProfileReport))
    }
    func setup(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings) throws { throw GLiteError.refused("The G300 needs no setup") }
    // The mouse's profile button may have moved it to another profile since the screen read this one, and Save is for the one in use.
    func save(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ want: MouseSettings) throws {
        let active = Int(try hidpp.getFeature(G300Mouse.activeReport)[1] >> 4)
        if Int(G300Mouse.firstProfileReport) + active != Int(now[0]) {
            throw GLiteError.refused("The G300 is on profile \(active + 1) now, not the one shown: nothing was saved")
        }
        try G300Mouse.write(hidpp, try G300Mouse.build(now, want))
    }
    func restore(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ data: [UInt8]?) throws {
        guard let data = data else { throw GLiteError.refused("The G300 has no factory profile to restore") }
        try G300Mouse.write(hidpp, data)
    }
    func describe(_ profile: [UInt8]) -> String { "profile \(Int(profile[0]) - Int(G300Mouse.firstProfileReport) + 1)" }
    func defaultStage(_ profile: [UInt8]) -> Int { G300Mouse.defaultStageOf(profile) }
}
