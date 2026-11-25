import Foundation

// What the mouse screen needs from a mouse (app/Mouse.cs, IMouse): HidppMouse for HID++ 2.0, G9xMouse and G5Mouse for HID++ 1.0.
protocol MouseDriver: AnyObject {
    var effects: [EffectInfo] { get }
    var hasFactory: Bool { get }
    func read(_ hidpp: Hidpp) throws -> MouseProtocol.State
    func sendDpi(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings, _ sent: MouseSettings?) throws
    func setLight(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ light: MouseLight) throws
    func setRate(_ hidpp: Hidpp, _ hz: Int) throws
    func setInvert(_ hidpp: Hidpp, _ on: Bool) throws
    func readProfile(_ hidpp: Hidpp, _ state: MouseProtocol.State) throws -> [UInt8]
    func setup(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings) throws
    func save(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ want: MouseSettings) throws
    func restore(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ data: [UInt8]?) throws
    func describe(_ profile: [UInt8]) -> String
    func defaultStage(_ profile: [UInt8]) -> Int
}

// The mice that share the G9x's profile page and registers (app/G9x.cs). From cvuchener's hidpp (GPL-3.0, facts only): the G500 has
// the G9x's sensor (0x63 in units of 400/17 DPI, 200–5700), the G500s another (units of 50 DPI, 200–8200), and neither has the G9x's
// colour light (0x57). The G700 and G700s have their sensors but another profile layout and memory commands nobody has confirmed: live
// DPI and rate only, no pages read or written.
final class G9xModel {
    static let g9x = G9xModel(17, 400, 5700, light: true, pages: true)
    static let g500 = G9xModel(17, 400, 5700, light: false, pages: true)
    static let g500s = G9xModel(1, 50, 8200, light: false, pages: true)
    static let g700 = G9xModel(17, 400, 5700, light: false, pages: false)
    static let g700s = G9xModel(1, 50, 8200, light: false, pages: false)

    private let rawPerStep: Int, dpiPerStep: Int
    let max: Int
    let light: Bool, pages: Bool

    private init(_ rawPerStep: Int, _ dpiPerStep: Int, _ max: Int, light: Bool, pages: Bool) {
        self.rawPerStep = rawPerStep; self.dpiPerStep = dpiPerStep; self.max = max; self.light = light; self.pages = pages
    }

    func dpi(_ raw: Int) -> Int { Int((Double(raw) * Double(dpiPerStep) / Double(rawPerStep) / 50).rounded()) * 50 }
    func dpiToRaw(_ dpi: Int) -> Int { Int((Double(Swift.max(200, Swift.min(max, dpi))) * Double(rawPerStep) / Double(dpiPerStep)).rounded()) }
    func dpis() -> [Int] { (0...((max - 200) / 50)).map { 200 + 50 * $0 } }
}

enum G9xRegisters {
    static let effects = MouseProtocol.effects.filter { $0.id <= 0x01 }
    static let rates = [125, 200, 250, 333, 500, 1000]

    // A profile page (docs/G9x.md): the LED colour, five 6-byte stages (X and Y, big-endian, then the LED nibbles), the default stage,
    // the report interval in ms. The CRC is in the last two bytes.
    static let pageSize = 512, colorAt = 0x00, stagesAt = 0x04, stageCount = 5, stageLength = 6, defaultStageAt = 0x23, reportIntervalAt = 0x26

    static func valid(_ page: [UInt8]?) -> Bool { page?.count == pageSize && MouseProtocol.valid(page) }

    static func readPage(_ device: Hidpp, _ pageNumber: Int) throws -> [UInt8] {
        var page: [UInt8] = []
        for offset in stride(from: 0, to: pageSize, by: 16) {
            page += try device.register(0x83, 0xA2, [UInt8(pageNumber), UInt8(offset / 2)]).prefix(16)
        }
        return page
    }

    // The directory's entries are 3 bytes (page, offset in words, LEDs), ended by one 0xFF; past it page 1 holds macros and names.
    static func entry(_ directory: [UInt8], _ index: Int) -> Int {
        var entry = 0
        while entry * 3 + 2 < directory.count - 2 && directory[entry * 3] != 0xFF {
            if entry == index { return Int(directory[entry * 3]) }
            entry += 1
        }
        return 0xFF
    }

    static func stagesOf(_ page: [UInt8], _ model: G9xModel) -> [Int] {
        Array((0..<stageCount).map { Int(page[stagesAt + stageLength * $0]) << 8 | Int(page[stagesAt + 1 + stageLength * $0]) }
            .prefix { $0 != 0 && $0 != 0xFFFF }).map(model.dpi)
    }

    static func light(_ color: [UInt8]) -> MouseLight {
        let brightest = Int(max(color[0], color[1], color[2]))
        if brightest == 0 { return MouseLight(effect: 0x00) }
        return MouseLight(effect: 0x01,
                          color: (Int(color[0]) * 255 / brightest) << 16 | (Int(color[1]) * 255 / brightest) << 8 | Int(color[2]) * 255 / brightest,
                          bright: max(1, (brightest * 100 + 127) / 255))
    }

    static func read(_ device: Hidpp, _ model: G9xModel) throws -> MouseProtocol.State {
        let state = MouseProtocol.State()
        state.flash = model.pages
        state.effects = effects
        state.rates = rates
        state.dpis = model.dpis()
        let resolution = try device.register(0x83, 0x63)
        state.dpi = model.dpi(Int(resolution[0]) | Int(resolution[1]) << 8)
        let interval = Int(try device.register(0x81, 0x64)[0])
        state.rate = interval > 0 ? 1000 / interval : 0
        if model.light {
            state.light = light(Array(try device.register(0x81, 0x57).prefix(3)))
            state.zones[0] = [0x00: 0, 0x01: 1]
        }
        if model.pages {
            do {
                let current = try device.register(0x81, 0x0F)
                let directory = current[0] == 0 && current[1] < 16 ? try readPage(device, 1) : nil
                let pageNumber = directory.map { valid($0) ? entry($0, Int(current[1])) : 0xFF } ?? 0xFF
                if pageNumber >= 2 && pageNumber < 32 {
                    let profile = try readPage(device, pageNumber)
                    state.sector = pageNumber
                    state.sectorSize = pageSize
                    state.current = [current[1]]
                    state.profile = profile
                    state.profileOk = valid(profile)
                    if state.profileOk { state.stages = stagesOf(profile, model) }
                }
            } catch GLiteError.hidpp {}
        }
        state.stage = state.stages.firstIndex(of: state.dpi) ?? -1
        return state
    }

    static func setDpi(_ device: Hidpp, _ dpi: Int, _ model: G9xModel) throws {
        let raw = model.dpiToRaw(dpi)
        var resolution = [UInt8](repeating: 0, count: 16)
        resolution.replaceSubrange(0..<6, with: try device.register(0x83, 0x63).prefix(6))
        resolution[0] = UInt8(raw & 0xFF); resolution[2] = resolution[0]
        resolution[1] = UInt8(raw >> 8 & 0xFF); resolution[3] = resolution[1]
        try device.register(0x82, 0x63, resolution)
    }

    static func setRate(_ device: Hidpp, _ hz: Int) throws { try device.register(0x80, 0x64, [UInt8(1000 / hz)]) }

    static func setLight(_ device: Hidpp, _ light: MouseLight) throws {
        let color = light.effect == 0x01 ? Array(MouseProtocol.encode(light).prefix(3)) : [0, 0, 0]
        try device.register(0x80, 0x57, color)
    }

    static func describe(_ page: [UInt8], _ model: G9xModel) -> String {
        if !valid(page) { return "damaged, can't be restored" }
        let stages = stagesOf(page, model), defaultStage = Int(page[defaultStageAt]), interval = Int(page[reportIntervalAt])
        let dpi = defaultStage < stages.count ? "\(stages[defaultStage]) DPI" : "DPI stages"
        return interval > 0 ? dpi + ", \(1000 / interval) Hz" : dpi
    }

    static func build(_ old: [UInt8], _ want: MouseSettings, _ hz: Int, _ model: G9xModel) throws -> [UInt8] {
        var page = old
        let stages = stagesOf(page, model)
        if stages.isEmpty { throw GLiteError.refused("The profile on the mouse has no DPI stages, not touching it") }
        var stage = want.stage >= 0 && want.stage < stages.count ? want.stage : stages.firstIndex(of: want.dpi) ?? -1
        if stage < 0 { stage = min(Int(page[defaultStageAt]), stages.count - 1) }
        let raw = model.dpiToRaw(want.dpi), stageAt = stagesAt + stageLength * stage
        page[stageAt] = UInt8(raw >> 8 & 0xFF); page[stageAt + 2] = page[stageAt]
        page[stageAt + 1] = UInt8(raw & 0xFF); page[stageAt + 3] = page[stageAt + 1]
        page[defaultStageAt] = UInt8(stage)
        if hz > 0 { page[reportIntervalAt] = UInt8(1000 / hz) }
        if let light = want.light, model.light {
            let color = light.effect == 0x01 ? Array(MouseProtocol.encode(light).prefix(3)) : [0, 0, 0]
            page.replaceSubrange(colorAt..<colorAt + 3, with: color)
        }
        MouseProtocol.writeChecksum(&page)
        return page
    }

    // previous: the page as it was before (backed up), written back if the write fails after the erase. Never pages 0 (RAM) or 1
    // (the directory): state.writable checks the page.
    static func store(_ device: Hidpp, _ state: MouseProtocol.State, _ page: [UInt8], _ previous: [UInt8]?) throws {
        if !state.flash || !state.writable { throw GLiteError.refused("Saving isn't supported on this mouse") }
        if !valid(page) { throw GLiteError.refused("Refusing to write a profile with a bad checksum") }
        let pageNumber = UInt8(state.sector), current = state.current?.first ?? 0
        try device.register(0x80, 0x0F, [0xFF])
        var erased = false
        do {
            try writePage(device, pageNumber, page) { erased = true }
        } catch {
            if !erased {
                _ = try? device.register(0x80, 0x0F, [0x00, current])
                throw error
            }
            // The page may be half written, and the mouse is on its factory profile (0x0F FF): put the page back as it was, then load it.
            do {
                guard let previous = previous, valid(previous) else { throw GLiteError.refused("no good copy to put back") }
                try writePage(device, pageNumber, previous) {}
                try device.register(0x80, 0x0F, [0x00, current])
            } catch {
                throw GLiteError.io("Saving failed halfway (\(error)). The mouse is on its factory profile: restore the backup from Backups, "
                                    + "or replug it and save again.")
            }
            throw GLiteError.io("Saving failed (\(error)), so the profile as it was is back on the mouse.")
        }
        try device.register(0x80, 0x0F, [0x00, current])
        if try readPage(device, Int(pageNumber)) != page { throw GLiteError.io("The profile on the mouse didn't read back the same after saving") }
    }

    private static func writePage(_ device: Hidpp, _ pageNumber: UInt8, _ page: [UInt8], erasing: () -> Void) throws {
        for half in 0..<2 {
            try upload(device, Array(page[pageSize / 2 * half..<pageSize / 2 * (half + 1)]))
            if half == 0 {
                erasing()
                try device.register(0x82, 0xA0, [0x02, 0, 0, 0, 0, 0, pageNumber, 0, 0, 0, 0x01, 0x00])
            }
            try device.register(0x82, 0xA0, [0x03, 0, 0, 0, 0, 0, pageNumber, UInt8(0x80 * half), 0, 0, 0x01, 0x00])
        }
    }

    private static func upload(_ device: Hidpp, _ data: [UInt8]) throws {
        try device.register(0x80, 0xA1, [0x01])
        var first: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, UInt8(data.count >> 8), UInt8(data.count & 0xFF), 0x00, 0x00]
        first += data.prefix(7)
        try device.upload(0x92, 0, first)
        var sequence: UInt8 = 1
        for offset in stride(from: 7, to: data.count, by: 16) {
            var chunk = [UInt8](repeating: 0xFF, count: 16)
            for i in 0..<min(16, data.count - offset) { chunk[i] = data[offset + i] }
            try device.upload(0x93, sequence, chunk)
            sequence += 1
        }
    }
}

final class G9xMouse: MouseDriver {
    let model: G9xModel
    init(_ model: G9xModel) { self.model = model }

    var effects: [EffectInfo] { G9xRegisters.effects }
    var hasFactory: Bool { false }
    func read(_ hidpp: Hidpp) throws -> MouseProtocol.State { try G9xRegisters.read(hidpp, model) }
    func sendDpi(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings, _ sent: MouseSettings?) throws {
        if sent?.dpi != want.dpi { try G9xRegisters.setDpi(hidpp, want.dpi, model) }
    }
    func setLight(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ light: MouseLight) throws {
        if !model.light { throw GLiteError.refused("This mouse has no colour light") }
        try G9xRegisters.setLight(hidpp, light)
    }
    func setRate(_ hidpp: Hidpp, _ hz: Int) throws { try G9xRegisters.setRate(hidpp, hz) }
    func setInvert(_ hidpp: Hidpp, _ on: Bool) throws { throw GLiteError.refused("This mouse can't invert its wheel") }
    func readProfile(_ hidpp: Hidpp, _ state: MouseProtocol.State) throws -> [UInt8] { try G9xRegisters.readPage(hidpp, state.sector) }
    func setup(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings) throws {
        throw GLiteError.refused("Saving isn't supported on this mouse")
    }
    func save(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ want: MouseSettings) throws {
        try G9xRegisters.store(hidpp, state, try G9xRegisters.build(now, want, state.rate, model), now)
    }
    func restore(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ data: [UInt8]?) throws {
        guard let data = data else { throw GLiteError.refused("G-Lite can't restore the factory profile on this mouse") }
        try G9xRegisters.store(hidpp, state, data, now)
    }
    func describe(_ profile: [UInt8]) -> String { G9xRegisters.describe(profile, model) }
    func defaultStage(_ profile: [UInt8]) -> Int { Int(profile[G9xRegisters.defaultStageAt]) }
}

// The G5 and G9: short register 0x63 holds 0x80 + an index into the mouse's DPI list, 0x64 the report interval in ms. From cvuchener's
// g500 docs and hidpp's sensors (GPL-3.0, facts only). Live only: the G5 has no profile memory, and nobody has confirmed how a G9
// writes its pages.
final class G5Mouse: MouseDriver {
    // The G9's index 0 is "off", so its 200 DPI is index 1.
    static func g5() -> G5Mouse { G5Mouse([400, 800, 1600, 2000], 0) }
    static func g9() -> G5Mouse { G5Mouse((1...16).map { 200 * $0 }, 1) }

    let dpis: [Int]
    private let firstIndex: Int
    private init(_ dpis: [Int], _ firstIndex: Int) { self.dpis = dpis; self.firstIndex = firstIndex }

    func dpi(_ raw: Int) -> Int {
        let index = (raw & 0x7F) - firstIndex
        return raw & 0x80 != 0 && index >= 0 && index < dpis.count ? dpis[index] : 0
    }

    func dpiToRaw(_ dpi: Int) throws -> Int {
        guard let index = dpis.firstIndex(of: dpi) else { throw GLiteError.refused("This mouse has no \(dpi) DPI setting") }
        return 0x80 | (index + firstIndex)
    }

    var effects: [EffectInfo] { G9xRegisters.effects }
    var hasFactory: Bool { false }
    func read(_ hidpp: Hidpp) throws -> MouseProtocol.State {
        let state = MouseProtocol.State()
        state.effects = G9xRegisters.effects
        state.rates = G9xRegisters.rates
        state.dpis = dpis
        state.dpi = dpi(Int(try hidpp.register(0x81, 0x63)[0]))
        let interval = Int(try hidpp.register(0x81, 0x64)[0])
        state.rate = interval > 0 ? 1000 / interval : 0
        return state
    }
    func sendDpi(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings, _ sent: MouseSettings?) throws {
        if sent?.dpi != want.dpi { try hidpp.register(0x80, 0x63, [UInt8(try dpiToRaw(want.dpi))]) }
    }
    func setLight(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ light: MouseLight) throws {
        throw GLiteError.refused("G-Lite can't set this mouse's light yet")
    }
    func setRate(_ hidpp: Hidpp, _ hz: Int) throws { try G9xRegisters.setRate(hidpp, hz) }
    func setInvert(_ hidpp: Hidpp, _ on: Bool) throws { throw GLiteError.refused("This mouse can't invert its wheel") }
    func readProfile(_ hidpp: Hidpp, _ state: MouseProtocol.State) throws -> [UInt8] { throw GLiteError.refused("This mouse has no profile memory") }
    func setup(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ want: MouseSettings) throws { throw GLiteError.refused("Saving isn't supported on this mouse") }
    func save(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ want: MouseSettings) throws {
        throw GLiteError.refused("Saving isn't supported on this mouse")
    }
    func restore(_ hidpp: Hidpp, _ state: MouseProtocol.State, _ now: [UInt8], _ data: [UInt8]?) throws {
        throw GLiteError.refused("Saving isn't supported on this mouse")
    }
    func describe(_ profile: [UInt8]) -> String { "" }
    func defaultStage(_ profile: [UInt8]) -> Int { 0 }
}
