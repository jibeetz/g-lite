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
        DeviceTable(matches: { $0.isG && $0.isRgbKeyboard }, make: { LiveKeyboardPage(device: $0, hidpp: $1) }, fake: { _ in FakeG915() },
                    keeps: { "lighting." + $0.settingsKey }),
        DeviceTable(matches: { $0.isG && ($0.isLedKeyboard || $0.isG560) }, make: { ZonesPage(device: $0, hidpp: $1) },
                    fake: { $0.kind != "keyboard" ? FakeSpeaker() : $0.has(0x8080) ? FakeSpeaker.g512() : FakeSpeaker.g213Keyboard() }, keeps: { "lighting." + $0.settingsKey }),
        // The G305 loses its live light when switched off; the others keep what the mouse saved.
        DeviceTable(matches: { $0.isG9x }, make: { MousePage(device: $0, hidpp: $1, mouse: G9xMouse(.g9x)) }, fake: { _ in FakeG9x() }),
        DeviceTable(matches: { $0.isG5 }, make: { MousePage(device: $0, hidpp: $1, mouse: G5Mouse.g5()) }, fake: { _ in FakeG9x.short(0x82) }),
        DeviceTable(matches: { $0.isG9 }, make: { MousePage(device: $0, hidpp: $1, mouse: G5Mouse.g9()) }, fake: { _ in FakeG9x.short(0x84) }),
        DeviceTable(matches: { $0.isG600 }, make: { MousePage(device: $0, hidpp: $1, mouse: G600Mouse()) }, fake: { _ in FakeG600() }),
        DeviceTable(matches: { $0.isG300 }, make: { MousePage(device: $0, hidpp: $1, mouse: G300Mouse()) }, fake: { _ in FakeG300() }),
        DeviceTable(matches: { $0.isG500 }, make: { MousePage(device: $0, hidpp: $1, mouse: G9xMouse($0.g500Model)) },
                    fake: { _ in FakeG9x.g500s() }),
        DeviceTable(matches: { $0.isG && $0.isMouse }, make: { MousePage(device: $0, hidpp: $1, mouse: HidppMouse()) },
                    fake: { _ in FakeMouse.g502() },
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

    // What --demo lists.
    static func demoDevices() -> [FoundDevice] {
        let g213 = FoundDevice()
        g213.key = "demo|g213"; g213.name = "Gaming Keyboard G213"; g213.kind = "keyboard"; g213.link = "USB"
        g213.features = [0x0001, 0x0003, 0x0005, 0x8070]
        return [FakeG515.found(), FakeG915.found(), g213, FakeMouse.found(), FakeOther.mxMaster(), FakeOther.mxKeys(), FakeSpeaker.found(),
                FakeHeadset.found(), FakeLight.found(), FakeG510.found(), FakeG9x.found(),
                FakeG600.found(), FakeG300.found()]
    }
}
