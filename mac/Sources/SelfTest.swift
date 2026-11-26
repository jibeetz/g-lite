import Foundation

// The checks of app/SelfTest.cs that apply to what the Mac port does, with the same golden bytes from the real keyboard.
// `GLite --selftest` runs them; mac/build.sh stops when one fails.
enum SelfTest {
    static func check(_ ok: Bool, _ what: String) {
        if !ok { print("FAIL " + what); exit(1) }
    }

    static func hex(_ text: String) -> [UInt8] { Backups.bytes(text) }

    static func run() {
        FakeG515.latency = 0
        let factory = hex("0101003c012cffffffffffffffffffffffffffffffffffffffffffffffff18ff008180aaff00006400000000000000000000000019ff008180aaff0000640000000000000000000000000300000000000000000010000104000200ffffffffffffffff")
        let factoryDir = hex("5e380925010181014063996dec0101ff")
        let pyProfile = hex("0101003c012cffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000001ffffff000000000000000000000000000000000000017f7f7f000000000000000000000000000000000010000104000200ffffffffffffffff")

        check(G515Profile.crc32(Array(factoryDir[4...])) == 0x5e380925, "crc32")
        check(G515Profile.buildDirectory(factoryDir, pyProfile) == hex("8b5bf5610101810140639a0ad7d308ff"),
              "directory matches the one the keyboard accepted")

        var expected = pyProfile
        expected[45] = 0x02; expected[67] = 0x02
        let white = Lighting(effect: 0x01, color: 0xFFFFFF, dim: 50, idle: 60, sleep: 300)
        check(G515Profile.buildProfile(factory, white) == expected, "static white profile")
        check(G515Profile.decode(factory) == nil, "factory animation is unknown")

        for effect in G515Profile.effects {
            let lighting = Lighting(effect: effect.id, color: 0x3080FF,
                                    period: effect.speed ? (effect.minPeriod + effect.maxPeriod) / 2 : 5000,
                                    direction: 6, dim: 25, idle: 0, sleep: 900)
            let back = G515Profile.decode(G515Profile.buildProfile(factory, lighting))
            check(back != nil && back!.effect == lighting.effect && back!.idle == 0 && back!.sleep == 900, effect.name + " effect/timers")
            if effect.color { check(back!.color == lighting.color && back!.dim == 25, effect.name + " color/dim") }
            if effect.speed { check(back!.period == lighting.period, effect.name + " period") }
            if effect.direction { check(back!.direction == 6, effect.name + " direction") }
        }

        do {
            let fake = FakeG515()
            check(G515Profile.decode(try G515Profile.snapshot(fake).factoryProfile!) == nil, "fake starts on factory profile")
            let blue = Lighting(effect: 0x0A, color: 0x3080FF, period: 3000, dim: 25, idle: 30, sleep: 600)
            try G515Profile.claim(fake)
            try G515Profile.preview(fake, blue)
            check(fake.live[1] == 2 && fake.live[2] == 0x30, "preview sends breathe at effect index 2")
            try G515Profile.store(fake, try G515Profile.snapshot(fake), blue)
            check(G515Profile.decode(try G515Profile.snapshot(fake).userProfile!) == blue, "store then read back")
            try G515Profile.store(fake, try G515Profile.snapshot(fake), white)
            check(G515Profile.decode(try G515Profile.snapshot(fake).userProfile!) == white, "second store overwrites")

            Backups.root = FileManager.default.temporaryDirectory.appendingPathComponent("glite-selftest-" + UUID().uuidString)
            let keyboard = FakeG515()
            try G515Profile.store(keyboard, try G515Profile.snapshot(keyboard), blue)
            try Backups.save("T", try G515Profile.read(keyboard))
            try Backups.save("T", try G515Profile.read(keyboard))
            var saved = Backups.list("T")
            check(saved.count == 1 && saved[0].first && Backups.describe(saved[0].files) == "Breathe",
                  "first backup, and no copy of an unchanged keyboard")
            try G515Profile.store(keyboard, try G515Profile.snapshot(keyboard), white)
            try G515Profile.restore(keyboard, saved[0].files)
            check(G515Profile.decode(try G515Profile.snapshot(keyboard).userProfile!) == blue, "restoring a backup brings its lighting back")
            try G515Profile.restore(keyboard, G515Profile.Files())
            check(G515Profile.decode(try G515Profile.snapshot(keyboard).userProfile!) == nil,
                  "restoring the factory lighting brings the factory animation back")
            keyboard.flash[0x0008] = G515Profile.buildProfile(keyboard.flash[0x0008]!, white)
            var half = false
            do { _ = try G515Profile.snapshot(keyboard) } catch GLiteError.halfWritten { half = true }
            check(try half && !G515Profile.filesAreValid(G515Profile.read(keyboard)), "a directory that doesn't match its profile is caught")
            try G515Profile.restore(keyboard, saved[0].files)
            check(G515Profile.decode(try G515Profile.snapshot(keyboard).userProfile!) == blue, "a backup repairs a half written keyboard")
            var stranger = saved[0].files
            stranger.factoryDir![11] ^= 1
            var refused = false
            do { try G515Profile.restore(keyboard, stranger) } catch let error as GLiteError { refused = error.isRefusal }
            check(refused, "a backup from another keyboard is refused")
            var foreign = try G515Profile.read(keyboard)
            foreign.userDir![15] = 0x00
            var other = false, offered = false
            do { try G515Profile.checkFiles(foreign) } catch GLiteError.halfWritten { offered = true } catch GLiteError.refused { other = true }
            check(other && !offered, "profiles G-Lite didn't write are refused, not offered for restore")
            for i in 0..<Backups.keep + 3 {
                try G515Profile.store(keyboard, try G515Profile.snapshot(keyboard), Lighting(effect: 0x01, color: i + 1))
                try Backups.save("T", try G515Profile.read(keyboard))
            }
            saved = Backups.list("T")
            check(saved.count == Backups.keep + 1 && saved.filter { $0.first }.count == 1 && saved.last!.first,
                  "the first backup stays, with the last ten")
            try? FileManager.default.removeItem(at: Backups.root)
        } catch {
            check(false, "fake keyboard: \(error)")
        }

        let audio = Lighting(effect: 0xE2, color: 0x3080FF, intensity: 100, solid: true)
        check(audio.toText(40) == "226,3080FF,5000,1,50,60,300,40,100,1" && Lighting.fromText(audio.toText(40))?.0 == audio
              && Lighting(intensity: 30).toText(40).hasSuffix(",40,30") && Lighting().toText(40).hasSuffix(",300,40"),
              "the intensity and Solid are written only when set, and read back")

        let full = FoundDevice(), charging = FoundDevice(), unplugged = FoundDevice()
        for device in [full, charging, unplugged] { device.batteryId = 0x1001 }
        Devices.decode(full, [0x10, 0x72, 0x81])
        Devices.decode(charging, [0x10, 0x72, 0x80])
        Devices.decode(unplugged, [0x0F, 0x3C, 0x00])
        check(full.charging && full.battery == 100 && charging.charging && charging.battery == 68
              && !unplugged.charging && unplugged.battery == 66 && unplugged.millivolts == 3900,
              "battery voltage flags: charging, full, unplugged")

        check(FoundDevice.looksG("G515 LIGHTSPEED TKL") && FoundDevice.looksG("G Pro Wireless Gaming Mouse")
              && FoundDevice.looksG("PRO X Wireless Gaming Headset") && FoundDevice.looksG("G502 X PLUS")
              && !FoundDevice.looksG("MX KEYS S") && !FoundDevice.looksG("Logitech USB Receiver") && !FoundDevice.looksG("")
              && !FoundDevice.looksG("Gaming Keyboard") && !FoundDevice.looksG("Wireless Keyboard K270"),
              "G devices are told from other Logitech devices")
        func named(_ name: String) -> FoundDevice { let device = FoundDevice(); device.name = name; return device }
        check(named("G Pro Wireless Gaming Mouse").shortName == "G Pro Wireless" && named("G515 LIGHTSPEED TKL").shortName == "G515 TKL"
              && named("G915 WIRELESS RGB MECHANICAL GAMING KEYBOARD").shortName == "G915"
              && named("G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard").shortName == "G915 TKL",
              "short device names")
        check(FoundDevice.fromVolts(4200) == 100 && FoundDevice.fromVolts(3300) == 0 && FoundDevice.fromVolts(3800) == 50,
              "battery estimate from the voltage")
        check(FoundDevice.fromChargingVolts(4096) == 44 && FoundDevice.fromChargingVolts(4200) == 68
              && FoundDevice.fromChargingVolts(4300) == 68 && FoundDevice.fromChargingVolts(3000) == 2,
              "battery estimate from the charging voltage")
        check(FoundDevice.modelText(hex("0400000000000EB38940B4C35500")) == "USB C355, LIGHTSPEED 40B4, Bluetooth B389"
              && FoundDevice.modelText(hex("0300000000000C4079C0880000")) == "USB C088, LIGHTSPEED 4079"
              && FoundDevice.modelText(hex("01000000000003000000000ABA")) == "0ABA",
              "model ids per connection")
        let g515 = named("G515 LIGHTSPEED TKL")
        g515.features = [0x8071, 0x8040, 0x8101]
        check(g515.isG515 && !named("G515 RAPID TKL").isG515, "the G515 is told from the G515 RAPID")
        let dpis = MouseProtocol.dpiList(hex("000064e0326400"))
        check(dpis.count == 511 && dpis[0] == 100 && dpis[1] == 150 && dpis.last == 25600, "DPI range with a step")
        check(OtherSettings.fromText("dpi:1600,shift:255,invert:1,level:3,bogus:2").toText() == "dpi:1600,shift:255,invert:1,level:3"
              && OtherSettings.fromText("").toText() == "", "other devices' settings read back as written, skipping what isn't known")
        check(OtherDevice.supports(FakeOther.mxMaster()) && OtherDevice.supports(FakeOther.mxKeys())
              && !OtherDevice.supports(named("G Pro Wireless Gaming Mouse")) && !OtherDevice.supports(named("M720 Triathlon")),
              "a device that isn't a G device gets the other devices' screen only with a setting it can change")
        do {
            let mxMaster = FakeOther.mxMaster()
            mxMaster.features = [0x2110, 0x2121, 0x2201]
            let device = FakeOther()
            device.refuseDpi = true
            let read = try OtherDevice.read(device, mxMaster)
            var want = read.set
            want.merge(OtherDevice.keepSupported(OtherSettings.fromText("dpi:1625,invert:1,shift:120,thumb:1,bright:30,level:2"), read))
            let refused = try OtherDevice.apply(device, read, want, read.set)
            check(want.toText() == "dpi:1600,shift:10,invert:1" && refused == [OtherSettings.dpi] && device.wheel == 0x04 && device.shift == 10,
                  "other devices: a setting the device lacks or out of range isn't sent, and a refused one doesn't stop the others")

            let keyboard = FakeOther()
            var state = try OtherDevice.read(keyboard, FakeOther.mxKeys())
            check(state.set.toText() == "light:1,auto:0,level:3,away:30,near:30,powered:300,saver:1,mediakeys:1,disabled:0" && state.levels == 8
                  && state.hosts == 3 && state.layoutCode == 0x0D
                  && state.names[0] == "Desk PC" && state.names[1] == "MacBook" && !state.paired[2],
                  "the MX Keys S's backlight, its fade delays, battery saving, F1–F12 and its computers read as its report says")
            var brighter = state.set
            brighter[OtherSettings.level] = 6
            brighter[OtherSettings.away] = 60
            _ = try OtherDevice.apply(keyboard, state, brighter, state.set)
            state = try OtherDevice.read(keyboard, FakeOther.mxKeys())
            check(state.set[OtherSettings.level] == 6 && state.set[OtherSettings.away] == 60 && state.set[OtherSettings.powered] == 300,
                  "the backlight's level and one fade delay are written, the other delays kept")
            let mini = FakeOther.mxMini()
            mini.features = [0x1982, 0x40A3, 0x4521]
            let miniDevice = FakeOther.make(mini)
            let miniRead = try OtherDevice.read(miniDevice, mini)
            var miniWant = miniRead.set
            miniWant.merge(OtherDevice.keepSupported(OtherSettings.fromText("effect:6,saver:0,mediakeys:0,disabled:19"), miniRead))
            let miniRefused = try OtherDevice.apply(miniDevice, miniRead, miniWant, miniRead.set)
            let effectSent = miniDevice.effect
            miniDevice.effect = 1
            let unlisted = try OtherDevice.read(miniDevice, mini)
            check(miniRead.set.toText().contains("effect:0,saver:1,mediakeys:1,disabled:0") && miniRefused.isEmpty && effectSent == 6
                  && miniDevice.backlight[1] & 0x04 == 0 && miniDevice.backlight[1] >> 3 & 3 == 3 && miniDevice.mediaKeys == 0
                  && miniDevice.disabledKeys == 0x11 && unlisted.set[OtherSettings.effect] == 0xFF,
                  "MX keyboards: the effect in fn 1 b2, battery saving as options bit 2, F1–F12 in 0x40A3 fn 1, the disabled keys the keyboard"
                  + " can disable as 0x4521 fn 2's bits (no Num Lock on the Mini), and an effect not in the list read as FF")
            // Turned off, the Mini reads its stored level as 0; turning it on again sends the level the screen shows.
            let darkDevice = FakeOther.make(mini)
            let litRead = try OtherDevice.read(darkDevice, mini)
            darkDevice.backlight[0] = 0
            darkDevice.backlight[5] = 0
            var offRead = litRead
            offRead.set[OtherSettings.light] = 0
            var turnOn = offRead.set
            turnOn[OtherSettings.light] = 1
            _ = try OtherDevice.apply(darkDevice, offRead, turnOn, offRead.set)
            check(darkDevice.backlight[0] == 1 && darkDevice.backlight[5] == 7,
                  "MX keyboards: turning the backlight on again sends the level shown, not the 0 the keyboard reads while off")
            let diverted = FakeOther.mxMini()
            diverted.features = [0x1982, 0x1B04]
            let divertedDevice = FakeOther.make(diverted)
            let released = try OtherDevice.releaseDiverted(divertedDevice)
            let divertedRead = try OtherDevice.read(divertedDevice, diverted)
            // The keyboard's own keys set level 5 after the read; a fade delay changed on the screen keeps it.
            divertedDevice.backlight[5] = 5
            var delayed = divertedRead.set
            delayed[OtherSettings.away] = 120
            _ = try OtherDevice.apply(divertedDevice, divertedRead, delayed, divertedRead.set)
            check(released == 3 && divertedDevice.reporting.allSatisfy { $0 == 0 } && divertedDevice.backlight[5] == 5,
                  "0x1B04: the three diverted controls given back (fn 3 with the valid bit, the flag off), none diverted; in manual mode, a"
                  + " backlight change keeps the level stored on the keyboard")
        } catch {
            check(false, "fake other device: \(error)")
        }
        layouts()
        presetTexts()
        bindings()
        gameMode()
        litraTry()
        report()
        screenSetup()
        liveEffects()
        mice()
        oldMice()
        reportMice()
        g915()
        zones()
        lights()
        let g510 = FakeG510.found()
        let g510Name = FoundDevice()
        g510Name.name = "G510 Gaming Keyboard"
        check(g510Name.shortName == "G510" && FoundDevice.looksG("G510 Gaming Keyboard") && g510.isG && g510.isG510 && !FoundDevice().isG510
              && G510Lighting.frame(G510Settings(color: 0xFF2020, bright: 50), 0) == 0x7F1010
              && G510Lighting.frame(G510Settings(on: false), 0) == 0
              && G510Lighting.frame(G510Settings(effect: G510Settings.breathe, period: 2000), 1000) == 0xFFFFFF
              && G510Lighting.frame(G510Settings(effect: G510Settings.breathe, period: 2000), 0) == 0
              && G510Lighting.frame(G510Settings(effect: G510Settings.cycle), 0) == 0xFF0000
              && G510Settings.fromText(G510Settings(on: false, color: 0x3080FF, bright: 40).toText())!.same(G510Settings(on: false, color: 0x3080FF, bright: 40))
              && G510Settings.fromText(G510Settings(effect: G510Settings.cycle, period: 3000).toText())!.same(G510Settings(effect: G510Settings.cycle, period: 3000))
              && G510Settings.fromText("1,FF0000,100")!.effect == G510Settings.staticEffect,
              "the G510 gets its screen only with its vendor collection's port, and its backlight is the colour scaled by brightness")
        do {
            let keyboard = FakeG510()
            check(try G510Lighting.read(keyboard) == 0xFFFFFF, "the G510s's backlight reads as its owner's report says")
            try G510Lighting.set(keyboard, 0x7F1010)
            check(keyboard.features[0x05]! == [0x05, 0x7F, 0x10, 0x10] && keyboard.writes == 1, "the backlight is set as 05 R G B")
            let g510Keys = G510Keys.fromText("80020105 800300E9 nonsense")
            let switched = FakeG510()
            switched.gameMode = true
            let litBefore = try G510Keys.litBank(switched, 2)
            let switchOn = try G510Keys.gameMode(switched), switchOff = try G510Keys.gameMode(FakeG510())
            try G510Keys.lightBank(switched, 2)
            let litAfter = try G510Keys.litBank(switched, 0)
            check(g510Keys.count == 18 && G510Keys.toText(g510Keys).hasPrefix("80020105 800300E9 80000000 ")
                  && G510Keys.fromText(G510Keys.toText(g510Keys)) == g510Keys
                  && switchOn && !switchOff && litBefore == 0 && switched.features[0x04]![1] == 0x20 && litAfter == 2
                  && KeyLayout.load("g510.json")!.keyIds().filter { $0 >= 0 }.count == 18 + 104,
                  "the G510's G key bindings read back from their text, unbound keys as Disabled; its Game mode switch is bit 2 of byte 3 of "
                  + "input report 03; M1 to M3 light as 80, 40 and 20 in feature 04; its picture lights the 18 G keys and the 104 others")
        } catch {
            check(false, "fake G510: \(error)")
        }
        do {
            let headset = FakeHeadset()
            let state = try HeadsetProtocol.read(headset, autoOff: true)
            check(state.hasSidetone && state.hasOff && state.set.sidetone == 30 && state.set.autoOffMinutes == 30 && state.millivolts == 3926
                  && !state.charging, "headset sidetone, auto-off and battery are read")
            try HeadsetProtocol.setSidetone(headset, 55)
            try HeadsetProtocol.setOff(headset, 10)
            check(headset.sidetone == 55 && headset.autoOffMinutes == 10, "headset sidetone and auto-off are set")
            try HeadsetProtocol.setEqualizer(headset, [-12, 0, 0, 0, 0, 0, 0, 0, 0, 12], keep: true)
            check(state.frequencies == FakeHeadset.frequencies && state.range == 12 && state.set.bands == [0, 0, 0, 0, 0, 1, 3, 5, 6, 6]
                  && headset.persistence == 1 && headset.bands.first == -12 && headset.bands.last == 12
                  && HeadsetSettings.fromText("30,10,1 -2 3") == HeadsetSettings(sidetone: 30, autoOffMinutes: 10, bands: [1, -2, 3])
                  && HeadsetSettings.fromText("30,10")?.bands == nil && state.set.text == "30,30,0 0 0 0 0 1 3 5 6 6",
                  "the equalizer's bands, frequencies and range are read (0x8310), written signed with persistence 1, and kept in presets")
            let noOff = try HeadsetProtocol.read(FakeHeadset(), autoOff: false)
            check(noOff.hasSidetone && !noOff.hasOff, "auto-off is read only on the headsets known to have it")
        } catch {
            check(false, "fake headset: \(error)")
        }
        print("selftest ok")
    }

    // app/SelfTest.cs's Litra checks.
    static func lights() {
        var state = LightState(frontOn: true, backOn: false, lumen: 120, kelvin: 5000, backLevel: 40)
        state.colors = [1, 2, 3, 4, 5, 6, 0xFF0000]
        var copy = LightState()
        check(copy.readFront(state.frontText()) && copy.readBack(state.backText()) && copy.frontText() == state.frontText()
              && copy.backText() == state.backText() && !copy.readBack("1,50,FFFFFF"),
              "the light's settings round-trip through text, with all seven zones")
        var breathe = LightState(effect: LightState.breathe, period: 4000)
        breathe.colors = [Int](repeating: 0xFF8000, count: 7)
        let wave = LightState(effect: LightState.wave, period: 7000)
        var waveCopy = LightState()
        check(LitraProtocol.frame(breathe, 0)[0] == 0 && LitraProtocol.frame(breathe, 2000)[3] == 0xFF8000
              && abs((LitraProtocol.frame(breathe, 1000)[6] >> 16) - 128) <= 1
              && LitraProtocol.hue(0) == 0xFF0000 && LitraProtocol.hue(1.0 / 3) == 0x00FF00 && LitraProtocol.hue(-1.0 / 3) == 0x0000FF
              && LitraProtocol.frame(wave, 1000)[1] == LitraProtocol.frame(wave, 0)[0]
              && LitraProtocol.frame(LightState(effect: LightState.cycle, period: 3000), 1000).allSatisfy { $0 == 0x00FF00 }
              && waveCopy.readBack(wave.backText()) && waveCopy.effect == LightState.wave && waveCopy.period == 7000
              && !waveCopy.readBack("1,50,FFFFFF/FFFFFF/FFFFFF/FFFFFF/FFFFFF/FFFFFF/FFFFFF,9,5000"),
              "the light's breathe, cycle and wave frames, and its effect round-trips through text")
        do {
            let light = FakeLight()
            let lumens = try LitraProtocol.lumens(light), kelvins = try LitraProtocol.kelvins(light)
            try LitraProtocol.colors(light, [0x000000, 0xFF0000, 0x00FF00, 0x0000FF, 0x123456, 0xFFFFFF, 0x808080])
            check(lumens.min == 30 && lumens.max == 400 && kelvins.min == 2700 && kelvins.max == 6500 && kelvins.step == 100
                  && kelvins.snap(4049) == 4000 && light.colors[0] == 0x010101 && light.colors[1] == 0xFF0101 && light.colors[6] == 0x808080
                  && light.frames == 1, "the light reads its ranges, and sets its seven back zones in two messages and one frame")
        } catch {
            check(false, "fake light: \(error)")
        }
    }

    // app/SelfTest.cs's zone lighting checks.
    static func zones() {
        let g513 = FakeSpeaker.g512()
        var g513Sent: [String] = []
        Hidpp.tap = { g513Sent.append($0) }
        try? ZoneLighting.sendKeys(g513, [0x01: 0xFF0000, 0x02: 0x00FF00, 0x03: 0x0000FF, 0x68: 0x101010, -1: 0xFFFFFF])
        Hidpp.tap = nil
        check(g513.keyColors.count == 4 && g513.keyColors[0x04] == 0xFF0000 && g513.keyColors[0x06] == 0x0000FF && g513.keyColors[0xE0] == 0x101010
              && g513.frames == 1 && g513Sent.count == 3 && g513Sent.first == "8080 fn3  00 01 00 03 04 FF 00 00 05 00 FF 00 06 00 00 FF"
              && g513Sent.last == "8080 fn5", "0x8080 colours go three keys to a message by USB usage (modifiers E0-E7), and fn 5 shows them")
        let rain = ZoneLighting.fromText("227,FFFFFF,1200,100,2", 6), aurora = ZoneLighting.parse("229,FFFFFF,20000,80")
        check(rain?[0]?.effect == 0xE3 && rain?[0]?.direction == 2 && ZoneLighting.toText([rain![0]]) == "227,FFFFFF,1200,100,2"
              && aurora?.direction == 7 && ZoneLighting.parse("254,FFFFFF,100,100") == nil,
              "a live effect from a G512 or G513 reads and writes as on Windows, its direction too; Screen isn't one of them")
        let audio = ZoneLighting.fromText("226,FF8000,5000,80", 6)
        check(audio?.count == 6 && audio?[5]?.effect == 0xE2 && audio?[5]?.bright == 80 && ZoneLighting.toText([audio![0]]) == "226,FF8000,5000,80,7"
              && ZonesPage.scale(0xFF8040, 0.5) == 0x7F4020,
              "a zones keyboard's Audio light reads and writes as on Windows, and its colour scales with the sound's level")
        func named(_ name: String, _ kind: String, _ features: [Int]) -> FoundDevice {
            let device = FoundDevice(); device.name = name; device.kind = kind; device.features = features; return device
        }
        let g213 = named("Gaming Keyboard G213", "keyboard", [0x8070]), g512 = named("G512 RGB MECHANICAL GAMING KEYBOARD", "keyboard", [0x8070, 0x8080])
        check(g213.isG && g213.shortName == "G213" && g213.isLedKeyboard && g512.isLedKeyboard && g512.shortName == "G512"
              && !named("G515 LIGHTSPEED TKL", "keyboard", [0x8070, 0x8071]).isLedKeyboard && !named("G502 HERO Gaming Mouse", "mouse", [0x8070]).isLedKeyboard
              && named("G560 Gaming Speaker", "device", [0x8070]).isG560 && !named("G560 Gaming Speaker", "device", [0x8040]).isG560
              && ZoneLighting.zoneName(1, 0) == "Keys" && ZoneLighting.zoneName(8, 3) == "Zone 3" && ZoneLighting.zoneName(0, 1) == "Zone 2",
              "a keyboard with 0x8070 and no 0x8071 gets the zones screen, the G560 needs its lighting feature, zones are named from their location")
        let wave = MouseLight(effect: 0x04, period: 0x1388, bright: 80, direction: 3)
        check(ZoneLighting.encode(wave) == [0, 0, 0, 0, 0, 0, 0x88, 3, 80, 0x13] && ZoneLighting.fromText(ZoneLighting.toText([wave]), 1)![0] == wave
              && ZoneLighting.fromText("1,FF0000,5000,100", 1)![0]!.direction == 6,
              "0x8070 Wave is encoded with its direction and kept in text")
        let breathe = MouseLight(effect: 0x0A, color: 0x30D050, period: 4800, bright: 50)
        let lights = ZoneLighting.fromText(ZoneLighting.toText([breathe, nil, MouseLight(), breathe]), 4)
        let oneForAll = ZoneLighting.fromText("1,FF0000,5000,100", 4)
        check(lights != nil && lights![0] == breathe && lights![1] == nil && lights![2] == MouseLight() && lights![3] == breathe
              && oneForAll!.allSatisfy { $0?.color == 0xFF0000 } && ZoneLighting.fromText("7,FFFFFF,1000,100", 4) == nil
              && ZoneLighting.fromText("", 4) == nil,
              "speaker zone lighting round-trips through text, one light sets every zone, unknown effects are dropped")
        do {
            let (g413Zones, g413Monochrome) = try ZoneLighting.zones(FakeSpeaker.g413Silver())
            let speakers = FakeSpeaker()
            let (speakerZones, speakersMonochrome) = try ZoneLighting.zones(speakers)
            check(g413Monochrome && !speakersMonochrome && g413Zones.count == 1 && g413Zones[0][ZoneLighting.place] == 1
                  && g413Zones[0][0x0A] != nil && g413Zones[0][0x03] == nil && speakerZones.count == 4,
                  "a G413 Silver's 0x8070 says monochrome (fn 0 byte 4 bit 3), the speakers' doesn't")
            try ZoneLighting.setLight(speakers, 2, speakerZones[2], breathe)
            try ZoneLighting.setLight(speakers, 1, speakerZones[1], wave)
            check(speakers.live[2] == [2, 4, 0x30, 0xD0, 0x50, 0x12, 0xC0, 0, 50, 0, 0, 0] && speakers.live[1].isEmpty,
                  "a zone gets its effect at its own index, and an effect it lacks isn't sent")
            let (g213Zones, _) = try ZoneLighting.zones(FakeSpeaker.g213Keyboard())
            check(g213Zones.count == 6 && g213Zones[0][ZoneLighting.place] == 1 && ZoneLighting.isArea(g213Zones[3][ZoneLighting.place]!)
                  && g213Zones[3][0x0A] == nil, "the G213's zone 0 is the whole keyboard and its five areas take Off and Static only")
        } catch {
            check(false, "fake speakers: \(error)")
        }
    }

    // app/SelfTest.cs's G915 checks.
    static func g915() {
        do {
            let g915 = FakeG915()
            let (clusters, vertical) = try G915Lighting.clusters(g915)
            check(clusters.count == 2 && G915Lighting.keys(clusters) == 1, "the G915's keys are the cluster with the most effects")
            let (slots, running, onboard) = try G915Lighting.slots(g915)
            check(slots == [1, 2, 3] && running == 1 && onboard, "the onboard profiles are the directory's enabled sectors, M1 to M3")
            let (stock, _, buttons) = try G915Lighting.readProfile(g915)
            let keys = G915Lighting.readButtons(stock, 12)
            var edited = keys
            edited[0] = Bindings.mouseActions.first { $0.name == "Mute" }!.bytes
            var elsewhere = stock
            elsewhere.replaceSubrange(0x24..<0x28, with: [0x80, 0x00, 0x00, 0x00])
            let withKeys = G915Lighting.withButtons(elsewhere, edited, keys)
            check(buttons == 15 && keys[0] == [0x80, 0x02, 0x00, 0x3A] && keys[11] == [0x80, 0x02, 0x00, 0x45]
                  && Array(withKeys[0x20..<0x24]) == [0x80, 0x03, 0x00, 0xE2] && Array(withKeys[0x24..<0x28]) == [0x80, 0x00, 0x00, 0x00]
                  && MouseProtocol.valid(withKeys) && withKeys.count == stock.count,
                  "the G915 TKL's G keys are its profile's first 12 buttons (F1-F12); a save writes only the keys edited, with a new checksum")
            var factory = stock
            factory.replaceSubrange(0x20..<0x24, with: [0x80, 0x00, 0x00, 0x00])
            let factoryKeys = try G915Lighting.factoryButtons(g915, 1, factory, 12)
            check(G915Lighting.readButtons(factoryKeys, 12) == keys && MouseProtocol.valid(factoryKeys) && Bindings.keyboardActions.allSatisfy { $0.bytes[0] == 0x80 }
                  && !Bindings.keyboardActions.isEmpty, "the factory G keys come from the factory copy; the G keys offer only the mouse's 80 actions")
            func kind(_ name: String) -> KeyboardKind {
                let device = FoundDevice(); device.name = name; device.kind = "keyboard"; device.features = [0x8040, 0x8071, 0x8100]; return KeyboardKind.of(device)
            }
            check(kind("G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard").gKeys?.count == 12
                  && kind("G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard").gKeysExperimental
                  && kind("G815 RGB MECHANICAL GAMING KEYBOARD").gKeys == ["G1", "G2", "G3", "G4", "G5"]
                  && kind("G815 RGB MECHANICAL GAMING KEYBOARD").gKeysExperimental == false,
                  "the G915 TKL's G keys are F1-F12 and the G815's G1-G5, as on Windows")
            check(try G915Lighting.clusters(FakeG515()).verticalWave && !vertical,
                  "Wave goes up and down when its capabilities say so (the G515's DC E1), not otherwise")
            try G915Lighting.claim(g915)
            try G915Lighting.preview(g915, clusters, Lighting(effect: 0x15, period: 3000))
            check(g915.claimed == 3 && g915.live[1][1] == 3 && g915.live[1][7] == 0x0B && g915.live[1][8] == 0xB8 && g915.live[1][9] == 100
                  && g915.live[1][12] == 1, "cycle on the G915 uses effect 0x03, with its period at byte 5")
            check(g915.live[0][1] == 2 && g915.live[0][7] == 0x0B, "the logo cycles too")
            try G915Lighting.preview(g915, clusters, Lighting(effect: 0x16, period: 4000, direction: 1))
            check(g915.live[1][1] == 4 && g915.live[1][8] == 0xA0 && g915.live[1][9] == 1 && g915.live[1][10] == 100 && g915.live[1][11] == 0x0F,
                  "wave on the G915 uses effect 0x04")
            check(g915.live[0][1] == 2, "the logo cycles when the keys wave")
            try G915Lighting.preview(g915, clusters, Lighting(effect: 0x17, color: 0x3080FF, period: 20))
            check(g915.live[1][1] == 5 && g915.live[1][2] == 0x30 && g915.live[1][7] == 20 && g915.live[0][1] == 1 && g915.live[0][4] == 0xFF,
                  "ripple on the keys, the ripple's colour on the logo")
            try G915Lighting.preview(g915, clusters, Lighting(effect: 0x0A, color: 0xFF0000, period: 5000))
            check(g915.live[1][1] == 2 && g915.live[0][1] == 3 && g915.live[1][5] == 0x13 && g915.live[1][6] == 0x88, "breathe on keys and logo")
            var lacks = false
            do { try G915Lighting.preview(g915, clusters, Lighting(effect: 0x02)) } catch GLiteError.refused { lacks = true }
            check(lacks && g915.live[1][1] == 2, "an effect the G915 lacks is refused without sending anything")
            try G915Lighting.release(g915)
            check(g915.claimed == 0, "release gives the lighting back to the G915")

            let (profile, sector, _) = try G915Lighting.readProfile(g915)
            let saved = G915Lighting.decode(profile, 1)!
            check(sector == 1 && saved.effect == 0x15 && saved.period == 10000 && saved.idle == 60 && saved.sleep == 300 && saved.dim == 50,
                  "the G915 TKL's profile reads as Cycle at 10 s, dimmed to half after 60 s, off after 300 s")
            let built = try G915Lighting.build(profile, clusters, Lighting(effect: 0x16, period: 3000, direction: 1, dim: 50, idle: 15, sleep: 600),
                                               nil, idleTimes: true)
            // Profile 3 of the same keyboard, Cycle on the logo and Wave on the keys, normal then dimmed.
            let want = hex("0300000000000BB864000004000000000000B801640B0300000000000BB832000004000000000000B801320B")
            check(Array(built[0xD0..<0xD0 + 44]) == want && MouseProtocol.valid(built) && built[0x1C] == 15 && built[0x1E] == 0x58 && built[0x1F] == 2
                  && (0..<0xD0).allSatisfy { ($0 >= 0x1C && $0 <= 0x1F) || built[$0] == profile[$0] },
                  "saving Wave on the G915 writes the records the keyboard's own Wave profile has, the idle times, and keeps every other byte")
            // Profile 2 of an owner's G815 (256-byte sectors): Breathe, no idle times, the power-save records copies of the others.
            let g815Profile = hex("01000000000000000000000000" + String(repeating: "F", count: 30) + "00000000"
                + "8002001E8002001F800200208002002180020022900DFF01900DFF02900DFF03" + String(repeating: "F", count: 192)
                + String(repeating: "0", count: 96) + String(repeating: "0A00DCFF0BB80000000000", count: 4) + "FFFF74A5")
            let g815Saved = G915Lighting.decode(g815Profile, 1)!
            let g815Built = try G915Lighting.build(g815Profile, clusters, Lighting(effect: 0x01, color: 0xFF0000, dim: 50, idle: 60, sleep: 300),
                                                   nil, idleTimes: false)
            check(g815Profile.count == 256 && MouseProtocol.valid(g815Profile) && g815Saved.effect == 0x0A && g815Saved.color == 0x00DCFF
                  && g815Saved.period == 3000 && g815Saved.idle == 0 && MouseProtocol.valid(g815Built)
                  && g815Built[0xD0..<0xE6] == g815Built[0xE6..<0xFC] && g815Built[0xDB] == 0x01 && g815Built[0xDC] == 0xFF
                  && g815Built[0..<0xD0] == g815Profile[0..<0xD0] && g815Built[0xFC] == 0xFF && g815Built[0xFD] == 0xFF,
                  "the G815's profile reads, and saving keeps its idle times at 0 and writes the power-save records as copies, as G HUB does")
            try G915Lighting.claim(g915)
            try G915Lighting.store(g915, sector, built)
            check(g915.sectors[1]! == built && g915.reloads == 1 && g915.claimed == 0 && g915.modes == [1],
                  "the G915's profile is written, loaded again, the lighting given back, and it stays in onboard mode")
            let g815 = FakeG915()
            try G915Lighting.store(g815, sector, built, reloadThroughHostMode: true)
            check(g815.reloads == 1 && g815.modes == [1, 2, 1],
                  "the G815's profile is loaded again by leaving onboard mode and coming back, which ends in onboard mode")
            let restored = try G915Lighting.factoryLighting(g915, 1, built)
            check(G915Lighting.decode(restored, 1)?.period == 5000 && restored[0x1C] == 0x3C && restored[0x20..<0xD0] == built[0x20..<0xD0],
                  "the factory lighting comes back with its idle times, and the rest of the profile stays")
        } catch {
            check(false, "fake G915: \(error)")
        }
    }

    // app/SelfTest.cs's per-key checks, and the live effects' frames.
    static func liveEffects() {
        do {
            let keyboard = FakeG515()
            check(try KeyLights.present(keyboard).count == 94, "the fake reports 94 lighting ids")
            var individual = true
            var colors: [Int: Int] = [:]
            for id in 0x01...0x14 { colors[id] = 0xFF0000 }
            colors[0x61] = 0x0000FF; colors[0x6F] = 0x00FF00
            try KeyLights.sendColors(keyboard, colors, individual: &individual)
            check(keyboard.keys.count == 22 && keyboard.keys[0x14] == 0xFF0000 && keyboard.keys[0x61] == 0x0000FF && keyboard.keys[0x6F] == 0x00FF00
                  && keyboard.frames == 1 && individual, "per-key colours go out in groups of 13 or four by four, and end with a frame")
            let busy = FakeG515()
            busy.busyFrames = 3
            try KeyLights.sendColors(busy, [0x04: 0xFF0000, 0x05: 0x00FF00], individual: &individual)
            let shown = busy.frames == 1 && busy.busyFrames == 0
            busy.busyFrames = 25
            var gaveUp = false
            do { try KeyLights.sendColors(busy, [0x06: 0x0000FF], individual: &individual) } catch let error as GLiteError { gaveUp = error.code == 8 }
            check(shown && gaveUp && busy.frames == 1 && busy.busyFrames == 5, "a busy fn 7 is sent again until the frame shows, and after 20 tries the error stands")
        } catch {
            check(false, "per-key lighting: \(error)")
        }
        var field = KeyField()
        field.ids = Array(1...40)
        field.x = (0..<40).map { Double($0 % 10) / 9 }
        field.y = (0..<40).map { Double($0 / 10) / 3 }
        var allInRange = true
        // Not Audio and Screen: they start the screen capture, which would ask for the Screen Recording permission during the build.
        for info in LiveEffects.all where info.id != 0xE2 && info.id != 0xFE {
            guard let effect = LiveEffects.make(info.id) else { allInRange = false; continue }
            effect.period = info.defaultPeriod
            var colors = [Int](repeating: -1, count: field.count)
            for step in 1...20 { effect.frame(field, Double(step) * 0.04, 0.04, &colors) }
            allInRange = allInRange && colors.allSatisfy { $0 >= 0 && $0 <= 0xFFFFFF }
            effect.stop()
        }
        check(allInRange && Fire.color(0) == 0 && Fire.color(1) == 0xFFD040 && Fire.color(0.4) == 0xFF0000
              && LiveEffects.blend(0x000000, 0xFF0000, 0.5) == 0x800000 && KeyPresses.lightingId(KeyPresses.usages[0x00]!) == 0x01
              && KeyPresses.usages[0x31] == 0x2C && KeyPresses.lightingId(0xE0) == 0x68 && field.along(7)[0] == 1 && field.lanes(2, 10)[9] == 9,
              "each live effect draws a colour for every key; Fire runs black, red, orange, yellow; macOS key codes map to USB usages")
        var real = (0..<1024).map { sin(2 * Double.pi * 64 * Double($0) / 1024) }, imaginary = [Double](repeating: 0, count: 1024)
        ScreenSource.fourier(&real, &imaginary)
        let peak = (0..<512).max { hypot(real[$0], imaginary[$0]) < hypot(real[$1], imaginary[$1]) }
        check(LiveEffects.boost(0x804020, 0) == 0xFF7F3F && (LiveEffects.boost(0x806060, 100) & 0xFF) < 0x60 * 255 / 0x80
              && LiveEffects.boost(0x050505, 33) == 0 && peak == 64 && AudioEffect.hue(255, 0, 0) == 0 && abs(AudioEffect.hue(0, 255, 0) - 1.0 / 3) < 0.001,
              "the screen's boost keeps the hue and brightens to full, the Fourier transform finds a tone, and hues match .NET's")
    }

    // The key layouts: each loads, and its ISO picture is the one Windows built (app/models/iso, read from the repo when the build runs
    // from mac/).
    static func layouts() {
        let files = ["g515-tkl.json", "g915-tkl.json", "g915.json", "g915-x.json", "g915-x-tkl.json", "g815.json", "g512-x-75.json",
                     "g-full.json", "g-60.json", "g213.json", "g413.json", "g510.json", "g-pro.json", "g410.json", "g810.json",
                     "g910.json", "mx-mechanical-mini.json", "mx-keys-s.json"]
        for file in files {
            guard let layout = KeyLayout.load(file) else { check(false, "the layout \(file) loads"); continue }
            check(layout.rows.count > 3 && layout.keyIds().count == layout.keyNames().count, "the layout \(file) loads")
            let isoFile = URL(fileURLWithPath: "../app/models/iso/" + file.replacingOccurrences(of: ".json", with: "-iso.json"))
            guard let data = try? Data(contentsOf: isoFile), let expected = KeyLayout.parse(data) else { continue }
            let built = layout.iso()
            check(built?.rows == expected.rows && built?.ids == expected.ids, "the ISO picture of \(file) is the one Windows built")
        }
        if let g213 = KeyLayout.load("g213.json") {
            check(g213.zones && g213.keyIds().allSatisfy { (1...5).contains($0) } && g213.iso()!.keyIds().allSatisfy { (1...5).contains($0) },
                  "every G213 key has a zone, on the ISO picture too")
        }
        check(!KeyLayout.isIso(0) && !KeyLayout.isIso(1) && KeyLayout.isIso(2) && KeyLayout.isIso(0x0D), "layout codes 2 and up are ISO")
    }

    // app/SelfTest.cs's G300 and G600 checks.
    static func reportMice() {
        let g300Report = FakeG300().profiles[1]
        let g300 = G300Mouse.decode(g300Report)
        check(!g300.readOnly && g300.saveOnly && g300.writable && g300.stages == [1000, 2000, 2500, 2000] && g300.stage == 1 && g300.dpi == 2000
              && g300.rate == 500 && g300.light?.effect == 0x01 && g300.light?.color == 0x0000FF && g300.buttons!.count == 9
              && g300.buttons![5] == hex("80020106") && g300.buttons![8] == hex("90070000") && G300Mouse().defaultStage(g300Report) == 1
              && (try? G300Mouse.build(g300Report, MouseSettings(dpi: g300.dpi, rate: g300.rate, stage: g300.stage, light: g300.light,
                                                                buttons: g300.buttons))) == g300Report
              && G300Mouse.entry(hex("80010010")) == hex("050000") && G300Mouse.entry(hex("900A0000")) == hex("0D0000")
              && G300Mouse.entry(hex("80020106")) == hex("000106") && G300Mouse.entry(hex("90010000")) == nil
              && G300Mouse.colorBits(MouseLight(color: 0xFFD000)) == 3 && G300Mouse.colorBits(MouseLight(color: 0x202020)) == 7
              && G300Mouse.colorBits(MouseLight(color: 0x7F0000, bright: 40)) == 1 && G300Mouse.colorBits(MouseLight(effect: 0x00)) == 0
              && G300Mouse.entry(hex("90080000")) == hex("0D0000") && G300Mouse.binding(hex("0D0000"), 0) == hex("90080000")
              && g300.effects.map { $0.id } == [0x00, 0x01]
              && G300Mouse.decode(hex("F302000284060A40" + String(repeating: "0", count: 54))).stage == 1,
              "G300: the profile report decodes (DPI × 250, the 0x80 default, rate codes, colour bits, buttons), builds back to the same "
                + "bytes, and maps bindings both ways")
        var rightChanged = g300.buttons!
        rightChanged[1] = hex("80010008")
        var dpiRefused = false, rightRefused = false
        do { _ = try G300Mouse.build(g300Report, MouseSettings(dpi: 2600, stage: 0)) } catch GLiteError.refused { dpiRefused = true } catch {}
        do { _ = try G300Mouse.build(g300Report, MouseSettings(dpi: g300.dpi, stage: g300.stage, buttons: rightChanged)) }
        catch GLiteError.refused { rightRefused = true } catch {}
        check(dpiRefused && rightRefused, "G300: a DPI it can't take and a change to the right button are refused, not dropped")
        var unreadLevel = g300Report
        // Byte 4 is level 2, the default: 0x80 alone reads as 0 DPI.
        unreadLevel[4] = 0x80
        check((try? G300Mouse.build(unreadLevel, MouseSettings(dpi: 0, stage: 1, light: MouseLight(effect: 0x01, color: 0xFF0000))))?[4] == 0x80,
              "G300: a level read outside 250 to 2500 DPI stays as it was when a save changes something else")
        var otherProfileRefused = false
        // The report shown is profile 2's, the fake mouse on profile 1.
        do { try G300Mouse().save(FakeG300(), g300, g300Report, MouseSettings(dpi: g300.dpi, stage: g300.stage)) }
        catch GLiteError.refused { otherProfileRefused = true } catch {}
        check(otherProfileRefused, "G300: Save refuses when the mouse's profile button moved it off the profile shown")
        do {
            let mouse = FakeG300()
            let state = try G300Mouse().read(mouse)
            try G300Mouse().save(mouse, state, try G300Mouse().readProfile(mouse, state), MouseSettings(dpi: 1250, stage: 2, light: MouseLight(color: 0xFF0000)))
            let saved = try G300Mouse().read(mouse)
            check(saved.stages[2] == 1250 && saved.stage == 2 && saved.light?.color == 0xFF0000 && saved.stages[0] == state.stages[0],
                  "G300: a save writes the whole profile report and reads back")
        } catch {
            check(false, "fake G300: \(error)")
        }
        let g600Report = FakeG600().modes[2]
        let g600 = G600Mouse.decode(g600Report, 3)
        check(g600.readOnly && !g600.writable && g600.stages == [400, 1200, 2000, 3200] && g600.stage == 3 && g600.dpi == 3200
              && g600.rate == 1000 && g600.light?.effect == 0x0A && g600.light?.color == 0x00FF00 && g600.light?.period == 4000
              && g600.buttons!.count == 20 && G600Mouse().defaultStage(g600Report) == 1
              && G600Mouse.binding(hex("070000"), 0) == hex("80010040") && G600Mouse.binding(hex("140000"), 0) == hex("900A0000")
              && G600Mouse.binding(hex("170000"), 0) == hex("900B0000") && G600Mouse.binding(hex("000205"), 0) == hex("80020205")
              && G600Mouse.binding(hex("000000"), 0) == hex("80000000") && G600Mouse.decode(FakeG600().modes[0], 1).light?.effect == 0x03
              && G600Mouse.decode([UInt8](repeating: 0, count: G600Mouse.reportLength), 0).light?.effect == 0x00,
              "a G600 mode report reads as DPI levels, rate, lighting (solid black is off) and its 20 buttons as HID++ bindings")
    }

    // app/SelfTest.cs's HID++ 1.0 mouse checks.
    static func oldMice() {
        let g9x = G9xModel.g9x
        check(g9x.dpi(17) == 400 && g9x.dpi(136) == 3200 && g9x.dpi(242) == 5700 && g9x.dpi(9) == 200 && g9x.dpi(85) == 2000
              && g9x.dpiToRaw(5700) == 242 && g9x.dpiToRaw(800) == 34, "G9x DPI matches what LGS shows")
        func old(_ usbId: Int, wireless: Int = 0) -> FoundDevice {
            let device = FoundDevice(); device.hidpp10 = true; device.usbId = usbId; device.wirelessId = wireless; return device
        }
        let notOld = FoundDevice(); notOld.usbId = 0xC066
        check(old(0xC066).isG9x && !notOld.isG9x && old(0xC24E).g500Model === G9xModel.g500s && old(0xC068).isG500 && old(0xC049).isG5
              && old(0xC048).isG9 && old(0xC06B).g500Model === G9xModel.g700 && old(0xC531, wireless: 0x102A).g500Model === G9xModel.g700s
              && !old(0xC066).isMouse, "the old mice are told apart by USB id or wireless id, and aren't taken for HID++ 2.0 mice")
        do {
            let mouse = FakeG9x()
            let state = try G9xRegisters.read(mouse, g9x)
            check(state.dpi == 800 && state.stage == 1 && state.stages == [400, 800, 1600, 3200] && state.rate == 500
                  && state.light?.effect == 0x01 && state.light?.color == 0xFF0000 && state.light?.bright == 100,
                  "the G9x reads its DPI, stages, rate and colour")
            try G9xRegisters.setDpi(mouse, 5700, g9x)
            try G9xRegisters.setRate(mouse, 1000)
            try G9xRegisters.setLight(mouse, MouseLight(effect: 0x01, color: 0x0000FF, bright: 50))
            check(Array(mouse.registers[0x63]!.prefix(6)) == hex("F200F2008001") && mouse.registers[0x64]![0] == 1
                  && mouse.registers[0x57]! == hex("00007F"), "the G9x sets DPI, rate and colour through its registers")
            try G9xRegisters.setLight(mouse, MouseLight(effect: 0x00))
            let dark = try G9xRegisters.read(mouse, g9x)
            check(mouse.registers[0x57]! == [0, 0, 0] && dark.light?.effect == 0x00, "the G9x light turns off")
            check(G9xRegisters.stagesOf(mouse.pages[3]!, g9x) == [200, 800, 2000], "G9x profile 2")

            let saver = FakeG9x()
            let before = try G9xRegisters.read(saver, g9x)
            let otherPage = saver.pages[3]!
            let page = try G9xRegisters.build(saver.pages[2]!, MouseSettings(dpi: 1200, stage: 2, light: MouseLight(effect: 0x01, color: 0x00FF00)), 1000, g9x)
            try G9xRegisters.store(saver, before, page, before.profile)
            let after = try G9xRegisters.read(saver, g9x)
            check(before.writable && saver.pages[2]! == page && after.profileOk && after.stages == [400, 800, 1200, 3200]
                  && page[16] == 0 && page[17] == 51 && page[18] == 0 && page[19] == 51 && page[0x23] == 2 && page[0x26] == 1
                  && Array(page.prefix(3)) == hex("00FF00") && saver.pages[3]! == otherPage
                  && saver.writes == ["erase 2:0", "copy 2:0", "copy 2:128"] && saver.registers[0x0F]![0] == 0 && saver.registers[0x0F]![1] == 0,
                  "the G9x saves a profile page through RAM, erase and copy, and loads it again")
            let directory = try G9xRegisters.read(FakeG9x(), g9x)
            directory.sector = 1
            var refused = false
            do { try G9xRegisters.store(saver, directory, page, nil) } catch GLiteError.refused { refused = true }
            check(refused && !directory.writable && saver.writes.count == 3, "the G9x never writes the directory page")
            let cut = FakeG9x()
            let cutState = try G9xRegisters.read(cut, g9x)
            let kept = cut.pages[2]!
            cut.failSecondHalf = true
            var cutError = ""
            do { try G9xRegisters.store(cut, cutState, try G9xRegisters.build(kept, MouseSettings(dpi: 1200, stage: 2), 1000, g9x), kept) }
            catch { cutError = "\(error)" }
            check(cutError.contains("as it was is back") && cut.pages[2]! == kept && cut.registers[0x0F]![0] == 0
                  && cut.writes == ["erase 2:0", "copy 2:0", "erase 2:0", "copy 2:0", "copy 2:128"],
                  "a G9x save cut off after the erase puts the page back as it was and loads it")

            let g500s = FakeG9x.g500s()
            let g500sState = try G9xRegisters.read(g500s, .g500s)
            try G9xRegisters.setDpi(g500s, 8200, .g500s)
            let g500sPage = try G9xRegisters.build(g500s.pages[2]!, MouseSettings(dpi: 6400, stage: 3, light: MouseLight(effect: 0x01, color: 0x00FF00)), 1000, .g500s)
            try G9xRegisters.store(g500s, g500sState, g500sPage, g500sState.profile)
            let g500sAfter = try G9xRegisters.read(g500s, .g500s)
            check(g500sState.dpi == 800 && g500sState.light == nil && g500sState.stages == [400, 800, 1600, 3200] && g500sState.dpis.last == 8200
                  && g500s.registers[0x63]![0] == 164 && g500sAfter.stages == [400, 800, 1600, 6400] && g500s.pages[2]![0x23] == 3
                  && g500s.pages[2]!.prefix(3).allSatisfy { $0 == 0 },
                  "the G500s reads and saves its DPI in units of 50 up to 8200, and has no colour light to read or save")

            let g5Mouse = FakeG9x.short(0x82)
            let g5State = try G5Mouse.g5().read(g5Mouse)
            try G5Mouse.g5().sendDpi(g5Mouse, g5State, MouseSettings(dpi: 2000), nil)
            let g9Mouse = FakeG9x.short(0x84)
            let g9State = try G5Mouse.g9().read(g9Mouse)
            try G5Mouse.g9().sendDpi(g9Mouse, g9State, MouseSettings(dpi: 3200), nil)
            let g9Lowest = try G5Mouse.g9().dpiToRaw(200)
            var g5Refused = false
            do { try G5Mouse.g5().sendDpi(g5Mouse, g5State, MouseSettings(dpi: 1000), nil) } catch GLiteError.refused { g5Refused = true }
            check(g5State.dpi == 1600 && g5State.rate == 500 && !g5State.writable && g5State.light == nil && g5Mouse.registers[0x63]![0] == 0x83
                  && g5Refused && g9State.dpi == 800 && g9State.dpis.count == 16 && g9Mouse.registers[0x63]![0] == 0x90
                  && g9Lowest == 0x81,
                  "the G5 and G9 read and set their DPI as 0x80 + an index into their list (the G9's 200 DPI is 0x81), live only")
            let g700s = try G9xRegisters.read(FakeG9x.g500s(), .g700s)
            check(g700s.dpi == 800 && g700s.dpis.last == 8200 && g700s.profile == nil && !g700s.writable && g700s.stages.isEmpty,
                  "the G700s reads its DPI live, with no profile page")
        } catch {
            check(false, "fake G9x: \(error)")
        }
    }

    // app/SelfTest.cs's bindings checks.
    static func bindings() {
        let actions = Bindings.mouseActions
        let dpiShift = actions.firstIndex { $0.name == "DPI shift" }!, disabled = actions.firstIndex { $0.name == "Disabled" }!
        let hero = FoundDevice()
        hero.models = "USB C08B"
        check(Bindings.find(actions, hex("9007FFFF")) == dpiShift && Bindings.find(actions, hex("9007FF00")) == dpiShift
              && Bindings.find(actions, hex("8000FFFF")) == disabled && Bindings.find(actions, hex("80010005")) < 0
              && Bindings.describe(hex("900AFFFF")) == "Cycle profile" && Bindings.describe(hex("900D0003")) == "Profile 3"
              && Bindings.describe(hex("90000000")) == "Disabled" && Bindings.describe(hex("80020306")) == "Ctrl + Shift + C"
              && Bindings.names(hero, 11)[5] == "Sniper" && Bindings.names(FoundDevice(), 5)[4] == "Button 5"
              && Bindings.describe(Bindings.key(8, KeyPresses.usages[0x00]!)) == "Win + A",
              "factory special bindings (90 xx FF FF) are named, keystrokes read as their keys, and the G502 HERO gets the G502's button names")
    }

    // The device report (app/SelfTest.cs's report checks): what it reads, and that every call it makes is a read.
    static func report() {
        var calls: [String] = []
        func onlyReads() -> Bool {
            calls.allSatisfy { line in
                let parts = line.components(separatedBy: " ").filter { !$0.isEmpty }
                guard parts.count >= 2, let feature = Int(parts[0], radix: 16), let fn = Int(parts[1].dropFirst(2), radix: 16) else { return false }
                // The tap drops trailing zeros, so a call with none left had only zeros.
                let parameters = parts.dropFirst(2).compactMap { UInt8($0, radix: 16) }
                return Report.isRead(feature, fn, parameters.isEmpty ? [0] : parameters)
            }
        }
        func found(_ name: String, _ kind: String, _ features: [Int]) -> FoundDevice {
            let device = FoundDevice(); device.name = name; device.kind = kind; device.link = "LIGHTSPEED"; device.index = 1
            device.features = features; return device
        }
        Hidpp.tap = { calls.append($0) }
        let g915 = Report.build(FakeG915(), found("G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard", "keyboard",
                                                  [0x4540, 0x8040, 0x8071, 0x8100]), "LiveKeyboardPage")
        let g915Reads = onlyReads()
        calls = []
        let mouse = Report.build(FakeMouse.g502(), FakeMouse.found(), "MousePage")
        let mouseReads = onlyReads()
        Hidpp.tap = nil
        check(g915.contains("0000=000101FF000201FF000301FF") && g915.contains("0001=0100") && g915.contains("0101=0100")
              && g915.contains("cluster 0 effect 0=") && g915.contains("Screen    LiveKeyboardPage") && g915Reads,
              "the G915 report reads the profiles its directory lists and its effects, and only reads")
        check(mouse.contains("dpi list=") && mouse.contains("0101=") && mouseReads, "the mouse report reads its DPI and profiles, and only reads")
        let headsetDevice = found("PRO X Wireless Gaming Headset", "headset", [0x8300, 0x1F20])
        headsetDevice.index = 0xFF
        let headset = Report.build(FakeHeadset(), headsetDevice, "HeadsetPage")
        check(headset.contains("sidetone=1E") && headset.contains("%, 3926 mV"), "the headset report reads sidetone and the battery")
        let g9x = Report.registers(FakeG9x(), FakeG9x.found(), "MousePage")
        check(g9x.contains("HID++ 1.0 registers") && g9x.contains("page 02"), "the G9x report reads its registers and flash pages")
        check(Report.reads[0x8100].map { Set($0).isDisjoint(with: [1, 3, 6, 7, 8, 0xC]) } == true
              && Report.reads[0x8101].map { Set($0).isDisjoint(with: [2, 3, 6, 7]) } == true
              && Report.reads[0x8071]?.contains(1) == false && Report.reads[0x8070]?.contains(3) == false
              && Report.isRead(0x8071, 8, [0, 0, 0]) && !Report.isRead(0x8071, 8, [1, 1, 0]) && !Report.isRead(0x8071, 5, [1, 0, 0]),
              "the report never calls a write function")
    }

    // Try effect on the Litra Beam LX (app/LitraProtocol.cs).
    static func litraTry() {
        do {
            let light = FakeLight()
            let groups = try G915Lighting.clusters(light).clusters
            var state = LightState()
            state.colors = [0xFF0000, 0, 0, 0, 0, 0, 0x0000FF]
            state.period = 3000
            try LitraProtocol.tryEffect(light, 1, 2, 0x18, state)
            let tried = light.effect
            LitraProtocol.release(light)
            check(groups == FakeLight.groups && tried == [0x01, 0x02, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x0B, 0xB8, 0x64, 0x00, 0x01]
                  && !light.controlled && LitraProtocol.effectName(0x18) == "Two colours" && LitraProtocol.effectName(0x42) == "Effect 42",
                  "Try effect takes the clusters, sends Two colours with the first and last zones' colours and the period, and gives them back")
        } catch { check(false, "Try effect: \(error)") }
    }

    // app/SelfTest.cs's Game mode checks, same golden bytes.
    static func gameMode() {
        check(TypedKeys.typed(0x3A) == nil && TypedKeys.typed(0x28) == nil && TypedKeys.typed(-1) == nil
              && (TypedKeys.typed(0x04).map { !$0.isEmpty && $0 == $0.uppercased() } ?? true),
              "the Game view takes from the Mac's layout only the legends that depend on it (letters, digits, punctuation), in capitals")
        check(IdleBox.nearest(IdleBox.idleSeconds, 20) == 1 && IdleBox.nearest(IdleBox.sleepSeconds, 3600) == 6
              && IdleBox.nearest(IdleBox.dimPercents, 50) == 3 && IdleBox.idleNames.count == IdleBox.idleSeconds.count
              && IdleBox.sleepNames.count == IdleBox.sleepSeconds.count && IdleBox.dimNames.count == IdleBox.dimPercents.count,
              "the When idle lists show the nearest choice to a time the keyboard holds")
        check(ZoneLighting.usage(0x01) == 0x04 && ZoneLighting.usage(0x17) == 0x1A && ZoneLighting.usage(0x62) == 0x65
              && ZoneLighting.usage(0x68) == 0xE0 && ZoneLighting.usage(0x6F) == 0xE7 && ZoneLighting.usage(0xB4) == -1
              && ZoneLighting.usage(0x99) == -1 && KeyPresses.lightingId(0x1A) == 0x17 && KeyPresses.lightingId(0xE3) == 0x6B,
              "Game mode keys: lighting ids are USB usages minus 3, the modifiers 0x68-0x6F, and G, media and brightness keys have none")
        check(!GameModeKeys.canPick(0xE3, false) && !GameModeKeys.canPick(0xE7, false) && !GameModeKeys.canPick(0x65, false)
              && GameModeKeys.canPick(0x2B, false) && GameModeKeys.clean([0x1A, 0xE3, 0x0E, 0x1A, 0xC0], false) == [0x0E, 0x1A],
              "Game mode keys: Windows and Menu are always off and can't be picked, and the list is sorted without repeats")
        let packets = GameModeKeys.packets(Array(4..<22))
        check(packets.count == 2 && packets[0] == (4..<20).map { UInt8($0) } && packets[1][0] == 20 && packets[1][1] == 21
              && packets[1].dropFirst(2).allSatisfy { $0 == 0 } && GameModeKeys.packets([]).isEmpty,
              "Game mode keys: 16 usages per fn 1 call, the last one ended by zeros")
        let old = GameModeKeys.split("1,FF0000,0,0,0,0,0,100"), empty = GameModeKeys.split("1,FF0000,0,0,0,0,0,100!")
        let zone = GameModeKeys.split("254,FF0000,0,0,0,0,0,100|zones:Hey!,FF0000!0E1A")
        check(old.keys == nil && old.preset == "1,FF0000,0,0,0,0,0,100" && empty.keys == "" && empty.preset == old.preset
              && zone.keys == "0E1A" && zone.preset.hasSuffix("Hey!,FF0000")
              && KeyboardPage.screenPart("254,FF0000,0,0,0,0,0,100|zones:Hey!,FF0000!0E1A") == "zones:Hey!,FF0000"
              && GameModeKeys.fromText("1A0EE3zz", false) == [0x0E, 0x1A] && GameModeKeys.toText([0x0E, 0x1A]) == "0E1A",
              "Game mode keys in a preset: after the last !, none in an older preset, read back without what can't be picked")
        let controls = stride(from: 0, to: FakeG515.controlList.count, by: 2).map { Int(FakeG515.controlList[$0]) << 8 | Int(FakeG515.controlList[$0 + 1]) }
        let aAndEnter = GameModeKeys.bitmap(controls, [0x04, 0x28])
        check(aAndEnter[7] == 0x41 && aAndEnter.enumerated().allSatisfy { $0.offset == 7 || $0.element == 0 },
              "Game mode bitmap (0x4523): A and Enter are the G515's controls 0x38 and 0x3E, bits 0 and 6 of byte 7 (tried)")
        // The games (app/SelfTest.cs).
        let blocks = Blocks()
        for y in 0..<Game.rows { blocks.cells[y][Game.columns - 1] = 1 }
        blocks.cells[0][Game.columns - 2] = 2
        blocks.clearFull()
        check(blocks.score == 1 && blocks.cells[0][Game.columns - 1] == 2 && blocks.cells[0][Game.columns - 2] == 0, "games: full column clears and shifts")
        blocks.key(.space)
        check(!blocks.over, "games: piece locks after drop")
        let gridCount = Game.columns * Game.rows
        let rects = (0..<gridCount).map { CGRect(x: CGFloat($0 % Game.columns * 40), y: CGFloat($0 / Game.columns * 40), width: 36, height: 36) }
        let gridCells: [[Cell]?] = (0..<gridCount).map { [Cell(x: $0 % Game.columns, y: $0 / Game.columns)] }
        let snake = Snake(gridCells)
        snake.key(.left)
        snake.step()
        check(!snake.over && snake.at(2, 5) != 0, "games: snake ignores reversing into itself")
        for _ in 0..<Game.columns - 5 { snake.step() }
        check(!snake.over && snake.at(2, 0) != 0, "games: snake wraps through the wall")
        var mines = Mines(rects, gridCells)
        mines.open(2 * Game.columns + 7)
        check(!mines.over && mines.opened(2 * Game.columns + 7) && mines.minesAround(2 * Game.columns + 7) == 0, "games: first open is never a mine")
        mines = Mines(rects, gridCells); mines.placed = true; mines.mine[0] = true
        mines.open(gridCount - 1)
        check(mines.over && mines.score == gridCount - 1, "games: opening an empty key floods the board and wins")
        mines = Mines(rects, gridCells); mines.placed = true; mines.mine[0] = true
        mines.open(0)
        check(mines.over && mines.score == 0 && mines.at(0, 0) == 0xFF3030, "games: opening a mine ends the game and shows it")
        let wide = [CGRect(x: 0, y: 0, width: 76, height: 36), CGRect(x: 80, y: 0, width: 36, height: 36), CGRect(x: 20, y: 40, width: 36, height: 36)]
        mines = Mines(wide, [[Cell(x: 0, y: 0), Cell(x: 1, y: 0)], [Cell(x: 2, y: 0)], [Cell(x: 0, y: 1)]]); mines.placed = true; mines.mine[1] = true
        check(mines.minesAround(0) == 1 && mines.minesAround(2) == 0, "games: neighbours follow the keys, not the grid")
        if let g515 = KeyLayout.load("g515-tkl.json") {
            let boardCells = GamesBoard(g515).cells
            check(boardCells.compactMap { $0 }.count > 50 && boardCells.compactMap { $0 }.joined().allSatisfy { $0.y < Game.rows },
                  "games: the G515's bottom five rows are the board")
        }
        if let g515 = KeyLayout.load("g515-tkl.json") {
            let usages = Array(Set(g515.keyIds().map(ZoneLighting.usage).filter { GameModeKeys.canPick($0, true) } + [0x32, 0x64]))
            check(usages.count == 88 && usages.allSatisfy { usage in
                GameModeKeys.bitmap(controls, [usage]).reduce(0) { $0 + $1.nonzeroBitCount } == 1
            }, "Game mode bitmap: each key that can be picked on the G515 (ANSI and ISO) is one control")
        }
        check(GameModeKeys.canPick(0xE3, true) && GameModeKeys.canPick(0x65, true) && !GameModeKeys.canPick(0xE7, true)
              && GameModeKeys.fromText("E365", true) == [0x65, 0xE3],
              "Game mode bitmap: Windows and Menu can be picked (the G515 leaves them on), the Fn key can't (no control)")
        do {
            let g515 = FakeG515(), g915 = FakeG915()
            var none: [Int]?
            try GameModeKeys.send(g515, [0x04, 0x28], true, controls: &none)
            var sent: [String] = []
            Hidpp.tap = { sent.append($0) }
            var unused: [Int]?
            try GameModeKeys.send(g915, [0x1A, 0x04, 0x07], false, controls: &unused)
            Hidpp.tap = nil
            check(g515.gameBitmap[7] == 0x41 && none?.count == FakeG515.controlList.count / 2 && g915.gameKeys == [0x1A, 0x04, 0x07]
                  && sent == ["4522 fn3", "4522 fn1  1A 04 07"],
                  "Game mode keys go to the G515 as its control bitmap, the list read once, and to the G915 as fn 3 then fn 1")
        } catch { check(false, "Game mode keys are sent: \(error)") }
    }

    // app/SelfTest.cs's screen setup checks.
    static func screenSetup() {
        var screen = ScreenSettings()
        screen.monitor = "69733378"; screen.boost = 60; screen.interval = 300; screen.smooth = false; screen.pauseOnBattery = false
        screen.pauseWhenLocked = false
        screen.keys[0x26] = 3
        screen.zones.append(Zone(name: "Zone 5", markColor: ScreenSettings.markColors[4], area: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))
        let back = ScreenSettings.fromText(screen.toText())
        check(back.monitor == screen.monitor && back.boost == 60 && back.interval == 300 && !back.smooth && !back.pauseOnBattery
              && !back.pauseWhenLocked && back.zones.count == 5 && back.zones[4].name == "Zone 5" && abs(back.zones[4].area.height - 0.4) < 0.001
              && back.keys[0x26] == 3 && back.zoneOf(0x26, 0) == 3 && back.zoneOf(0x10, 0.99) == 4, "screen setup round-trips through text")
        check(ScreenSettings.fromText("garbage;zones:x").zones.count == 4 && ScreenSettings.fromText("ms:5000").interval == 1000
              && ScreenSettings.corners("").zones.count == 4 && ScreenSettings.corners(screen.toText()).zones.count == 4
              && ScreenSettings.columns("").zones.count == 7 && ScreenSettings.corners("").zones[0].name == "Bottom left",
              "bad screen setup text falls back to defaults, and the speakers and the light keep their own number of areas")
        var edited = ScreenSettings()
        edited.keys = [0x04: 1, 0x05: 2, 0x06: 3]
        let added = edited.add()
        edited.remove(1)
        var full = edited
        while full.add() != nil {}
        check(added == 4 && edited.zones.count == 4 && edited.zones[3].name == "Zone 5" && edited.zones[3].markColor == ScreenSettings.markColors[4]
              && edited.keys == [0x04: 0, 0x05: 1, 0x06: 2] && full.zones.count == ScreenSettings.maxZones,
              "an added area takes a free colour; a removed one gives its keys to the one before, the others moving up")
        var stripes = ScreenSettings()
        stripes.zones[1].area = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.2)
        _ = stripes.add()
        check((0..<5).allSatisfy { abs(stripes.zones[$0].area.minX - CGFloat($0) * 0.2) < 0.001 && abs(stripes.zones[$0].area.width - 0.2) < 0.001 }
              && abs(stripes.zones[1].area.minY - 0.1) < 0.001 && abs(stripes.zones[4].area.height - 0.35) < 0.001,
              "an added zone makes every zone an equal strip, left to right with the new one at the right, each keeping its height")
        var field = KeyField()
        field.ids = [0x04, 0x05, 0x10]; field.x = [0, 0.5, 0.99]
        check(edited.counts(field) == [1, 1, 0, 1], "each area counts the keys it lights")
        let pausing = ScreenSettings()
        var running = pausing
        running.pauseOnBattery = false; running.pauseWhenLocked = false
        check(pausing.pauseReason(away: false, battery: 19, charging: false) != nil && pausing.pauseReason(away: false, battery: 19, charging: true) == nil
              && pausing.pauseReason(away: false, battery: 20, charging: false) == nil && pausing.pauseReason(away: false, battery: -1, charging: false) == nil
              && pausing.pauseReason(away: true, battery: 80, charging: false) != nil && running.pauseReason(away: true, battery: 5, charging: false) == nil,
              "the Screen effect pauses below 20% battery unless charging, and while the screen is off or locked, as its switches say")
        // A Windows setup, as a Windows preset holds it.
        let windows = ScreenSettings.fromText(#"mon:\\.\DISPLAY2;boost:40;ms:200;bright:80;smooth:1;bat:1;lock:0;zones:Left,3B82F6,0,0.5,0.25,0.35/Right,8B6CF0,0.75,0.5,0.25,0.35;keys:"#)
        check(windows.boost == 40 && windows.interval == 200 && windows.bright == 80 && !windows.pauseWhenLocked && windows.zones.count == 2
              && windows.zones[1].area.minX == 0.75, "a Windows screen setup reads here")
    }

    // Presets: their texts read back, and a Windows keyboard preset's extras are left out.
    static func presetTexts() {
        let mouse = MouseSettings(dpi: 1200, rate: 500, stage: 2, light: MouseLight(effect: 0x0A, color: 0x30D050, period: 3000, bright: 70),
                                  buttons: [hex("80010001"), hex("90050000")])
        let back = MouseSettings.fromText(mouse.toText())
        check(back?.dpi == 1200 && back?.rate == 500 && back?.light == mouse.light && back?.buttons == mouse.buttons
              && MouseSettings.fromText("800,1,FFFFFF,5000,100")?.rate == 0 && MouseSettings.fromText("bogus") == nil,
              "a mouse preset round-trips through text, buttons included")
        check(KeyboardPage.lightingPart("1,FF0000,5000,1,50,60,300,80|mon:;boost:33!1E,1F") == "1,FF0000,5000,1,50,60,300,80"
              && KeyboardPage.lightingPart("10,3080FF,3000,1,25,30,600,100#1,FFFFFF,5000,1,50,60,300,100") == "10,3080FF,3000,1,25,30,600,100"
              && Lighting.fromText(KeyboardPage.lightingPart("254,FFFFFF,5000,1,50,60,300,100|mon:"))?.0.effect == 0xFE,
              "a Windows keyboard preset reads here without its Screen setup, light bar and Game mode keys; its Screen effect stays Screen")
    }

    // app/SelfTest.cs's mouse checks.
    static func mice() {
        check(MouseProtocol.rateList(0x8B) == [125, 250, 500, 1000], "report rates from their bits")
        for effect in MouseProtocol.effects {
            let light = MouseLight(effect: effect.id, color: 0x3080FF, period: 4000, bright: 50)
            let back = MouseProtocol.decode([effect.id] + MouseProtocol.encode(light))
            check(back != nil && back!.effect == effect.id, effect.name + " mouse effect")
            if effect.id != 0 { check(back!.bright == 50, effect.name + " mouse brightness") }
            if effect.color { check(back!.color == 0x3080FF, effect.name + " mouse color") }
            if effect.speed { check(back!.period == 4000, effect.name + " mouse period") }
        }
        do {
            let mouse = FakeMouse()
            let mouseState = try MouseProtocol.read(mouse)
            check(mouseState.dpi == 1600 && mouseState.stage == 2 && mouseState.stages == [400, 800, 1600, 3200, 6400]
                  && mouseState.onboard && mouseState.rate == 1000 && mouseState.light?.effect == 0x03
                  && mouseState.light?.period == 8000 && mouseState.zones.count == 2, "mouse state read from its onboard profile")
            mouse.pressDpiButton()
            let (pressedDpi, pressedStage) = try MouseProtocol.readDpiAndStage(mouse, mouseState)
            check(pressedDpi == 3200 && pressedStage == 3, "after the mouse's DPI button, the new DPI and stage are read")
            try MouseProtocol.setStage(mouse, 3)
            try MouseProtocol.setLight(mouse, mouseState, MouseLight(effect: 0x0A, color: 0xFF0000, period: 3000, bright: 80))
            check(mouse.dpi == 3200 && mouse.zones[1][1] == 3 && mouse.zones[1][2] == 0xFF && mouse.zones[1][8] == 80,
                  "mouse stage and lighting are set")

            let real = hex("01020290012003d007800c0019ffffffff00ffffffffffffffffffffffffffff8001000180010002800100048001000880010010900500008001000880010010ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff8001000180010002800100048001000880010010900500008001000880010010ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff440065006600610075006c0074000000000000000000000000000000000000000000000000000000000000000000000001ffffff0000000000000001ffffff00000000000000ffffffffffffffffffffffffffffffffffffffffffff00bfdd")
            check(MouseProtocol.valid(real) && MouseProtocol.crc(real, 253) == 0xBFDD, "the profile checksum matches the real mouse")
            let mouseLight = MouseLight(effect: 0x0A, color: 0xFF0000, period: 3000, bright: 80)
            let built = try MouseProtocol.build(real, MouseSettings(dpi: 1200, rate: 500, stage: 2, light: mouseLight), 2)
            let allowed = Set([0, 1, 253, 254] + Array(3..<13) + Array(0xD0..<0xD0 + 22))
            check(MouseProtocol.valid(built) && built[0] == 2 && built[1] == 2 && MouseProtocol.stagesOf(built) == [400, 800, 1200, 3200, 6400]
                  && built[0xD0] == 0x0A && built[0xDB] == 0x0A && (0..<255).allSatisfy { allowed.contains($0) || built[$0] == real[$0] },
                  "a saved mouse profile changes only DPI, report rate and lighting")
            let picked = try MouseProtocol.build(real, MouseSettings(dpi: 800, stage: 1), 2)
            check(picked[1] == 1 && MouseProtocol.stagesOf(picked) == MouseProtocol.stagesOf(real) && picked[0] == real[0],
                  "saving a DPI stage only makes it the default")
            let moved = try MouseProtocol.build(real, MouseSettings(dpi: 800, stage: 2), 2)
            check(moved[1] == 2 && MouseProtocol.stagesOf(moved) == [400, 800, 800, 3200, 6400], "a stage dragged to another stage's value keeps its place")

            let second = FakeMouse()
            let secondState = try MouseProtocol.read(second)
            check(secondState.savable && secondState.sector == 1 && secondState.sectorSize == 255 && secondState.format == 3,
                  "the fake mouse can be saved to")
            try MouseProtocol.store(second, secondState, try MouseProtocol.build(secondState.profile!,
                MouseSettings(dpi: 3200, rate: 500, stage: 3, light: MouseLight(effect: 0x01, color: 0xFF2020, bright: 100)), 2))
            let savedState = try MouseProtocol.read(second)
            check(savedState.dpi == 3200 && savedState.rate == 500 && savedState.light?.effect == 0x01 && savedState.light?.color == 0xFF2020
                  && second.reloads == 1 && savedState.profileOk, "saving to the mouse sticks and reloads the profile")
            try MouseProtocol.store(second, savedState,
                                    try MouseProtocol.factory(try MouseProtocol.readSector(second, MouseProtocol.romSector, 255), savedState.profile!, savedState))
            let restoredState = try MouseProtocol.read(second)
            let name = String(decoding: stride(from: 0xA0, to: 0xAE, by: 2).map { UInt16(restoredState.profile![$0]) | UInt16(restoredState.profile![$0 + 1]) << 8 },
                              as: UTF16.self)
            check(restoredState.dpi == 1600 && restoredState.light?.effect == 0x03 && restoredState.profileOk && name == "Default",
                  "the factory profile comes back with the profile's name")
            var refusals = 0
            for sector in [0x0000, 0x0101] {
                do { try MouseProtocol.writeSector(second, sector, restoredState.profile!) } catch GLiteError.refused { refusals += 1 }
            }
            var broken = restoredState.profile!
            broken[5] ^= 1
            do { try MouseProtocol.writeSector(second, 1, broken) } catch GLiteError.refused { refusals += 1 }
            check(refusals == 3 && MouseProtocol.valid(second.sectors[1]) && !MouseProtocol.valid(second.sectors[0x0101]),
                  "the directory, the factory profile and bad checksums are never written")
            check(!restoredState.fresh, "a mouse with a profile isn't set up again")

            let fresh = FakeMouse(fresh: true)
            let freshFactory = fresh.sectors[0x0101]!
            let freshState = try MouseProtocol.read(fresh)
            check(freshState.fresh && freshState.writable && freshState.savable && freshState.sector == 0x0101,
                  "a mouse with only its factory profile can be saved to")
            var freshRefusals = 0
            do { try MouseProtocol.store(fresh, freshState, try MouseProtocol.build(freshState.profile!, MouseSettings(dpi: 800), 2)) }
            catch GLiteError.refused { freshRefusals += 1 }
            do { try MouseProtocol.setup(second, restoredState, restoredState.profile!) } catch GLiteError.refused { freshRefusals += 1 }
            do { _ = try MouseProtocol.directory(255, 0) } catch GLiteError.refused { freshRefusals += 1 }
            check(freshRefusals == 3 && fresh.sectors[0x0001] == nil && fresh.sectors[0x0000] == nil,
                  "setting up is refused on a mouse that has a profile, and a save never writes the factory profile")
            try MouseProtocol.setup(fresh, freshState, try MouseProtocol.build(freshState.profile!, MouseSettings(dpi: 3200, rate: 500, stage: 3), 2))
            let setUpState = try MouseProtocol.read(fresh)
            let directory = fresh.sectors[0x0000]!
            check(setUpState.sector == 1 && !setUpState.fresh && setUpState.savable && setUpState.dpi == 3200 && setUpState.rate == 500
                  && fresh.reloads == 1 && MouseProtocol.valid(directory) && Array(directory.prefix(8)) == hex("00010100FFFF0000")
                  && directory[8..<253].allSatisfy { $0 == 0xFF } && fresh.sectors[0x0101]! == freshFactory,
                  "the first save writes the profile and the directory, and leaves the factory profile as it was")

            let hero = FakeMouse.hero()
            let heroState = try MouseProtocol.read(hero)
            try MouseProtocol.setup(hero, heroState, try MouseProtocol.build(heroState.profile!, MouseSettings(dpi: 800), 2))
            let formatOne = FakeMouse()
            formatOne.info = "01010105050B1000FF0A01"
            let heroSaved = try MouseProtocol.read(hero), formatOneState = try MouseProtocol.read(formatOne)
            check(heroState.fresh && heroState.savable && MouseProtocol.valid(hero.sectors[0x0000]) && heroSaved.sector == 1
                  && !formatOneState.writable && MouseProtocol.unwritten([UInt8](repeating: 0xFF, count: 255))
                  && !MouseProtocol.unwritten(restoredState.profile!),
                  "profile format 2 (G502 HERO) saves like format 3, a directory of zeros counts as none, format 1 stays read-only")

            let superlight = FakeMouse.superlight()
            let superlightMouse = HidppMouse()
            let superlightState = try superlightMouse.read(superlight)
            let superlightBefore = superlight.sectors[1]!
            var superlightButtons = superlightState.buttons!
            superlightButtons[3] = hex("90050000")
            try superlightMouse.save(superlight, superlightState, superlightBefore,
                                     MouseSettings(dpi: 1000, rate: 500, stage: 1, light: MouseLight(effect: 0x01, color: 0xFF0000), buttons: superlightButtons))
            let superlightSaved = superlight.sectors[1]!
            check(superlightState.format == 4 && superlightState.savable && superlightState.zones.isEmpty && superlightMouse.hasFactory
                  && superlightState.stages == [400, 800, 1600, 3200, 6400] && superlightState.buttons!.count == 5
                  && MouseProtocol.valid(superlightSaved) && superlight.reloads == 1
                  && Log.hex(Array(superlightSaved.prefix(0x0D))) == "02010290 01e80340 06800c0019".replacingOccurrences(of: " ", with: "")
                  && Array(superlightSaved[0x2C..<0x30]) == hex("90050000")
                  && superlightSaved[0x30..<0xFD] == superlightBefore[0x30..<0xFD] && superlightSaved[0x0D..<0x2C] == superlightBefore[0x0D..<0x2C],
                  "a format 4 mouse saves format 3's fields and buttons, and keeps its LED records")

            let proX2 = try MouseProtocol.read(FakeMouse.proX2())
            check(proX2.dpi == 800 && proX2.dpis.first == 100 && proX2.dpis.last == 32000 && proX2.dpis.count == 639
                  && proX2.stages == [400, 800, 1600, 3200] && proX2.stage == 1 && proX2.rate == 1000
                  && proX2.rates == [125, 250, 500, 1000, 2000, 4000, 8000] && proX2.onboard && proX2.savable && proX2.format == 7
                  && proX2.buttons!.count == 5 && proX2.buttons![4] == hex("80010010"),
                  "a format 7 mouse with 0x2202 and 0x8061 reads its DPI, stages, rate and buttons (from 0x30) and can be saved to")
            let proX2Profile = FakeMouse.proX2().sectors[1]!
            var wideButtons = proX2.buttons!
            wideButtons[3] = hex("90050000")
            let wideProfile = try MouseProtocol.buildWide(proX2Profile, MouseSettings(dpi: 1800, rate: 2000, stage: 2, buttons: wideButtons), wired: false)
            let wideWired = try MouseProtocol.buildWide(proX2Profile, MouseSettings(dpi: 800, rate: 500, stage: 1), wired: true)
            check(MouseProtocol.valid(wideProfile) && wideProfile.count == 255
                  && Array(wideProfile.prefix(0x1D)) == hex("0403020090019001022003200302080708070280 0C800C020000000000".replacingOccurrences(of: " ", with: ""))
                  && Array(wideProfile[0x3C..<0x40]) == hex("90050000") && wideProfile[0x44..<0xFD] == proX2Profile[0x44..<0xFD]
                  && wideWired[0] == 3 && wideWired[1] == 2 && wideWired[2] == 1 && MouseProtocol.describeWide(wideProfile) == "1800 DPI",
                  "a format 7 save changes the stage (X and Y), the default stage, the rate of the link in use and the buttons, nothing else")
        } catch {
            check(false, "fake mouse: \(error)")
        }
    }
}
