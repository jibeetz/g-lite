import Foundation

// Which screen and driver each device gets (app/DeviceTable.cs). The first entry that matches wins; asleep or unmatched devices get
// the info page. A device that works like a supported one is a new entry here.
struct DeviceTable {
    let matches: (FoundDevice) -> Bool
    let make: (FoundDevice, @escaping () throws -> Hidpp) -> DevicePage
    // The in-memory device --demo talks to.
    let fake: (FoundDevice) -> Hidpp
    // The setting a screen sends again at each load: when it's set, the screen is made at each scan even if it isn't opened.
    var keeps: ((FoundDevice) -> String)? = nil

    static let all: [DeviceTable] = [
        DeviceTable(matches: { $0.isG515 }, make: { KeyboardPage(device: $0, hidpp: $1) }, fake: { _ in FakeG515() }),
        // The G915 TKL's profile counts 15 buttons (F1-F12, M1-M3), the G915's and G815's 8; the others are 0x8101 keyboards like the G512 X 75.
        DeviceTable(matches: { $0.isG && $0.isRgbKeyboard }, make: { LiveKeyboardPage(device: $0, hidpp: $1) }, fake: { found in
                        guard found.isG915 else { return FakeG915.g512x() }
                        let fake = FakeG915()
                        fake.buttonSlots = found.name.uppercased().contains("TKL") ? 15 : 8
                        return fake },
                    keeps: { "lighting." + $0.settingsKey }),
        DeviceTable(matches: { $0.isG && ($0.isLedKeyboard || $0.isG560) }, make: { ZonesPage(device: $0, hidpp: $1) },
                    fake: { found in found.kind != "keyboard" ? FakeSpeaker() : found.shortName.uppercased().hasPrefix("G413") ? FakeSpeaker.g413Silver()
                        : found.has(0x8080) ? FakeSpeaker.g512() : FakeSpeaker.g213Keyboard() }, keeps: { "lighting." + $0.settingsKey }),
        // The G305 loses its live light when switched off; the others keep what the mouse saved.
        DeviceTable(matches: { $0.isG9x }, make: { MousePage(device: $0, hidpp: $1, mouse: G9xMouse(.g9x)) }, fake: { _ in FakeG9x() }),
        DeviceTable(matches: { $0.isG5 }, make: { MousePage(device: $0, hidpp: $1, mouse: G5Mouse.g5()) }, fake: { _ in FakeG9x.short(0x82) }),
        DeviceTable(matches: { $0.isG9 }, make: { MousePage(device: $0, hidpp: $1, mouse: G5Mouse.g9()) }, fake: { _ in FakeG9x.short(0x84) }),
        DeviceTable(matches: { $0.isG600 }, make: { MousePage(device: $0, hidpp: $1, mouse: G600Mouse()) }, fake: { _ in FakeG600() }),
        DeviceTable(matches: { $0.isG300 }, make: { MousePage(device: $0, hidpp: $1, mouse: G300Mouse()) }, fake: { _ in FakeG300() }),
        DeviceTable(matches: { $0.isG500 }, make: { MousePage(device: $0, hidpp: $1, mouse: G9xMouse($0.g500Model)) },
                    fake: { _ in FakeG9x.g500s() }),
        DeviceTable(matches: { $0.isG && $0.isMouse }, make: { MousePage(device: $0, hidpp: $1, mouse: HidppMouse()) },
                    fake: { FakeMouse.forDevice($0) },
                    keeps: { $0.lightIsLiveOnly ? "lighting." + $0.settingsKey : "" }),
        DeviceTable(matches: { $0.isLight }, make: { LightPage(device: $0, hidpp: $1) }, fake: { _ in FakeLight() },
                    keeps: { $0.has(0x8081) ? "lighting." + $0.settingsKey : "" }),
        DeviceTable(matches: { $0.isG510 }, make: { G510Page(device: $0, hidpp: $1) }, fake: { _ in FakeG510() }, keeps: { "lighting." + $0.settingsKey }),
        DeviceTable(matches: { $0.isHeadset }, make: { HeadsetPage(device: $0, hidpp: $1) }, fake: { _ in FakeHeadset() }),
        DeviceTable(matches: OtherDevice.supports, make: { OtherPage(device: $0, hidpp: $1) }, fake: { _ in FakeOther() },
                    keeps: { "device." + $0.settingsKey }),
    ]

    static func entry(_ device: FoundDevice) -> DeviceTable? { device.asleep ? nil : all.first { $0.matches(device) } }

    // Whether the device's screen has something to send at each scan: what it keeps, or a picked preset (app/Pages.cs, SendsAgain).
    static func keeps(_ device: FoundDevice) -> Bool {
        guard let entry = entry(device) else { return false }
        if !Settings.get("preset." + device.settingsKey).isEmpty { return true }
        guard let key = entry.keeps?(device), !key.isEmpty else { return false }
        return !Settings.get(key).isEmpty
    }

    // What --demo lists: every device Windows' --demo lists (app/Program.cs, DemoDevices), with the same names, links, batteries,
    // firmware and features.
    static func demoDevices() -> [FoundDevice] {
        func device(_ key: String, _ name: String, _ kind: String, _ link: String, index: UInt8 = 0xFF, wireless: Int = 0, battery: Int = -1,
                    millivolts: Int = 0, firmware: String = "", features: [Int] = [], models: String = "", usb: Int = 0,
                    plain: Bool = false, hidpp10: Bool = false) -> FoundDevice {
            let found = FoundDevice()
            found.key = "demo|" + key; found.name = name; found.kind = kind; found.link = link; found.index = index
            found.wirelessId = wireless; found.battery = battery; found.millivolts = millivolts; found.batteryFromVoltage = millivolts > 0
            found.firmware = firmware; found.features = features; found.models = models; found.usbId = usb
            found.plainHid = plain; found.hasVendorCollection = plain; found.hidpp10 = hidpp10
            return found
        }
        let base = [0x0001, 0x0003, 0x0005]
        return [
            FakeG515.found(),
            device("g915full", "G915 LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard", "keyboard", "LIGHTSPEED", index: 2, wireless: 0x407C,
                   battery: 46, millivolts: 3780, firmware: "MPK 12.01, build 0019", features: base + [0x1001, 0x4522, 0x8040, 0x8071, 0x8081, 0x8100]),
            device("g915", "G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard", "keyboard", "LIGHTSPEED", index: 1, wireless: 0x408E,
                   battery: 70, millivolts: 3923, firmware: "MPK 14.01, build 0021", features: base + [0x1001, 0x4522, 0x8040, 0x8071, 0x8081, 0x8100]),
            device("g915x", "G915 X LIGHTSPEED", "keyboard", "LIGHTSPEED", index: 2, wireless: 0x40B5, battery: 68, firmware: "MPK 27.00, build 0012",
                   features: base + [0x1004, 0x4540, 0x8040, 0x8071, 0x8081, 0x8101]),
            device("g915xtkl", "G915 X LIGHTSPEED TKL", "keyboard", "LIGHTSPEED", index: 3, wireless: 0x40B6, battery: 91,
                   firmware: "MPK 27.00, build 0012", features: base + [0x1004, 0x4540, 0x8040, 0x8071, 0x8081, 0x8101]),
            device("g815", "G815 RGB MECHANICAL GAMING KEYBOARD", "keyboard", "USB", firmware: "U1 31.02, build 0018",
                   features: base + [0x4522, 0x4540, 0x8040, 0x8071, 0x8081, 0x8100]),
            device("g512x", "G512 X 75", "keyboard", "USB", firmware: "U1 81.05, build 0020",
                   features: base + [0x1B10, 0x4523, 0x4540, 0x8040, 0x8071, 0x8081, 0x8101]),
            device("prox60", "PRO X 60", "keyboard", "LIGHTSPEED", index: 5, wireless: 0x40C1, battery: 77, firmware: "MPK 21.01, build 0012",
                   features: base + [0x1004, 0x4540, 0x8040, 0x8071, 0x8081, 0x8101]),
            device("g512", "G512 RGB MECHANICAL GAMING KEYBOARD", "keyboard", "USB", firmware: "U1 38.03, build 0015",
                   features: base + [0x4522, 0x4540, 0x8060, 0x8080, 0x8070]),
            device("g413", "G413 Silver Mechanical Gaming Keyboard", "keyboard", "USB", firmware: "U1 14.00, build 0008",
                   features: base + [0x4522, 0x4540, 0x8060, 0x8070, 0x40A2]),
            device("g213", "Gaming Keyboard G213", "keyboard", "USB", firmware: "U1 12.01, build 0007",
                   features: base + [0x4522, 0x4540, 0x8060, 0x8070]),
            device("g513", "G513 Carbon RGB Mechanical Gaming Keyboard", "keyboard", "USB", firmware: "U1 38.03, build 0015",
                   features: base + [0x4522, 0x4540, 0x8060, 0x8080, 0x8070]),
            device("gprokeyboard", "G PRO RGB Mechanical Gaming Keyboard", "keyboard", "USB", firmware: "U1 36.02, build 0011",
                   features: base + [0x4522, 0x4540, 0x8060, 0x8080, 0x8070]),
            device("g810", "G810 Orion Spectrum", "keyboard", "USB", firmware: "U1 35.04, build 0012",
                   features: base + [0x4522, 0x4540, 0x8060, 0x8080, 0x8070]),
            device("g910", "G910 Orion Spectrum", "keyboard", "USB", firmware: "U1 34.01, build 0009",
                   features: base + [0x4522, 0x4540, 0x8060, 0x8080, 0x8070]),
            device("g410", "G410 Atlas Spectrum", "keyboard", "USB", firmware: "U1 33.00, build 0008",
                   features: base + [0x4522, 0x4540, 0x8060, 0x8080, 0x8070]),
            FakeG510.found(),
            device("mouse", "G Pro Wireless Gaming Mouse", "mouse", "LIGHTSPEED", index: 1, wireless: 0x4079, battery: 54, millivolts: 3824,
                   firmware: "MPM 15.02, build 0017", features: base + [0x1001, 0x2201, 0x8060, 0x8070, 0x8100]),
            device("superlight", "PRO X Wireless", "mouse", "LIGHTSPEED", index: 7, wireless: 0x4093, battery: 71, firmware: "MPM 25.01, build 0018",
                   features: base + [0x1004, 0x2201, 0x8060, 0x8070, 0x8100]),
            device("g502xplus", "G502 X PLUS", "mouse", "LIGHTSPEED", index: 3, wireless: 0x4099, battery: 82, firmware: "MPM 30.00, build 0014",
                   features: base + [0x1004, 0x2121, 0x2201, 0x8060, 0x8071, 0x8081, 0x8100]),
            device("superlight2", "PRO X SUPERLIGHT 2", "mouse", "LIGHTSPEED", index: 4, wireless: 0x40A9, battery: 63,
                   firmware: "MPM 31.01, build 0018", features: base + [0x1004, 0x2202, 0x8061, 0x8100]),
            device("dex", "PRO X 2 DEX", "mouse", "LIGHTSPEED", index: 6, wireless: 0x40B8, battery: 88, firmware: "MPM 33.00, build 0010",
                   features: base + [0x1004, 0x2202, 0x8061, 0x8100]),
            FakeG600.found(),
            FakeG300.found(),
            FakeG9x.found(),
            FakeSpeaker.found(),
            FakeLight.found(),
            FakeOther.mxMaster(),
            FakeOther.mxKeys(),
            device("keypad", "MX Creative Keypad", "device", "USB", firmware: "U1 66.00, build 0017", features: base + [0x1B04, 0x8040]),
            device("g305", "G305 Lightspeed Wireless Gaming Mouse", "mouse", "LIGHTSPEED", index: 6, wireless: 0x4074, battery: 90,
                   firmware: "RQM 68.02, build 0021", features: base + [0x1000, 0x1D4B, 0x2201, 0x8060, 0x8070, 0x8100]),
            device("g502", "G502 LIGHTSPEED Wireless Gaming Mouse", "mouse", "LIGHTSPEED", index: 3, wireless: 0x407F, battery: 88, millivolts: 4020,
                   firmware: "MPM 16.01, build 0020", features: base + [0x1001, 0x2121, 0x2201, 0x8060, 0x8070, 0x8100]),
            device("g9", "G9 Laser Mouse", "mouse", "USB", index: 0, firmware: "31.01, build 0012", models: "USB C048", usb: 0xC048, hidpp10: true),
            device("g700s", "G700s Gaming Mouse", "mouse", "Wireless", index: 1, wireless: 0x102A, firmware: "79.02, build 0016",
                   models: "Wireless 102A", usb: 0xC531, hidpp10: true),
            device("g500s", "G500s Laser Gaming Mouse", "mouse", "USB", index: 0, firmware: "86.01, build 0003", models: "USB C24E", usb: 0xC24E,
                   hidpp10: true),
            device("g502hero", "G502 HERO Gaming Mouse", "mouse", "USB", firmware: "U1 69.00, build 0009", features: base + [0x2201, 0x8060, 0x8070, 0x8100],
                   models: "USB C08B"),
            FakeHeadset.found(),
        ]
    }
}
