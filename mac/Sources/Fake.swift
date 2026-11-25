import Foundation

// An in-memory G515 for --demo and the self-test (app/Fake.cs, FakeHidpp).
final class FakeG515: Hidpp {
    static var latency = 0.005
    static let index: [Int: UInt8] = [0x8071: 9, 0x8040: 14, 0x8101: 15, 0x8081: 16, 0x4540: 17, 0x1004: 18, 0x1B10: 11, 0x4523: 12]
    // The control list (0x1B10) of an owner's G515 TKL (app/Fake.cs), and the Game mode bitmap 0x4523 fn 0 sets.
    static let controlList = Backups.bytes("014C00EF00F100F300F5014E0150004E010B014401460148014A01420153015600F600F000F200F4014D014F004C004D0143014501470149014B0158017E0116010C01380133013A012A0131015B0118010D013401270129012C015C0169011701320126013501360130015A011E011A012201250128012B012D015D015501190000010E013B01240123012E015F017C010F018B0161018D004F00EC0152011B0000016A01390137012F0160015E0115018C0180017F00340114015100EB000000000000015900000000000000000000000000000000000000000000000000000000018A01850000000000000000000000000000000000000000000000000000")
    var gameBitmap = [UInt8](repeating: 0, count: 16)
    static let effectIds: [UInt8] = [0x00, 0x01, 0x0A, 0x15, 0x16, 0x17]
    var flash: [Int: [UInt8]] = [
        0x0101: Backups.bytes("0101003c012cffffffffffffffffffffffffffffffffffffffffffffffff18ff008180aaff00006400000000000000000000000019ff008180aaff0000640000000000000000000000000300000000000000000010000104000200ffffffffffffffff"),
        0x0100: Backups.bytes("5e380925010181014063996dec0101ff"),
    ]
    var live = [UInt8](repeating: 0, count: 12)
    var battery = 82
    // 0x8081: the colours by lighting id, the frames fn 7 showed, and how many times fn 7 answers busy first (the G515 during Rain).
    var keys: [Int: Int] = [:]
    var frames = 0, busyFrames = 0
    private var buffer: [UInt8] = []
    private var brightness = 100, mode = 0x03
    private var control: [UInt8] = [0, 0]

    init() { super.init(fake: 1) }

    static func found() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|g515"; device.name = "G515 LIGHTSPEED TKL"; device.kind = "keyboard"; device.link = "LIGHTSPEED"
        device.index = 1; device.battery = 82; device.models = "USB C358, LIGHTSPEED 40B4"
        device.features = [0x0001, 0x0003, 0x0005, 0x1004, 0x1B10, 0x4523, 0x4540, 0x8040, 0x8071, 0x8081, 0x8101]
        return device
    }

    static func controls(_ fn: Int, _ padded: [UInt8], _ reply: inout [UInt8]) {
        if fn == 0 { reply[0] = UInt8(controlList.count / 2) }
        if fn == 1 { for i in 0..<16 where Int(padded[0]) * 2 + i < controlList.count { reply[i] = controlList[Int(padded[0]) * 2 + i] } }
    }

    override func send(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        if FakeG515.latency > 0 { Thread.sleep(forTimeInterval: FakeG515.latency) }
        var reply = [UInt8](repeating: 0, count: 16)
        let padded = parameters + [UInt8](repeating: 0, count: 16)
        func readUInt16(_ at: Int) -> Int { Int(padded[at]) << 8 | Int(padded[at + 1]) }
        let index = FakeG515.index
        if featureIndex == 0 {
            reply[0] = index[readUInt16(0)] ?? 0
        } else if featureIndex == index[0x1B10] {
            FakeG515.controls(fn, padded, &reply)
        } else if featureIndex == index[0x4523] {
            if fn == 0 { gameBitmap = Array(padded.prefix(16)) }
        } else if featureIndex == index[0x8040] {
            if fn == 1 { reply[0] = UInt8(brightness >> 8); reply[1] = UInt8(brightness & 0xFF) }
            if fn == 2 { brightness = readUInt16(0) }
        } else if featureIndex == index[0x8071] {
            if fn == 0 {
                if padded[0] > 0 || Int(padded[1]) >= FakeG515.effectIds.count { throw GLiteError.hidpp(2, "invalid argument") }
                reply[1] = padded[1]; reply[3] = FakeG515.effectIds[Int(padded[1])]
                if reply[3] == 0x16 { reply[4] = 0xDC; reply[5] = 0xE1 }
            }
            if fn == 1 { live = Array(padded.prefix(12)) }
            if fn == 5 && padded[0] == 1 { control = [padded[1], padded[2]] }
            if fn == 5 { reply[1] = control[0]; reply[2] = control[1] }
        } else if featureIndex == index[0x8081] {
            if fn == 0 {
                reply[1] = padded[1]
                let base = Int(padded[1]) * 112
                for id in base..<base + 112 where (0x01...0x4F).contains(id) || (0x61...0x6F).contains(id) {
                    reply[2 + (id - base) / 8] |= UInt8(1 << (id % 8))
                }
            }
            if fn == 6 {
                for i in 3..<16 where i < parameters.count {
                    if padded[i] == 0 && i > 3 { break }
                    keys[Int(padded[i])] = Int(padded[0]) << 16 | Int(padded[1]) << 8 | Int(padded[2])
                }
            }
            if fn == 1 {
                for at in stride(from: 0, to: 16, by: 4) where at + 3 < parameters.count {
                    keys[Int(padded[at])] = Int(padded[at + 1]) << 16 | Int(padded[at + 2]) << 8 | Int(padded[at + 3])
                }
            }
            if fn == 7 {
                if busyFrames > 0 { busyFrames -= 1; throw GLiteError.hidpp(8, "busy") }
                frames += 1
            }
        } else if featureIndex == index[0x4540] {
            reply[0] = 0x0D
        } else if featureIndex == index[0x1004] {
            reply[0] = UInt8(battery)
        } else if featureIndex == index[0x8101] {
            switch fn {
            case 2: buffer.removeAll()
            case 3: buffer += padded.prefix(16)
            case 6:
                if padded[0] & 1 != 0 { mode = Int(padded[0] >> 1 & 1) }
                reply[0] = UInt8(mode); reply[2] = 1
            case 7: flash[readUInt16(0)] = Array(buffer.prefix(readUInt16(2)))
            case 8:
                guard let file = flash[readUInt16(0)] else { throw GLiteError.hidpp(4, "HID++ error 0x04") }
                buffer = file
            case 0xC:
                let part = Array(buffer.dropFirst(readUInt16(0)).prefix(16))
                reply.replaceSubrange(0..<part.count, with: part)
            default: break
            }
        }
        return reply
    }
}

// An MX Master 3S or MX Keys S, depending on the features its FoundDevice lists, for --demo and the self-test (app/Fake.cs,
// FakeOther).
final class FakeOther: Hidpp {
    static let index: [Int: UInt8] = [0x8040: 2, 0x2201: 3, 0x2110: 4, 0x2121: 5, 0x2150: 6, 0x1982: 7, 0x1814: 8, 0x1815: 9]
    static let names = ["Desk PC", "MacBook"]
    var bright = 100, dpi = 1000, shift = 10, wheel = 0, thumbInvert = 0, level = 3, host = 0
    var refuseDpi = false
    // An MX Keys S's 0x1982 fn 0, from its owner's report: manual, level 3, fading after 30 s, 30 s and 300 s.
    var backlight: [UInt8] = [0x01, 0x1D, 0x3D, 0x03, 0x00, 0x03, 0x06, 0x00, 0x06, 0x00, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00]

    init() { super.init(fake: 0xFF) }

    static func mxMaster() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|mxmaster"; device.name = "MX Master 3S"; device.kind = "mouse"; device.link = "Bluetooth"; device.battery = 64
        device.features = [0x0001, 0x0003, 0x0005, 0x1004, 0x1814, 0x1815, 0x2110, 0x2121, 0x2150, 0x2201]
        return device
    }

    static func mxKeys() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|mxkeys"; device.name = "MX Keys S"; device.kind = "keyboard"; device.link = "Bluetooth"; device.battery = 90
        device.features = [0x0001, 0x0003, 0x0005, 0x1004, 0x1814, 0x1815, 0x1982]
        return device
    }

    override func write(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        if featureIndex == FakeOther.index[0x1814] && fn == 1 { host = Int(parameters[0]) }
        return []
    }

    override func send(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        if FakeG515.latency > 0 { Thread.sleep(forTimeInterval: FakeG515.latency) }
        var reply = [UInt8](repeating: 0, count: 16)
        let padded = parameters + [UInt8](repeating: 0, count: 16)
        if featureIndex == 0 { reply[0] = FakeOther.index[Int(padded[0]) << 8 | Int(padded[1])] ?? 0; return reply }
        guard let id = FakeOther.index.first(where: { $0.value == featureIndex })?.key else { return reply }
        switch id {
        case 0x8040:
            if fn == 0 { reply[1] = 100; reply[2] = 0x65; reply[3] = 0x10 }
            if fn == 1 { reply[0] = UInt8(bright >> 8); reply[1] = UInt8(bright & 0xFF) }
            if fn == 2 { bright = Int(padded[0]) << 8 | Int(padded[1]) }
        case 0x2201:
            if fn == 1 { reply.replaceSubrange(1...6, with: [0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40]) }
            if fn == 2 { reply[1] = UInt8(dpi >> 8); reply[2] = UInt8(dpi & 0xFF); reply[3] = 0x03; reply[4] = 0xE8 }
            if fn == 3 && refuseDpi { throw GLiteError.hidpp(5, "refused") }
            if fn == 3 { dpi = Int(padded[1]) << 8 | Int(padded[2]) }
        case 0x2110:
            if fn == 1 && padded[1] != 0 { shift = Int(padded[1]) }
            reply[0] = 2; reply[1] = UInt8(shift); reply[2] = 10
        case 0x2121:
            if fn == 0 { reply[0] = 15; reply[1] = 0x0C; reply[2] = 24; reply[3] = 26 }
            if fn == 2 { wheel = Int(padded[0]) }
            if fn == 1 || fn == 2 { reply[0] = UInt8(wheel) }
        case 0x2150:
            if fn == 2 { thumbInvert = Int(padded[1] & 1) }
            if fn == 1 || fn == 2 { reply[1] = UInt8(thumbInvert) }
        case 0x1982:
            if fn == 0 { reply = backlight }
            if fn == 1 {
                backlight[0] = padded[0]; backlight[1] = padded[1]; backlight[5] = padded[3]
                backlight.replaceSubrange(6..<12, with: padded[4..<10])
                if padded[1] >> 3 & 3 == 3 { level = Int(padded[3]) }
            }
            if fn == 2 {
                reply[0] = 8; reply[1] = UInt8(level)
                reply[2] = backlight[0] & 1 == 0 ? 0 : backlight[1] >> 3 & 3 == 1 ? 2 : 5
            }
        case 0x1814:
            if fn == 0 { reply[0] = 3; reply[1] = UInt8(host); reply[2] = 1 }
        case 0x1815:
            let host = Int(padded[0]), known = host < FakeOther.names.count
            if fn == 0 { reply[0] = 0x1F; reply[1] = 0x0E; reply[2] = 3; reply[3] = 0xFF }
            if fn == 1 {
                reply[0] = padded[0]; reply[1] = known ? 1 : 0; reply[2] = 5
                reply[4] = UInt8(known ? FakeOther.names[host].utf8.count : 0); reply[5] = 32
            }
            if fn == 3 && known {
                reply[0] = padded[0]; reply[1] = padded[1]
                let name = Array(FakeOther.names[host].utf8)
                for offset in 0..<14 where Int(padded[1]) + offset < name.count { reply[2 + offset] = name[Int(padded[1]) + offset] }
            }
        default: break
        }
        return reply
    }
}

// An in-memory mouse for --demo and the self-test (app/Fake.cs, FakeMouse): a format 3 mouse by default, with variants built from
// real mice's bytes.
final class FakeMouse: Hidpp {
    var dpi = 1600, stage = 2, reloads = 0, rate = 1, zoneCount = 2
    var info = "0103010501081000ff0a04"
    var wheel = false, wide = false, hiddenLight = false
    var wheelMode: UInt8 = 0
    var zones: [[UInt8]] = [[UInt8](repeating: 0, count: 12), [UInt8](repeating: 0, count: 12)]
    var sectors: [Int: [UInt8]] = [:]
    static let ids: [UInt8] = [0x00, 0x01, 0x03, 0x0A]
    private var pending: [UInt8] = []
    private var writeTo = 0, writeLength = 0, current = 1

    init(fresh: Bool = false) {
        super.init(fake: 1)
        var rom = [UInt8](repeating: 0xFF, count: 255)
        rom[0] = 1; rom[1] = 2; rom[2] = 2
        for (i, value) in [400, 800, 1600, 3200, 6400].enumerated() { rom[3 + 2 * i] = UInt8(value & 0xFF); rom[4 + 2 * i] = UInt8(value >> 8) }
        let cycle = Backups.bytes("0300000000001f40000000")
        rom.replaceSubrange(0xD0..<0xDB, with: cycle)
        rom.replaceSubrange(0xDB..<0xE6, with: cycle)
        var user = rom
        let name = Array("Default".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        user.replaceSubrange(0xA0..<0xA0 + name.count, with: name)
        MouseProtocol.writeChecksum(&user)
        sectors[0x0101] = rom
        sectors[0x0001] = user
        sectors[0x0000] = Backups.bytes("00010100") + [UInt8](repeating: 0xFF, count: 251)
        if !fresh { return }
        sectors[0x0000] = nil
        sectors[0x0001] = nil
        current = 0x0101
    }

    private func bind(_ bindings: [String], _ sectorIds: [Int], at: Int = 0x20) {
        for sector in sectorIds {
            for (i, binding) in bindings.enumerated() { sectors[sector]!.replaceSubrange(at + 4 * i..<at + 4 * i + 4, with: Backups.bytes(binding)) }
        }
    }

    static func g502() -> FakeMouse {
        let mouse = FakeMouse()
        mouse.info = "01030105010B1000ff0a04"
        mouse.wheel = true
        mouse.bind(["80010001", "80010002", "80010004", "80010008", "80010010", "90070000", "90040000", "90030000", "90080000",
                    "90020000", "90010000"], [0x0001, 0x0101])
        MouseProtocol.writeChecksum(&mouse.sectors[0x0001]!)
        return mouse
    }

    // A G502 HERO that has only run its factory profile: the 0x8100 fn 0 reply, the factory bindings (specials end FF FF) and the
    // directory of zeros are from g502-hub's docs/protocol.md and Solaar #2313.
    static func hero() -> FakeMouse {
        let mouse = FakeMouse(fresh: true)
        mouse.info = "01020105050B1000FF0A01"
        mouse.bind(["80010001", "80010002", "80010004", "80010008", "80010010", "9007FFFF", "9004FFFF", "9003FFFF", "900AFFFF",
                    "9002FFFF", "9001FFFF"], [0x0101])
        mouse.sectors[0x0000] = [UInt8](repeating: 0, count: 255)
        return mouse
    }

    // An original PRO X SUPERLIGHT: profile format 4, five buttons, and 0x8070 flagged hidden (Solaar's PRO X Wireless 4093 report).
    static func superlight() -> FakeMouse {
        let mouse = FakeMouse()
        mouse.info = "0104010501051000ff0a04"; mouse.hiddenLight = true; mouse.zoneCount = 1
        mouse.bind(["80010001", "80010002", "80010004", "80010008", "80010010"], [0x0001, 0x0101])
        MouseProtocol.writeChecksum(&mouse.sectors[0x0001]!)
        return mouse
    }

    // A PRO X SUPERLIGHT 2: Featherweight's 0x8100 fn 0 reply (format 7, 255-byte sectors, 5 buttons), docs/newer-mice.md.
    static func proX2() -> FakeMouse { wider("8001000180010002800100048001000880010010") }

    // A PRO X 2 DEX, the same format; the thumb buttons swapped to show the bindings come from the profile.
    static func dex() -> FakeMouse { wider("8001000180010002800100048001001080010008") }

    private static func wider(_ buttons: String) -> FakeMouse {
        let mouse = FakeMouse()
        mouse.wide = true; mouse.zoneCount = 0; mouse.info = "0107010501051000ff0a04"; mouse.dpi = 800; mouse.stage = 1; mouse.rate = 3
        var profile = [UInt8](repeating: 0xFF, count: 255)
        profile.replaceSubrange(0..<29, with: Backups.bytes("03030100" + "9001900102" + "2003200302" + "4006400602" + "800C800C02" + "0000000000"))
        profile.replaceSubrange(0x30..<0x44, with: Backups.bytes(buttons))
        MouseProtocol.writeChecksum(&profile)
        mouse.sectors[0x0001] = profile
        mouse.sectors[0x0101] = profile
        return mouse
    }

    // A G502 X PLUS: profile format 5 with the G502 X LIGHTSPEED's counts, stages and factory bindings (docs/G502X.md), a write counter
    // at 0x12 and lights on 0x8071 only, so no 0x8070 zones (Solaar's G502 X PLUS 4099 report).
    static func g502XPlus() -> FakeMouse {
        let mouse = FakeMouse()
        mouse.info = "01050105020B1000ff0a04"; mouse.wheel = true; mouse.zoneCount = 0; mouse.dpi = 1600; mouse.stage = 2
        mouse.bind(["80010001", "80010002", "80010004", "80010008", "90070000", "80010010", "90010000", "90020000", "900A0000",
                    "90030000", "90040000"], [0x0001, 0x0101])
        for sector in [0x0001, 0x0101] {
            for (i, value) in [800, 1200, 1600, 2400, 3200].enumerated() {
                mouse.sectors[sector]![3 + 2 * i] = UInt8(value & 0xFF); mouse.sectors[sector]![4 + 2 * i] = UInt8(value >> 8)
            }
            mouse.sectors[sector]!.replaceSubrange(0x12..<0x14, with: [0x00, 0x12])
            mouse.sectors[sector]!.replaceSubrange(0x1C..<0x20, with: [0x3C, 0x00, 0x2C, 0x01])
        }
        MouseProtocol.writeChecksum(&mouse.sectors[0x0001]!)
        return mouse
    }

    // A G305 that runs its factory profile, from an owner's report (app/Fake.cs).
    static func g305() -> FakeMouse {
        let mouse = FakeMouse(fresh: true)
        mouse.zoneCount = 1; mouse.info = "0103010101060600ff0a02"; mouse.dpi = 800; mouse.stage = 1
        mouse.sectors[0x0101] = Backups.bytes("010100900120034006800C0000FFFFFFFF00FFFFFFFFFFFFFFFFFFFFFFFFFFFF800100018001000280010004800100088001001090050000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0000000000001F400000000000000000001F40000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
        return mouse
    }

    // Each demo mouse its variant, as app/Fake.cs's For picks them.
    static func forDevice(_ found: FoundDevice) -> FakeMouse {
        if found.has(0x2202) { return found.wirelessId == 0x40B8 ? dex() : proX2() }
        if found.models.contains("C08B") { return hero() }
        switch found.wirelessId {
        case 0x407F: return g502()
        case 0x4074: return g305()
        case 0x4093: return superlight()
        case 0x4099: return g502XPlus()
        default: return FakeMouse()
        }
    }

    // The DPI button under the wheel: the next stage, as the mouse does on its own before it sends 0x8100 event fn 1.
    func pressDpiButton() {
        stage = (max(0, stage) + 1) % stagesNow.count
        dpi = stagesNow[stage]
    }

    private var stagesNow: [Int] {
        wide ? MouseProtocol.wideStages(sectors[current]!, [100, 32000]) : MouseProtocol.stagesOf(sectors[current]!)
    }

    override func send(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        if FakeG515.latency > 0 { Thread.sleep(forTimeInterval: FakeG515.latency) }
        var reply = [UInt8](repeating: 0, count: 16)
        let padded = parameters + [UInt8](repeating: 0, count: 16)
        func readUInt16(_ at: Int) -> Int { Int(padded[at]) << 8 | Int(padded[at + 1]) }
        switch featureIndex {
        case 0:
            let id = readUInt16(0)
            reply[0] = id == 0x2201 ? 1 : id == 0x8060 ? 2 : id == 0x8070 ? 3 : id == 0x8100 ? 4 : id == 0x2121 && wheel ? 5 : 0
            if wide { reply[0] = id == 0x2202 ? 6 : id == 0x8061 ? 7 : id == 0x8100 ? 4 : 0 }
            if hiddenLight && id == 0x8070 { reply[1] = 0x60 }
        case 6:
            if fn == 1 { reply[1] = 5; reply[2] = 3 }
            if fn == 2 { reply[2] = padded[2]; if padded[2] == 0 { reply.replaceSubrange(3..<11, with: Backups.bytes("0064e0327d000000")) } }
            if fn == 5 {
                reply[1] = UInt8(dpi >> 8); reply[5] = reply[1]; reply[2] = UInt8(dpi & 0xFF); reply[6] = reply[2]
                reply[3] = 0x03; reply[4] = 0x20; reply[9] = 2
            }
            if fn == 6 {
                guard let index = stagesNow.firstIndex(of: readUInt16(1)) else { throw GLiteError.hidpp(5, "HID++ error 0x05") }
                dpi = readUInt16(1); stage = index
            }
        case 7:
            if fn == 1 { reply[1] = 0x7F }
            if fn == 2 { reply[0] = UInt8(padded[0] == 1 ? rate : 0) }
            if fn == 3 { throw GLiteError.hidpp(5, "HID++ error 0x05") }
        case 1:
            if fn == 1 { reply.replaceSubrange(0..<7, with: Backups.bytes("000064e0326400")) }
            if fn == 2 { reply[1] = UInt8(dpi >> 8); reply[2] = UInt8(dpi & 0xFF); reply[3] = 0x03; reply[4] = 0x20 }
            if fn == 3 { dpi = readUInt16(1); stage = stagesNow.firstIndex(of: dpi) ?? -1 }
        case 2:
            if fn == 0 { reply[0] = 0x8B }
            if fn == 1 { reply[0] = UInt8(rate) }
            if fn == 2 { throw GLiteError.hidpp(5, "HID++ error 0x05") }
        case 3:
            if fn == 0 { reply[0] = UInt8(zoneCount) }
            if fn == 1 { reply[0] = padded[0]; reply[2] = padded[0] + 1; reply[3] = 4 }
            if fn == 2 {
                if Int(padded[1]) >= FakeMouse.ids.count { throw GLiteError.hidpp(2, "invalid argument") }
                reply[0] = padded[0]; reply[1] = padded[1]; reply[3] = FakeMouse.ids[Int(padded[1])]
            }
            if fn == 3 { zones[Int(padded[0])] = Array(padded.prefix(12)) }
        case 4:
            if fn == 0 { let bytes = Backups.bytes(info); reply.replaceSubrange(0..<bytes.count, with: bytes) }
            if fn == 2 { reply[0] = 1 }
            if fn == 3 {
                let profile = sectors[readUInt16(0)]!
                current = readUInt16(0)
                reloads += 1
                rate = Int(profile[0])
                stage = Int(profile[wide ? MouseProtocol.wideDefaultStageAt : MouseProtocol.defaultStageAt])
                dpi = stagesNow[stage]
                zones[0] = [0, 0] + profile[0xD1..<0xDB]
                zones[1] = [1, 0] + profile[0xDC..<0xE6]
            }
            if fn == 4 { reply[0] = UInt8(current >> 8); reply[1] = UInt8(current & 0xFF) }
            if fn == 5 {
                guard let sector = sectors[readUInt16(0)] else { throw GLiteError.hidpp(2, "HID++ error 0x02") }
                let part = Array(sector.dropFirst(readUInt16(2)).prefix(16))
                reply.replaceSubrange(0..<part.count, with: part)
            }
            if fn == 6 { writeTo = readUInt16(0); writeLength = readUInt16(4); pending.removeAll() }
            if fn == 7 { pending += padded.prefix(16) }
            if fn == 8 { sectors[writeTo] = Array(pending.prefix(writeLength)) }
            if fn == 0xB { reply[0] = UInt8(max(0, stage)) }
            if fn == 0xC { stage = Int(padded[0]); dpi = stagesNow[stage] }
        case 5:
            if fn == 0 { reply[0] = 0x08; reply[1] = 0x0C }
            if fn == 1 { reply[0] = wheelMode }
            if fn == 2 { wheelMode = padded[0]; reply[0] = wheelMode }
        default: break
        }
        return reply
    }

    static func found(_ name: String = "G502 LIGHTSPEED Wireless Gaming Mouse") -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|mouse"; device.name = name; device.kind = "mouse"; device.link = "LIGHTSPEED"; device.battery = 71
        device.wirelessId = 0x407F
        device.features = [0x0001, 0x0003, 0x0005, 0x1001, 0x2121, 0x2201, 0x8060, 0x8070, 0x8100]
        return device
    }
}

// An in-memory G915 TKL for --demo and the self-test (app/Fake.cs, FakeG915): two clusters with the older effect ids, and profile 1
// of an owner's keyboard (Cycle at 10 s, power save after 60 s, off after 300 s) with its factory copy (Cycle at 5 s).
final class FakeG915: Hidpp {
    var index: [Int: UInt8] = [0x8071: 10, 0x8040: 20, 0x8100: 21, 0x4540: 16, 0x8081: 11, 0x4522: 8]
    var gameBitmap = [UInt8](repeating: 0, count: 16)
    // The Game mode list (0x4522): usages added with fn 1, all cleared with fn 3.
    var gameKeys = Set<Int>()
    var ids: [[UInt8]] = [[0x00, 0x01, 0x03, 0x0A], [0x00, 0x01, 0x0A, 0x03, 0x04, 0x0B, 0x0C]]
    var sectors: [Int: [UInt8]] = [
        1: Backups.bytes("010000000000000000000000000000000000FFFFFFFFFFFFFFFFFFFF3C002C018002003A8002003B8002003C8002003D8002003E8002003F800200408002004180020042800200438002004480020045900DFF01900DFF02900DFF03FFFFFFFF00040000000400020004000400040006000400080004000A0004000C0004000E00040010000400120004001400040016900DFF01900DFF02900DFF03FFFFFFFF500052004F00460049004C0045005F004E0041004D0045005F00440045004600410055004C00540000000000000000000300000000002710320000030000000000271032000003000000000027101900000300000000002710190000004349"),
        0x101: Backups.bytes("010000000000000000000000000000000000FFFFFFFFFFFFFFFFFFFF3C002C018002003A8002003B8002003C8002003D8002003E8002003F800200408002004180020042800200438002004480020045900DFF01900DFF02900D0001900D0002900D0003FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF0300000000001388640000030000000000138864000003000000000013883200000300000000001388320000FFFFFF"),
    ]
    var reloads = 0, power = 1, running = 1, claimed = 0, brightness = 80
    // 0x8100's button slots: 15 on the owner's G915 TKL (F1-F12, M1-M3), 8 on the G815 (G1-G5, M1-M3).
    var buttonSlots = 15
    var modes: [UInt8] = [1]
    var live: [[UInt8]] = [[UInt8](repeating: 0, count: 13), [UInt8](repeating: 0, count: 13)]
    private var pending: [UInt8] = []
    private var writeTo = 0, writeLength = 0

    // The owner's directory lists profiles 1 to 3 (docs/G815-G915.md). Profiles 2 and 3 are copies of 1 with static red and blue keys.
    init() {
        super.init(fake: 1)
        var directory = [UInt8](repeating: 0xFF, count: 255)
        directory.replaceSubrange(0..<12, with: Backups.bytes("000101FF000201FF000301FF"))
        MouseProtocol.writeChecksum(&directory)
        sectors[0] = directory
        sectors[2] = FakeG915.recolored(sectors[1]!, "01FF0000")
        sectors[3] = FakeG915.recolored(sectors[1]!, "010000FF")
    }

    // A G512 X 75 (app/Fake.cs, G512X): its own indexes, 0x8101 instead of 0x8100, the Game mode bitmap (0x1B10 and 0x4523, the
    // G515's control list) and the newer effect ids.
    static func g512x() -> FakeG915 {
        let fake = FakeG915()
        fake.index = [0x8071: 6, 0x8081: 7, 0x8040: 8, 0x8101: 9, 0x4540: 10, 0x1B10: 11, 0x4523: 12]
        fake.ids = [[0x00, 0x01, 0x0A, 0x15, 0x16, 0x17, 0x18], [0x00, 0x01, 0x0A, 0x15, 0x16, 0x18]]
        return fake
    }

    static func recolored(_ profile: [UInt8], _ record: String) -> [UInt8] {
        var copy = profile
        for at in stride(from: 0xD0, to: 0xE6, by: 11) {
            for i in 0..<11 { copy[at + i] = 0 }
            let bytes = Backups.bytes(record)
            copy.replaceSubrange(at..<at + bytes.count, with: bytes)
        }
        MouseProtocol.writeChecksum(&copy)
        return copy
    }

    static func found() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|g915"; device.name = "G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard"; device.kind = "keyboard"
        device.link = "LIGHTSPEED"; device.battery = 55
        device.features = [0x0001, 0x0003, 0x0005, 0x1001, 0x4522, 0x4540, 0x8040, 0x8071, 0x8081, 0x8100]
        return device
    }

    override func send(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        if FakeG515.latency > 0 { Thread.sleep(forTimeInterval: FakeG515.latency) }
        var reply = [UInt8](repeating: 0, count: 16)
        let padded = parameters + [UInt8](repeating: 0, count: 16)
        func readUInt16(_ at: Int) -> Int { Int(padded[at]) << 8 | Int(padded[at + 1]) }
        let index = self.index
        if featureIndex == 0 {
            reply[0] = index[readUInt16(0)] ?? 0
        } else if featureIndex == index[0x1B10] {
            FakeG515.controls(fn, padded, &reply)
        } else if featureIndex == index[0x4523] {
            if fn == 0 { gameBitmap = Array(padded.prefix(16)) }
        } else if featureIndex == index[0x4540] {
            reply[0] = 1
        } else if featureIndex == index[0x4522] {
            if fn == 0 { reply[0] = 0xFF }
            if fn == 1 { for usage in padded.prefix(16).prefix(while: { $0 != 0 }) { gameKeys.insert(Int(usage)) } }
            if fn == 3 { gameKeys.removeAll() }
        } else if featureIndex == index[0x8100] {
            switch fn {
            case 0: reply.replaceSubrange(0..<11, with: Backups.bytes("01040103030F1000FF3604")); reply[5] = UInt8(buttonSlots)
            case 1: modes.append(padded[0])
            case 2: reply[0] = modes.last!
            case 3: reloads += 1; running = readUInt16(0)
            case 4: reply[1] = modes.last == 1 ? UInt8(running) : 0
            case 5:
                guard let sector = sectors[readUInt16(0)] else { throw GLiteError.hidpp(2, "invalid argument") }
                let part = Array(sector.dropFirst(readUInt16(2)).prefix(16))
                reply.replaceSubrange(0..<part.count, with: part)
            case 6: writeTo = readUInt16(0); writeLength = readUInt16(4); pending.removeAll()
            case 7: pending += padded.prefix(16)
            case 8: sectors[writeTo] = Array(pending.prefix(writeLength))
            default: break
            }
        } else if featureIndex == index[0x8040] {
            if fn == 1 { reply[0] = UInt8(brightness >> 8); reply[1] = UInt8(brightness & 0xFF) }
            if fn == 2 { brightness = readUInt16(0) }
        } else if featureIndex == index[0x8081] {
            // Every key lit, up to 0x6F (the G915 TKL's report lists per-key lighting; which ids isn't recorded).
            if fn == 0 {
                reply[1] = padded[1]
                let base = Int(padded[1]) * 112
                for id in base..<base + 112 where (0x01...0x6F).contains(id) { reply[2 + (id - base) / 8] |= UInt8(1 << (id % 8)) }
            }
        } else if featureIndex == index[0x8071] {
            if fn == 0 || fn == 1 {
                if Int(padded[0]) >= ids.count || Int(padded[1]) >= ids[Int(padded[0])].count { throw GLiteError.hidpp(2, "invalid argument") }
                if fn == 0 { reply[0] = padded[0]; reply[1] = padded[1]; reply[3] = ids[Int(padded[0])][Int(padded[1])] }
                else { live[Int(padded[0])] = Array(padded.prefix(13)) }
            }
            if fn == 5 && padded[0] == 1 { claimed = Int(padded[1]) }
            if fn == 5 { reply[1] = UInt8(claimed) }
            if fn == 8 && padded[0] == 1 { power = Int(padded[1]) }
            if fn == 8 { reply[1] = UInt8(power) }
        } else {
            throw GLiteError.hidpp(2, "invalid argument")
        }
        return reply
    }
}

// The G560 speakers, or a zones keyboard (app/Fake.cs, FakeSpeaker): a G213 from its report (zone 0 the whole keyboard, zones 1–5,
// locations 6–10, Off and Static only), a G413 Silver from its report (one zone, Off, Static and Breathe, monochrome).
final class FakeSpeaker: Hidpp {
    static let index: [Int: UInt8] = [0x8070: 4, 0x8040: 8, 0x8080: 11, 0x4522: 10]
    static let effects: [UInt8] = [0x00, 0x01, 0x03, 0x07, 0x0A]
    var live: [[UInt8]] = [[UInt8]](repeating: [], count: 6)
    var count = 4, g213 = false, g413 = false, perKey = false
    // 0x8080: colours by USB usage as fn 3 left them, and the frames fn 5 showed.
    var keyColors: [Int: Int] = [:], frames = 0
    var gameKeys = Set<Int>()

    init() { super.init(fake: 0xFF) }

    static func g213Keyboard() -> FakeSpeaker { let fake = FakeSpeaker(); fake.count = 6; fake.g213 = true; return fake }
    static func g413Silver() -> FakeSpeaker { let fake = FakeSpeaker(); fake.count = 1; fake.g413 = true; return fake }
    // A G512 or G513: the keys and the logo on 0x8070, per-key colours on 0x8080 (OpenLogi's G512 recording has both).
    static func g512() -> FakeSpeaker { let fake = FakeSpeaker(); fake.count = 2; fake.perKey = true; return fake }

    // A posted call (Hidpp.postUnlogged) gets no reply read.
    override func write(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        _ = try send(featureIndex, fn, parameters)
        return []
    }

    func zoneEffects(_ zone: Int) -> [UInt8] {
        if g413 { return [0x00, 0x01, 0x0A] }
        return !g213 ? FakeSpeaker.effects : zone == 0 ? [0x00, 0x01, 0x0A, 0x03, 0x04] : [0x00, 0x01]
    }

    static func found() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|g560"; device.name = "G560 Gaming Speaker"; device.kind = "device"; device.link = "USB"
        device.features = [0x0001, 0x0003, 0x0005, 0x8040, 0x8070]
        return device
    }

    override func send(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        if FakeG515.latency > 0 { Thread.sleep(forTimeInterval: FakeG515.latency) }
        var reply = [UInt8](repeating: 0, count: 16)
        let padded = parameters + [UInt8](repeating: 0, count: 16)
        if featureIndex == 0 { reply[0] = FakeSpeaker.index[Int(padded[0]) << 8 | Int(padded[1])] ?? 0; return reply }
        if featureIndex == FakeSpeaker.index[0x4522] && (g413 || perKey) {
            if fn == 1 { for usage in padded.prefix(16).prefix(while: { $0 != 0 }) { gameKeys.insert(Int(usage)) } }
            if fn == 3 { gameKeys.removeAll() }
            return reply
        }
        if featureIndex == FakeSpeaker.index[0x8080] && perKey {
            if fn == 3 {
                if padded[1] != 0x01 || padded[3] > 3 { throw GLiteError.hidpp(2, "invalid argument") }
                for entry in 0..<Int(padded[3]) {
                    keyColors[Int(padded[4 + 4 * entry])] = Int(padded[5 + 4 * entry]) << 16 | Int(padded[6 + 4 * entry]) << 8 | Int(padded[7 + 4 * entry])
                }
            }
            if fn == 5 { frames += 1 }
            return reply
        }
        guard featureIndex == FakeSpeaker.index[0x8070] else {
            if featureIndex != FakeSpeaker.index[0x8040] { throw GLiteError.hidpp(2, "invalid argument") }
            return reply
        }
        let zone = Int(padded[0])
        switch fn {
        case 0:
            reply[0] = UInt8(count)
            if g413 { reply[2] = 0x01; reply[4] = 0x08 }
        case 1:
            reply[0] = padded[0]
            reply[2] = UInt8(g213 ? (zone == 0 ? 1 : zone + 5) : g413 ? 1 : zone + 1)
            reply[3] = UInt8(zoneEffects(zone).count)
        case 2:
            let listed = zoneEffects(zone)
            if Int(padded[1]) >= listed.count { throw GLiteError.hidpp(2, "invalid argument") }
            reply[0] = padded[0]; reply[1] = padded[1]; reply[3] = listed[Int(padded[1])]
        case 3:
            if zone >= count || Int(padded[1]) >= zoneEffects(zone).count { throw GLiteError.hidpp(2, "invalid argument") }
            live[zone] = Array(padded.prefix(12))
        default: break
        }
        return reply
    }
}

// A PRO X Wireless (app/Fake.cs, FakeHeadset): sidetone 30, auto-off after 30 min, 3926 mV.
final class FakeHeadset: Hidpp {
    var sidetone = 30, autoOffMinutes = 30

    init() { super.init(fake: 0xFF) }

    static func found() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|headset"; device.name = "PRO X Wireless Gaming Headset"; device.kind = "headset"; device.link = "LIGHTSPEED"
        device.battery = 71; device.features = [0x0001, 0x0003, 0x0005, 0x1F20, 0x8300]
        return device
    }

    override func send(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        var reply = [UInt8](repeating: 0, count: 16)
        let padded = parameters + [UInt8](repeating: 0, count: 16)
        if featureIndex == 0 {
            let id = Int(padded[0]) << 8 | Int(padded[1])
            reply[0] = id == 0x8300 ? 1 : id == 0x1F20 ? 2 : 0
        } else if featureIndex == 1 {
            if fn == 0 { reply[0] = UInt8(sidetone) }
            if fn == 1 { sidetone = Int(padded[0]) }
        } else if featureIndex == 2 {
            if fn == 0 { reply[0] = 0x0F; reply[1] = 0x56; reply[2] = 1 }
            if fn == 1 { reply[0] = UInt8(autoOffMinutes) }
            if fn == 2 { autoOffMinutes = Int(padded[0]) }
        }
        return reply
    }
}

// A Litra Beam LX (app/Fake.cs, FakeLight): front light at 200 lm and 4000 K, back light at 80%.
final class FakeLight: Hidpp {
    static let index: [Int: UInt8] = [0x1990: 6, 0x8040: 0x0A, 0x8071: 0x0B, 0x8081: 0x0C]
    // 0x8071's groups as app/Fake.cs has them, the effect fn 1 last set, and whether software holds the clusters.
    static let groups: [[UInt8]] = [[0x01, 0x0A, 0x15], [0x13, 0x16, 0x18]]
    var effect: [UInt8] = [], controlled = false
    var frontOn = true, backOn = true
    var lumen = 200, kelvin = 4000, backLevel = 80, frames = 0
    var colors = [Int](repeating: 0, count: 7)

    init() { super.init(fake: 0xFF) }

    static func found() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|litra"; device.name = "Litra Beam LX"; device.kind = "light"; device.link = "USB"
        device.features = [0x0001, 0x0003, 0x0005, 0x1990, 0x8040, 0x8071, 0x8081]
        return device
    }

    override func send(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        if FakeG515.latency > 0 { Thread.sleep(forTimeInterval: FakeG515.latency) }
        var reply = [UInt8](repeating: 0, count: 16)
        let padded = parameters + [UInt8](repeating: 0, count: 16)
        if featureIndex == 0 {
            reply[0] = FakeLight.index[Int(padded[0]) << 8 | Int(padded[1])] ?? 0
        } else if featureIndex == FakeLight.index[0x1990] {
            switch fn {
            case 0: reply[0] = frontOn ? 1 : 0
            case 1: frontOn = padded[0] == 1
            case 2: reply[2] = 30; reply[3] = 0x01; reply[4] = 0x90; reply[6] = 1
            case 3: reply[0] = UInt8(lumen >> 8); reply[1] = UInt8(lumen & 0xFF)
            case 4: lumen = Int(padded[0]) << 8 | Int(padded[1])
            case 7: reply[1] = 0x0A; reply[2] = 0x8C; reply[3] = 0x19; reply[4] = 0x64; reply[6] = 100
            case 8: reply[0] = UInt8(kelvin >> 8); reply[1] = UInt8(kelvin & 0xFF)
            case 9: kelvin = Int(padded[0]) << 8 | Int(padded[1])
            default: throw GLiteError.hidpp(7, "invalid function")
            }
        } else if featureIndex == FakeLight.index[0x8040] {
            if fn == 1 { reply[1] = UInt8(backLevel) }
            if fn == 2 { backLevel = Int(padded[1]) }
            if fn == 3 { reply[0] = backOn ? 1 : 0 }
            if fn == 4 { backOn = padded[0] == 1 }
        } else if featureIndex == FakeLight.index[0x8071] {
            switch fn {
            case 0:
                let group = Int(padded[0]), index = Int(padded[1])
                if group >= FakeLight.groups.count || (index != 0xFF && index >= FakeLight.groups[group].count) {
                    throw GLiteError.hidpp(2, "invalid argument")
                }
                reply[0] = padded[0]; reply[1] = padded[1]
                if index == 0xFF { reply[4] = UInt8(FakeLight.groups[group].count) } else { reply[3] = FakeLight.groups[group][index] }
            // A real Beam LX answers 0x05 to fn 1 unless software holds the clusters (fn 5 bit 0).
            case 1:
                if !controlled { throw GLiteError.hidpp(5, "Logitech internal") }
                effect = Array(padded.prefix(13))
            case 5:
                if padded[0] == 1 { controlled = padded[1] & 1 != 0 }
                reply[1] = controlled ? 1 : 0
            default: throw GLiteError.hidpp(7, "invalid function")
            }
        } else if featureIndex == FakeLight.index[0x8081] {
            if fn == 1 {
                for at in stride(from: 0, to: 16, by: 4) where padded[at] >= 1 && padded[at] <= 7 {
                    colors[Int(padded[at]) - 1] = Int(padded[at + 1]) << 16 | Int(padded[at + 2]) << 8 | Int(padded[at + 3])
                }
            }
            if fn == 7 { frames += 1 }
        }
        return reply
    }
}

// A G510s with the feature reports from an owner's report (app/Fake.cs, FakeG510; docs/G510.md).
final class FakeG510: Hidpp {
    var features: [UInt8: [UInt8]] = [0x04: [0x04, 0x80], 0x05: [0x05, 0xFF, 0xFF, 0xFF], 0x06: [0x06, 0xFF, 0xFF, 0xFF], 0x07: [0x07, 0x03, 0x00]]
    var writes = 0

    init() { super.init(fake: 0xFF) }

    static func found() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|g510"; device.name = "G510s Gaming Keyboard"; device.kind = "keyboard"; device.link = "USB"
        device.plainHid = true; device.hasVendorCollection = true; device.models = "USB C22E"; device.usbId = 0xC22E
        return device
    }

    override func readFeature(_ id: UInt8) throws -> [UInt8] {
        guard let report = features[id] else { throw GLiteError.io(String(format: "Couldn't read feature report %02X", id)) }
        return report
    }

    override func writeFeature(_ report: [UInt8]) throws {
        features[report[0]] = report
        writes += 1
    }
}

// A G9x Laser Mouse over HID++ 1.0 registers (app/Fake.cs, FakeG9x): page 1 the directory, pages 2-4 the profiles, page 0 the RAM
// uploads go to. Variants: a G500s (no colour light, DPI in units of 50), a G5 or G9 (a one-byte 0x63, no light, no memory).
final class FakeG9x: Hidpp {
    var registers: [Int: [UInt8]] = [
        0x0F: [0, 0, 0], 0x51: Backups.bytes("221200"), 0x57: Backups.bytes("FF0000"), 0x64: Backups.bytes("020000"),
        0x63: Backups.bytes("22002200800100000000000000000000"), 0xF1: Backups.bytes("015802"),
    ]
    var pages: [Int: [UInt8]] = [:]
    var writes: [String] = []
    // The next copy of a second half fails once, after its page was erased: a save cut off halfway.
    var failSecondHalf = false
    private var nextSequence = -1, uploadPage = 0, uploadOffset = 0, uploadLeft = 0

    init() {
        super.init(fake: 0)
        pages[0] = [UInt8](repeating: 0, count: 512)
        pages[1] = FakeG9x.page("020001030003040007")
        pages[2] = FakeG9x.page("FF00008000110011221100220022221200440044222200880088122200000000122101011010028101008102008104008108008110008F0000830100830200830400830800")
        pages[3] = FakeG9x.page("00FF00800009000922110022002222120055005522220000000012220000000012210101101001")
        pages[4] = FakeG9x.page("0000FF800011001122110022002222120044004422220000000012220000000012210101101002")
    }

    static func page(_ start: String) -> [UInt8] {
        var page = [UInt8](repeating: 0xFF, count: 512)
        let bytes = Backups.bytes(start)
        page.replaceSubrange(0..<bytes.count, with: bytes)
        MouseProtocol.writeChecksum(&page)
        return page
    }

    // A G500s: no colour light (0x57), DPI in units of 50 (cvuchener's hidpp), stages 400, 800, 1600, 3200 on page 2.
    static func g500s() -> FakeG9x {
        let mouse = FakeG9x()
        mouse.registers[0x57] = nil
        mouse.registers[0x63] = Backups.bytes("10001000800100000000000000000000")
        mouse.pages[2] = page("000000800008000822110010001022120020002022220040004012220000000012210101101002")
        return mouse
    }

    // A G5 or G9: a one-byte 0x63 (0x80 + index), no colour light and no profile memory.
    static func short(_ resolution: UInt8) -> FakeG9x {
        let mouse = FakeG9x()
        mouse.registers[0x57] = nil
        mouse.registers[0x0F] = nil
        mouse.registers[0x63] = [resolution, 0, 0]
        mouse.pages.removeAll()
        return mouse
    }

    static func found() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|g9x"; device.name = "G9x Laser Mouse"; device.kind = "mouse"; device.link = "USB"
        device.hidpp10 = true; device.usbId = 0xC066; device.index = 0; device.models = "USB C066"; device.firmware = "58.02"
        return device
    }

    override func send(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        throw GLiteError.hidpp(1, "HID++ 1.0 only")
    }

    override func sendUpload(_ subId: UInt8, _ sequence: UInt8, _ data: [UInt8]) throws {
        if Int(sequence) != nextSequence || (subId == 0x92) != (sequence == 0) { throw GLiteError.hidpp(0x05, "out of sequence") }
        nextSequence += 1
        var start = 0
        if subId == 0x92 {
            uploadPage = Int(data[1]); uploadOffset = Int(data[2]) * 2; uploadLeft = Int(data[5]) << 8 | Int(data[6]); start = 9
        }
        if uploadPage != 0 { throw GLiteError.hidpp(0x07, "uploads go to RAM") }
        var i = start
        while i < 16 && uploadLeft > 0 { pages[0]![uploadOffset] = data[i]; uploadOffset += 1; uploadLeft -= 1; i += 1 }
    }

    override func sendRegister(_ subId: UInt8, _ register: UInt8, _ parameters: [UInt8]) throws -> [UInt8] {
        var reply = [UInt8](repeating: 0, count: 16)
        let p = parameters + [UInt8](repeating: 0, count: 16)
        if subId == 0x80 && register == 0xA1 { nextSequence = 0; return reply }
        if subId == 0x82 && register == 0xA0 {
            let target = Int(p[6]), wordOffset = Int(p[7]), length = Int(p[10]) << 8 | Int(p[11])
            if target < 2 { throw GLiteError.hidpp(0x07, "protected page") }
            if failSecondHalf && p[0] == 0x03 && wordOffset == 0x80 { failSecondHalf = false; throw GLiteError.hidpp(0x04, "copy failed") }
            writes.append((p[0] == 0x02 ? "erase " : "copy ") + "\(target):\(wordOffset)")
            if p[0] == 0x02 { pages[target] = [UInt8](repeating: 0xFF, count: 512) }
            else { for i in 0..<length { pages[target]![wordOffset * 2 + i] &= pages[Int(p[2])]![Int(p[3]) * 2 + i] } }
            return reply
        }
        if subId == 0x83 && register == 0xA2 {
            guard let page = pages[Int(p[0])] else { throw GLiteError.hidpp(3, "no such page") }
            let offset = Int(p[1]) * 2
            reply.replaceSubrange(0..<16, with: page[offset..<offset + 16])
            return reply
        }
        guard let value = registers[Int(register)] else { throw GLiteError.hidpp(2, "no such register") }
        if subId == 0x80 || subId == 0x82 {
            registers[Int(register)] = Array(p.prefix(value.count))
            return reply
        }
        reply.replaceSubrange(0..<value.count, with: value)
        return reply
    }
}

// A G600 with tulth/g600prog's defaults.json (app/Fake.cs, FakeG600): mode 1 rainbow with the keypad as 1 to =, mode 2 white with
// the numeric keypad, mode 3 a green pulse with DPI buttons. 400, 1200, 2000 and 3200 DPI, 1000 Hz.
final class FakeG600: Hidpp {
    var mode = 0, level = 1
    let modes: [[UInt8]] = [
        FakeG600.report(0xF3, 0x000000, 2, 6, "010000020000030000040000050000170000000205140000"
            + "00001E00001F000020000021000022000023000024000025000026000027" + "00002D00002E"),
        FakeG600.report(0xF4, 0xFFFFFF, 0, 0, "010000020000030000040000050000170000000205140000"
            + "00005900005A00005B00005C00005D00005E00005F000060000061000062" + "000056000057"),
        FakeG600.report(0xF5, 0x00FF00, 1, 4, "010000020000030000040000050000150000130000140000"
            + "00001E00001F000020000021000022000023" + "110000160000050000120000000008040000"),
    ]

    init() { super.init(fake: 0xFF) }

    static func report(_ id: UInt8, _ color: Int, _ effect: UInt8, _ duration: UInt8, _ buttons: String) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: G600Mouse.reportLength)
        report[0] = id
        report[1] = UInt8(color >> 16 & 0xFF); report[2] = UInt8(color >> 8 & 0xFF); report[3] = UInt8(color & 0xFF)
        report[4] = effect
        report[5] = duration
        let rates = Backups.bytes("000802" + "08182840")
        report.replaceSubrange(11..<11 + rates.count, with: rates)
        let bindings = Backups.bytes(buttons)
        report.replaceSubrange(31..<31 + bindings.count, with: bindings)
        report[91] = 0xFF; report[92] = 0xFF; report[93] = 0xFF
        let shifted = Backups.bytes("010000020000030000")
        report.replaceSubrange(94..<94 + shifted.count, with: shifted)
        return report
    }

    static func found() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|g600"; device.name = "G600 Gaming Mouse"; device.kind = "mouse"; device.link = "USB"
        device.plainHid = true; device.hasVendorCollection = true; device.usbId = 0xC24A; device.models = "USB C24A"
        return device
    }

    override func readFeature(_ id: UInt8) throws -> [UInt8] {
        if id == G600Mouse.activeReport {
            var reply = [UInt8](repeating: 0, count: G600Mouse.reportLength)
            reply[0] = id; reply[1] = UInt8(mode << 4 | level << 1)
            return reply
        }
        guard id >= G600Mouse.firstModeReport, Int(id - G600Mouse.firstModeReport) < G600Mouse.modeCount else {
            throw GLiteError.io(String(format: "Couldn't read feature report %02X", id))
        }
        return modes[Int(id - G600Mouse.firstModeReport)]
    }

    override func writeFeature(_ report: [UInt8]) throws { throw GLiteError.io(String(format: "Couldn't set feature report %02X", report[0])) }
}

// A G300 (app/Fake.cs, FakeG300): three profiles like those PeriHub's owner read, green, blue and off; a DPI shift button on profile
// 2, Ctrl alone on profile 3's G7. Profile writes are kept, so a save reads back.
final class FakeG300: Hidpp {
    var profile = 0, level = 1
    var profiles: [[UInt8]] = [
        Backups.bytes("F302000284060A40" + "010000020000030000" + "0A00000B00000C0000" + "040000050000" + "0D0000"),
        Backups.bytes("F4040304880A0804" + "010000020000030000" + "0A00000B0000000106" + "040000050000" + "0E0000"),
        Backups.bytes("F500020204860A40" + "010000020000030000" + "0C00000D00000F0000" + "000100050000" + "040000"),
    ]

    init() { super.init(fake: 0xFF) }

    static func found() -> FoundDevice {
        let device = FoundDevice()
        device.key = "demo|g300"; device.name = "G300 Gaming Mouse"; device.kind = "mouse"; device.link = "USB"
        device.plainHid = true; device.hasVendorCollection = true; device.usbId = 0xC246; device.models = "USB C246"
        return device
    }

    override func readFeature(_ id: UInt8) throws -> [UInt8] {
        if id == G300Mouse.activeReport { return [id, UInt8(profile << 4 | level << 1), 0, 0] }
        guard id >= G300Mouse.firstProfileReport, Int(id - G300Mouse.firstProfileReport) < G300Mouse.profileCount else {
            throw GLiteError.io(String(format: "Couldn't read feature report %02X", id))
        }
        return profiles[Int(id - G300Mouse.firstProfileReport)]
    }

    override func writeFeature(_ report: [UInt8]) throws {
        guard report.count == G300Mouse.reportLength, report[0] >= G300Mouse.firstProfileReport,
              Int(report[0] - G300Mouse.firstProfileReport) < G300Mouse.profileCount else {
            throw GLiteError.io(String(format: "Couldn't set feature report %02X", report[0]))
        }
        profiles[Int(report[0] - G300Mouse.firstProfileReport)] = report
    }
}
