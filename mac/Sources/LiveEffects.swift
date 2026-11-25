import AppKit
import CoreGraphics

// Effects G-Lite draws itself, key by key, through 0x8081 while it runs (app/LiveEffects.cs): Starlight and Echo, after G HUB's
// Starlight and Echo press, and G-Lite's own Rain, Fire and Aurora. Their ids sit above the keyboards' own effects and are never sent as
// one.
// Audio and Screen follow the Mac's sound and screen (ScreenSource).
enum LiveEffects {
    // Each takes the Intensity slider (Starlight's and Rain's density, Echo's spread, Fire's height, Aurora's colour mix); 50 is the
    // look each was first made with.
    static let all: [EffectInfo] = [
        EffectInfo(id: 0xE0, name: "Starlight", color: true, speed: true, intensity: true, minPeriod: 500, maxPeriod: 5000, defaultPeriod: 2000),
        EffectInfo(id: 0xE1, name: "Echo", color: true, speed: true, intensity: true, minPeriod: 200, maxPeriod: 3000, defaultPeriod: 1000),
        EffectInfo(id: 0xE3, name: "Rain", color: true, speed: true, direction: true, intensity: true, minPeriod: 300, maxPeriod: 3000,
                   defaultPeriod: 1200),
        EffectInfo(id: 0xE4, name: "Fire", speed: true, direction: true, intensity: true, minPeriod: 300, maxPeriod: 3000, defaultPeriod: 1200),
        EffectInfo(id: 0xE5, name: "Aurora", speed: true, intensity: true, minPeriod: 5000, maxPeriod: 60000, defaultPeriod: 20000),
        EffectInfo(id: 0xE2, name: "Audio", color: true, direction: true, intensity: true),
        // The Screen effect, set in its own box (ScreenBox). 0xFE, the id the Windows keyboard screen gives it, so a preset means the
        // same on both.
        EffectInfo(id: 0xFE, name: "Screen"),
    ]
    static let defaultIntensity = 50

    // Wave's numbers: 7 up, 2 down, 6 left, 1 right, 3 centre out, 8 centre in. Rain falls, Fire rises.
    static let directions = [7, 2, 6, 1, 3, 8]
    static let directionNames = ["Up", "Down", "Left", "Right", "Center out", "Center in"]
    static func defaultDirection(_ id: UInt8) -> Int { id == 0xE3 ? 2 : 7 }

    static func info(_ id: UInt8) -> EffectInfo? { all.first { $0.id == id } }
    static func isLive(_ id: UInt8) -> Bool { info(id) != nil }

    static func make(_ id: UInt8) -> LiveEffect? {
        switch id {
        case 0xE0: return Starlight()
        case 0xE1: return Echo()
        case 0xE3: return Rain()
        case 0xE4: return Fire()
        case 0xE5: return Aurora()
        case 0xE2: return AudioEffect()
        case 0xFE: return ScreenEffect()
        default: return nil
        }
    }

    static func scale(_ color: Int, _ factor: Double) -> Int {
        let f = max(0, min(1, factor))
        return Int(Double(color >> 16 & 0xFF) * f) << 16 | Int(Double(color >> 8 & 0xFF) * f) << 8 | Int(Double(color & 0xFF) * f)
    }

    static func blend(_ from: Int, _ to: Int, _ fraction: Double) -> Int {
        let f = max(0, min(1, fraction))
        func mix(_ shift: Int) -> Int { Int((Double(from >> shift & 0xFF) + Double((to >> shift & 0xFF) - (from >> shift & 0xFF)) * f).rounded()) }
        return mix(16) << 16 | mix(8) << 8 | mix(0)
    }

    static func distance(_ first: Int, _ second: Int) -> Int {
        abs((first >> 16 & 0xFF) - (second >> 16 & 0xFF)) + abs((first >> 8 & 0xFF) - (second >> 8 & 0xFF)) + abs((first & 0xFF) - (second & 0xFF))
    }

    // More saturation and full brightness, keeping the hue; a dark colour is off (app/Screen.cs, Boost).
    static func boost(_ color: Int, _ boost: Int) -> Int {
        var red = Double(color >> 16 & 0xFF), green = Double(color >> 8 & 0xFF), blue = Double(color & 0xFF)
        let mean = (red + green + blue) / 3, factor = 1 + Double(boost) / 50
        red = max(0, min(255, mean + (red - mean) * factor))
        green = max(0, min(255, mean + (green - mean) * factor))
        blue = max(0, min(255, mean + (blue - mean) * factor))
        let top = max(red, green, blue)
        if top < 12 { return 0 }
        return Int(red * 255 / top) << 16 | Int(green * 255 / top) << 8 | Int(blue * 255 / top)
    }

    static func hsv(_ hue: Double, _ saturation: Double, _ value: Double) -> Int {
        let rgb = KeyPicture.hsv(hue, saturation, max(0, min(1, value)))
        return Int(rgb.0 * 255) << 16 | Int(rgb.1 * 255) << 8 | Int(rgb.2 * 255)
    }
}

// The keys an effect draws on: each lighting id once, with its centre spread over 0 to 1 (x left to right, y top to bottom).
struct KeyField {
    var ids: [Int] = [], x: [Double] = [], y: [Double] = []
    // The distance from the first key centre to the last, in keys, across and down.
    var across = 20.0, down = 5.0
    var count: Int { ids.count }

    func distance(_ first: Int, _ second: Int) -> Double { hypot((x[first] - x[second]) * across, (y[first] - y[second]) * down) }

    static func from(_ picture: KeyPicture) -> KeyField {
        var field = KeyField(), lefts: [Double] = [], tops: [Double] = [], seen = Set<Int>()
        for key in 0..<picture.count {
            let id = picture.idOf(key)
            if id < 0 || !seen.insert(id).inserted { continue }
            field.ids.append(id); lefts.append(picture.xOf(key)); tops.append(picture.yOf(key))
        }
        func spread(_ values: [Double]) -> [Double] {
            guard let low = values.min(), let high = values.max() else { return [] }
            return values.map { ($0 - low) / max(0.0001, high - low) }
        }
        field.x = spread(lefts); field.y = spread(tops)
        if field.ids.count > 1 {
            field.across = max(1, (lefts.max()! - lefts.min()!) * Double(picture.widthInKeys))
            field.down = max(1, (tops.max()! - tops.min()!) * Double(picture.heightInKeys))
        }
        return field
    }

    // Each key's place along a direction, from the edge the effect starts at (0) to the other (1).
    func along(_ direction: Int) -> [Double] {
        switch direction {
        case 7: return y.map { 1 - $0 }
        case 2: return y
        case 6: return x.map { 1 - $0 }
        case 3: return x.map { abs($0 - 0.5) * 2 }
        case 8: return x.map { 1 - abs($0 - 0.5) * 2 }
        default: return x
        }
    }

    static func sideways(_ direction: Int) -> Bool { [6, 1, 3, 8].contains(direction) }

    // Each key's lane across the direction, out of count: columns going up or down, rows going sideways.
    func lanes(_ direction: Int, _ count: Int) -> [Int] { (KeyField.sideways(direction) ? y : x).map { min(count - 1, Int($0 * Double(count))) } }
}

class LiveEffect {
    var color = 0xFFFFFF, period = 2000, intensity = LiveEffects.defaultIntensity, direction = 7
    var level: Double { Double(max(0, min(100, intensity))) / 100 }
    // Why the effect can't run, for the status line; nil while it can.
    var problem: String?

    // colors[i] is the colour of field.ids[i]. seconds counts from the effect's start; elapsed is the time since the last frame.
    func frame(_ field: KeyField, _ seconds: Double, _ elapsed: Double, _ colors: inout [Int]) {}
    func stop() {}
}

// Keys light up at random and fade out over the period, on a sky of the colour at 4%. Intensity: from 2% to a third of the keys lit
// at a time.
final class Starlight: LiveEffect {
    private var born: [Double] = []

    override func frame(_ field: KeyField, _ seconds: Double, _ elapsed: Double, _ colors: inout [Int]) {
        if born.count != field.count { born = [Double](repeating: -1000, count: field.count) }
        let life = Double(period) / 1000, chance = elapsed / life * (0.02 + level * 0.31), sky = LiveEffects.scale(color, 0.04)
        for i in 0..<field.count {
            var age = seconds - born[i]
            if age >= life && Double.random(in: 0..<1) < chance { born[i] = seconds; age = 0 }
            colors[i] = age < life ? LiveEffects.blend(sky, color, sin(Double.pi * age / life)) : sky
        }
    }
}

// A key lights up when it's pressed, anywhere on the Mac, and fades out over the period. Intensity: how far the glow reaches the keys
// around it, from none to 4 keys away.
final class Echo: LiveEffect {
    private let presses = KeyPresses()
    private var pressedAt: [Int: Double] = [:]

    override init() {
        super.init()
        if !presses.listening { problem = "Echo can't see key presses: allow G-Lite in Privacy & Security, Input Monitoring." }
    }

    override func frame(_ field: KeyField, _ seconds: Double, _ elapsed: Double, _ colors: inout [Int]) {
        for usage in presses.take() {
            var index = field.ids.firstIndex(of: KeyPresses.lightingId(usage))
            // Usage 31 is \ on ANSI keyboards and # on ISO ones, which have no \ there.
            if usage == 0x31 && index == nil { index = field.ids.firstIndex(of: KeyPresses.lightingId(0x32)) }
            if let index = index { pressedAt[index] = seconds }
        }
        let fade = Double(period) / 1000, reach = level * 4
        pressedAt = pressedAt.filter { seconds - $0.value < fade }
        for i in 0..<field.count {
            var lit = 0.0
            for (key, at) in pressedAt {
                let distance = key == i ? 0 : field.distance(i, key)
                let near = distance < 0.01 ? 1 : reach <= 0 ? 0 : max(0, 1 - distance / (reach + 0.6))
                lit = max(lit, near * (1 - (seconds - at) / fade))
            }
            colors[i] = LiveEffects.scale(color, lit)
        }
    }

    override func stop() { presses.stop() }
}

// Drops fall down the columns with a fading trail (or up, or along the rows), taking the period to cross the keyboard. Intensity: from
// 0.1 to 1.3 drops per lane per fall.
final class Rain: LiveEffect {
    private static let columns = 22, rows = 6
    // Each drop: its lane, how far it is along the direction, its speed.
    private var drops: [(lane: Int, at: Double, speed: Double)] = []
    private var lastDirection = 0

    override func frame(_ field: KeyField, _ seconds: Double, _ elapsed: Double, _ colors: inout [Int]) {
        if lastDirection != direction { drops.removeAll(); lastDirection = direction }
        let fall = Double(period) / 1000, laneCount = KeyField.sideways(direction) ? Rain.rows : Rain.columns
        for lane in 0..<laneCount where Double.random(in: 0..<1) < elapsed * (0.1 + level * 1.2) / fall {
            drops.append((lane, -0.1, (0.8 + 0.4 * Double.random(in: 0..<1)) * 1.3 / fall))
        }
        for i in drops.indices { drops[i].at += drops[i].speed * elapsed }
        drops.removeAll { $0.at > 1.5 }
        let keyLanes = field.lanes(direction, laneCount), along = field.along(direction)
        for i in 0..<field.count {
            var lit = 0.0
            for drop in drops where drop.lane == keyLanes[i] {
                let behind = drop.at - along[i]
                if behind >= -0.1 && behind < 0 { lit = max(lit, 1 + behind / 0.1) }
                else if behind >= 0 && behind < 0.45 { lit = max(lit, 1 - behind / 0.45) }
            }
            colors[i] = LiveEffects.scale(color, lit * lit)
        }
    }
}

// Flames flicker up from the bottom row (or down from the top, or in from a side): black, red, orange, yellow. Intensity: how far they
// reach.
final class Fire: LiveEffect {
    private var heat: [Double] = [], phases: [Double] = []
    // Periods gone by, added up frame by frame so a speed change doesn't jump.
    private var time = 0.0

    override func frame(_ field: KeyField, _ seconds: Double, _ elapsed: Double, _ colors: inout [Int]) {
        if heat.count != field.count {
            heat = [Double](repeating: 0, count: field.count)
            phases = (0..<field.count).map { _ in Double.random(in: 0..<6.28) }
        }
        time += elapsed * 1000 / Double(period)
        let along = field.along(direction), across = KeyField.sideways(direction) ? field.y : field.x
        for i in 0..<field.count {
            let wave = across[i] * 7
            let flicker = (sin(wave + time * 3.1) + sin(wave * 1.7 - time * 4.3) + sin(phases[i] + time * 5.9)) / 3
            let target = (1 - along[i]) * 1.3 - 0.4 + (level - 0.5) * 0.9 + 0.45 * flicker + 0.15 * (Double.random(in: 0..<1) - 0.5)
            heat[i] += (target - heat[i]) * min(1, elapsed * 10)
            colors[i] = Fire.color(heat[i])
        }
    }

    static func color(_ heat: Double) -> Int {
        let h = max(0, min(1, heat))
        if h < 0.4 { return LiveEffects.scale(0xFF0000, h / 0.4) }
        if h < 0.75 { return LiveEffects.blend(0xFF0000, 0xFF7000, (h - 0.4) / 0.35) }
        return LiveEffects.blend(0xFF7000, 0xFFD040, (h - 0.75) / 0.25)
    }
}

// Slow bands of green, teal, blue and purple drift across the keys, a full turn per period. Intensity: from one teal to twice the range
// of hues.
final class Aurora: LiveEffect {
    // Added up frame by frame so a speed change doesn't jump.
    private var turn = 0.0

    override func frame(_ field: KeyField, _ seconds: Double, _ elapsed: Double, _ colors: inout [Int]) {
        turn += elapsed * 2 * Double.pi / (Double(period) / 1000)
        let mix = level * 2
        for i in 0..<field.count {
            let x = field.x[i], y = field.y[i]
            let hue = 0.47 + mix * (0.17 * sin(x * 3.1 + turn) + 0.1 * sin(y * 2.3 - turn * 2 + x * 1.7))
            let value = 0.3 + 0.7 * (0.5 + 0.5 * sin(x * 4.2 - turn * 3 + y * 1.5))
            colors[i] = LiveEffects.hsv(hue, 1, value)
        }
    }
}

// Bars grow with the sound playing on the Mac, up from the bottom row by default (or down, or across the rows): low notes first. They
// start in the colour and turn as they grow: a colour's hue by a third, white (or grey) to red. Intensity: how loud a sound has to be
// to reach the far edge (app/LiveEffects.cs, Audio).
final class AudioEffect: LiveEffect {
    private static let bands = 20, rowBands = 6
    private var levels = [Double](repeating: 0, count: AudioEffect.bands)

    override init() {
        super.init()
        ScreenSource.shared.use(self)
    }

    override func frame(_ field: KeyField, _ seconds: Double, _ elapsed: Double, _ colors: inout [Int]) {
        let bandCount = KeyField.sideways(direction) ? AudioEffect.rowBands : AudioEffect.bands
        let heard = ScreenSource.shared.bands(bandCount)
        problem = heard != nil ? nil : ScreenSource.shared.failure ?? (ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0))
            ? nil : "Audio needs macOS 13 or later to hear the Mac's sound.")
        for band in 0..<AudioEffect.bands {
            let level = heard != nil && band < bandCount ? heard![band] : 0
            levels[band] = level > levels[band] ? level : max(level, levels[band] - elapsed * 1.6)
        }
        let lanes = field.lanes(direction, bandCount), along = field.along(direction)
        let gain = 1.15 * (0.4 + level * 1.2)
        let red = color >> 16 & 0xFF, green = color >> 8 & 0xFF, blue = color & 0xFF, top = max(red, green, blue)
        let saturation = top == 0 ? 0 : Double(top - min(red, green, blue)) / Double(top)
        let grey = saturation < 0.05, value = Double(top) / 255
        let hue = AudioEffect.hue(red, green, blue)
        for i in 0..<field.count {
            let height = along[i], lit = max(0, min(1, (levels[lanes[i]] * gain - height) * 6 + 1))
            let shade = grey ? LiveEffects.blend(color, LiveEffects.scale(0xFF0000, value), height) : LiveEffects.hsv(hue - 0.33 * height, saturation, value)
            colors[i] = LiveEffects.scale(shade, lit)
        }
    }

    // A colour's hue from 0 to 1, as .NET's Color.GetHue gives it in degrees.
    static func hue(_ red: Int, _ green: Int, _ blue: Int) -> Double {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255, top = max(r, g, b), low = min(r, g, b)
        if top == low { return 0 }
        let delta = top - low
        let degrees = top == r ? (g - b) / delta * 60 : top == g ? (2 + (b - r) / delta) * 60 : (4 + (r - g) / delta) * 60
        return (degrees < 0 ? degrees + 360 : degrees) / 360
    }

    override func stop() { ScreenSource.shared.release(self) }
}

// Each key takes the colour of its area of the screen (app/Screen.cs, ScreenSettings.ZoneOf): the one it was given, else the one above
// its column; boosted and smoothed as on Windows (KeyboardPage.Sampled), at the setup's update rate. LiveRunner pauses it.
final class ScreenEffect: LiveEffect {
    var setup = ScreenSettings() {
        didSet { if setup.monitor != oldValue.monitor { source.release(self); source = ScreenSource.source(setup.monitor); source.use(self) } }
    }
    private var source = ScreenSource.shared
    private var shown: [Int] = []
    private var nextSample = 0.0

    override init() {
        super.init()
        Presence.watch()
        source.use(self)
    }

    override func frame(_ field: KeyField, _ seconds: Double, _ elapsed: Double, _ colors: inout [Int]) {
        if seconds >= nextSample, let sampled = source.sample(setup.zones.map { $0.area }) {
            nextSample = seconds + Double(setup.interval) / 1000
            let fresh = shown.count != sampled.count
            if fresh { shown = [Int](repeating: 0, count: sampled.count) }
            for zone in sampled.indices {
                let target = LiveEffects.boost(sampled[zone], setup.boost)
                shown[zone] = fresh || !setup.smooth ? target : LiveEffects.blend(shown[zone], target, 0.45)
            }
        }
        problem = shown.isEmpty ? source.failure : nil
        for i in 0..<field.count {
            let zone = setup.zoneOf(field.ids[i], field.x[i])
            colors[i] = zone < shown.count ? shown[zone] : 0
        }
    }

    override func stop() { source.release(self) }
}

// Key presses anywhere on the Mac, as USB usages, from a listen-only event tap (it needs Input Monitoring, which G-Lite already asks
// for). Only the usage is kept, to light the key; the tap is removed when the effect stops.
final class KeyPresses {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var usages: [Int] = []
    private let gate = NSLock()

    var listening: Bool { tap != nil }

    init() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                callback: { _, type, event, context in
            if type == .keyDown, let context = context {
                let presses = Unmanaged<KeyPresses>.fromOpaque(context).takeUnretainedValue()
                presses.heard(Int(event.getIntegerValueField(.keyboardEventKeycode)))
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context)
        guard let tap = tap else { return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func heard(_ keyCode: Int) {
        guard let usage = KeyPresses.usages[keyCode] else { return }
        gate.lock(); if usages.count < 64 { usages.append(usage) }; gate.unlock()
    }

    func take() -> [Int] {
        gate.lock(); defer { gate.unlock() }
        let taken = usages
        usages.removeAll()
        return taken
    }

    func stop() {
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    // A USB usage's 0x8081 lighting id: the usage minus 3, modifiers 0x68–0x6F (app/GameMode.cs, LightingId).
    static func lightingId(_ usage: Int) -> Int {
        if usage >= 0x04 && usage <= 0x67 { return usage - 3 }
        if usage >= 0xE0 && usage <= 0xE7 { return 0x68 + usage - 0xE0 }
        return -1
    }

    // macOS virtual key codes (Carbon's kVK_ constants, by position on an ANSI keyboard) to USB usages (the HID usage tables'
    // keyboard page).
    static let usages: [Int: Int] = [
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D,
        0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17,
        0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, 0x06: 0x1D,
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31,
        0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38, 0x39: 0x39,
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41, 0x65: 0x42, 0x6D: 0x43,
        0x67: 0x44, 0x6F: 0x45, 0x69: 0x46, 0x6B: 0x47, 0x71: 0x48, 0x72: 0x49, 0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D,
        0x79: 0x4E, 0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52, 0x47: 0x53, 0x4B: 0x54, 0x43: 0x55, 0x4E: 0x56, 0x45: 0x57,
        0x4C: 0x58, 0x53: 0x59, 0x54: 0x5A, 0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, 0x59: 0x5F, 0x5B: 0x60, 0x5C: 0x61,
        0x52: 0x62, 0x41: 0x63, 0x0A: 0x64, 0x6E: 0x65, 0x51: 0x67,
    ]
}

// Per-key colours through 0x8081 (app/Screen.cs, KeyLights): fn 0 lists the lit ids, fn 1 sets four keys (id R G B each), fn 6 one
// colour on up to 13 ids, fn 7 shows the frame. Frames are kept out of the log.
enum KeyLights {
    static func present(_ hidpp: Hidpp) throws -> Set<Int> {
        let feature = try hidpp.featureIndex(0x8081)
        var present = Set<Int>()
        for page in 0..<3 {
            let bits = try hidpp.call(feature, 0, [0, UInt8(page), 0])
            for i in 0..<14 { for bit in 0..<8 where bits[2 + i] >> bit & 1 != 0 { present.insert(page * 112 + i * 8 + bit) } }
        }
        return present
    }

    // fn 7 shows the frame. An owner's G515 answered it with error 08, busy, during Rain at a frame every 40 ms (docs/screen.md): busy
    // means try again, for up to about 200 ms.
    static func showFrame(_ hidpp: Hidpp, _ feature: UInt8) throws {
        var attempt = 1
        while true {
            do { try hidpp.callUnlogged(feature, 7, [0, 0, 0, 0, 0]); return } catch let error as GLiteError {
                if error.code != 8 || attempt >= 20 { throw error }
                Thread.sleep(forTimeInterval: 0.01)
                attempt += 1
            }
        }
    }

    // A frame of colours by lighting id: keys sharing a colour go three or more to a message (fn 6, up to 13), the others four to a
    // message (fn 1; a short message repeats its last key), then fn 7 shows it. individual turns false when the keyboard refuses fn 1,
    // and fn 6 takes every key from then on.
    static func sendColors(_ hidpp: Hidpp, _ colorById: [Int: Int], individual: inout Bool) throws {
        let feature = try hidpp.featureIndex(0x8081)
        var singles: [(Int, Int)] = [], groups: [Int: [Int]] = [:]
        for (color, entries) in Dictionary(grouping: colorById, by: { $0.value }) {
            if individual && entries.count < 3 { singles += entries.map { ($0.key, $0.value) } }
            else { groups[color] = entries.map { $0.key }.sorted() }
        }
        singles.sort { $0.0 < $1.0 }
        var start = 0
        while start < singles.count && individual {
            var batch = Array(singles[start..<min(start + 4, singles.count)])
            while batch.count < 4 { batch.append(batch[batch.count - 1]) }
            let parameters = batch.flatMap { [UInt8($0.0), UInt8($0.1 >> 16 & 0xFF), UInt8($0.1 >> 8 & 0xFF), UInt8($0.1 & 0xFF)] }
            do { try hidpp.callUnlogged(feature, 1, parameters) } catch GLiteError.hidpp {
                individual = false
                for (id, color) in singles[start...] { groups[color, default: []].append(id) }
            }
            start += 4
        }
        for (color, ids) in groups {
            for at in stride(from: 0, to: ids.count, by: 13) {
                let head = [UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)]
                try hidpp.callUnlogged(feature, 6, head + ids[at..<min(at + 13, ids.count)].map { UInt8($0) })
            }
        }
        try showFrame(hidpp, feature)
    }
}

// Runs a live effect on a keyboard page (app/KeyboardPage.cs, Animate): a frame every 40 ms on a cable, 100 ms without, drawn on the
// picture and the keys whose colour changed sent to the keyboard (all of them every 2 s, with the claim again). Without a cable a frame
// takes at most 40 keys, the most changed first.
final class LiveRunner {
    private weak var page: DevicePage?
    private let picture: KeyPicture
    private let claim: (Hidpp) throws -> Void, release: (Hidpp) throws -> Void
    private var pausedFor: String?, nextBattery = Date.distantPast
    private var effect: LiveEffect?, effectId: UInt8 = 0
    private var field: KeyField?
    private var timer: Timer?
    private var start = Date(), lastFrame = 0.0
    private var sentColors: [Int: Int]?, present: Set<Int>?
    private var individual = true, sending = false, claimed = false
    private var nextRefresh = Date.distantPast
    private(set) var problem: String?
    private static let wirelessKeysPerFrame = 40
    // The Screen effect's setup, from the page's Screen box.
    var screenSetup = ScreenSettings() { didSet { (effect as? ScreenEffect)?.setup = screenSetup } }
    // The Screen effect's picked area: its keys are outlined on the picture (app/KeyboardPage.cs, ShowLive).
    var screenZone: Int?

    init(page: DevicePage, picture: KeyPicture, claim: @escaping (Hidpp) throws -> Void, release: @escaping (Hidpp) throws -> Void) {
        self.page = page
        self.picture = picture
        self.claim = claim
        self.release = release
    }

    var running: Bool { timer != nil }

    // Starts or updates the effect from the screen's lighting.
    func run(_ lighting: Lighting) {
        if effect == nil || effectId != lighting.effect {
            stop()
            effect = LiveEffects.make(lighting.effect)
            (effect as? ScreenEffect)?.setup = screenSetup
            effectId = lighting.effect
            start = Date()
            lastFrame = 0
            guard let page = page else { return }
            let wired = page.device.link == "USB"
            timer = Timer.scheduledTimer(withTimeInterval: wired ? 0.04 : 0.1, repeats: true) { [weak self] _ in self?.frame() }
        }
        effect?.color = lighting.color
        effect?.period = lighting.period
        effect?.intensity = lighting.intensity
        effect?.direction = lighting.direction
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        effect?.stop()
        effect = nil
        sentColors = nil
        claimed = false
        pausedFor = nil
    }

    // The Screen effect's pause, as on Windows (KeyboardPage.Tick): the keys go back to the keyboard's own lighting until it ends, the
    // reason on the status line; the battery read every 60 s while Pause on low battery is on.
    private func paused(_ page: DevicePage) -> Bool {
        guard effect is ScreenEffect else { return false }
        let device = page.device
        if screenSetup.pauseOnBattery && device.has(0x1004) && Date() >= nextBattery && !sending {
            nextBattery = Date().addingTimeInterval(60)
            page.queue.async {
                guard let hidpp = try? page.connection(), let reply = try? hidpp.callUnlogged(try hidpp.featureIndex(0x1004), 1) else { return }
                DispatchQueue.main.async { device.battery = Int(reply[0]); device.charging = reply[2] != 0 }
            }
        }
        let why = screenSetup.pauseReason(away: Presence.away, battery: device.has(0x1004) ? device.battery : -1, charging: device.charging)
        if why != pausedFor {
            pausedFor = why
            page.status.show(why ?? "")
            sentColors = nil
        }
        guard why != nil else { return false }
        if claimed && !sending {
            sending = true
            claimed = false
            page.queue.async {
                defer { DispatchQueue.main.async { self.sending = false } }
                if let hidpp = try? page.connection() { try? self.release(hidpp) }
            }
        }
        return true
    }

    private func frame() {
        guard let effect = effect, let page = page else { return }
        if field == nil { field = KeyField.from(picture) }
        guard let field = field, !paused(page) else { return }
        let seconds = Date().timeIntervalSince(start), elapsed = min(0.25, seconds - lastFrame)
        lastFrame = seconds
        var colors = [Int](repeating: 0, count: field.count)
        effect.frame(field, seconds, elapsed, &colors)
        problem = effect.problem
        var byId: [Int: Int] = [:], inZone = Set<Int>()
        for i in 0..<field.count {
            byId[field.ids[i]] = colors[i]
            if let zone = screenZone, effect is ScreenEffect, screenSetup.zoneOf(field.ids[i], field.x[i]) == zone { inZone.insert(field.ids[i]) }
        }
        let outlined = screenZone != nil && effect is ScreenEffect ? (0..<picture.count).map { inZone.contains(picture.idOf($0)) } : nil
        picture.show((0..<picture.count).map { byId[picture.idOf($0)] ?? 0 }, marked: outlined)
        if sending { return }
        let full = sentColors == nil || Date() >= nextRefresh
        if full { nextRefresh = Date().addingTimeInterval(2) }
        var lastSent = sentColors ?? [:]
        var changes: [Int: Int] = [:]
        for (id, color) in byId {
            let before = lastSent[id]
            if full || before == nil || LiveEffects.distance(before!, color) > 9 || (color == 0 && before != 0) { changes[id] = color }
        }
        // One left out keeps its old colour in lastSent, so it comes back further off next frame; on a full frame it's forgotten, so it
        // goes first.
        if page.device.link != "USB" && changes.count > LiveRunner.wirelessKeysPerFrame {
            let ranked = changes.map { change in (change.key, lastSent[change.key].map { LiveEffects.distance($0, change.value) } ?? Int.max) }
                .sorted { $0.1 > $1.1 }
            for (id, _) in ranked.dropFirst(LiveRunner.wirelessKeysPerFrame) {
                changes[id] = nil
                if full { lastSent[id] = nil }
            }
        }
        if changes.isEmpty { return }
        for (id, color) in changes { lastSent[id] = color }
        sentColors = lastSent
        sending = true
        let claimAgain = full
        page.queue.async {
            defer { DispatchQueue.main.async { self.sending = false } }
            do {
                let hidpp = try page.connection()
                if self.present == nil { self.present = try KeyLights.present(hidpp) }
                if !self.claimed || claimAgain { try self.claim(hidpp); self.claimed = true }
                let lit = changes.filter { self.present!.contains($0.key) }
                var individual = self.individual
                try KeyLights.sendColors(hidpp, lit, individual: &individual)
                self.individual = individual
            } catch {
                // A failed frame forces a full one, with the claim, next time.
                DispatchQueue.main.async { self.sentColors = nil; self.claimed = false; self.problem = "\(error)" }
            }
        }
    }
}
