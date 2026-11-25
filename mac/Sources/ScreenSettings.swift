import AppKit

// An area of the screen the Screen effect follows, as fractions of the screen.
struct Zone: Equatable {
    var name: String
    var markColor: Int
    var area: CGRect
}

// The Screen effect's setup, in the Windows text (app/Screen.cs, ScreenSettings), kept as screen.<device>.
// A key takes the area it was given, else the one above its column.
struct ScreenSettings: Equatable {
    static let markColors = [0x3B82F6, 0x8B6CF0, 0xE5533D, 0xF29D38, 0x2FB57D, 0x22B8C8, 0xE0559A]
    // A keyboard's areas, as on Windows (the Litra's seven columns are set, not added).
    static let maxZones = 5
    static let batteryLimit = 20
    // The monitor: "" the main one, else its display id (Windows keeps a device name; a Mac's settings aren't a PC's).
    var monitor = ""
    var zones = ScreenSettings.defaults()
    var keys: [Int: Int] = [:]
    var boost = 33, interval = 100, bright = 100
    var smooth = true, pauseOnBattery = true, pauseWhenLocked = true

    static func defaults() -> [Zone] {
        ["Left", "Middle left", "Middle right", "Right"].enumerated().map {
            Zone(name: $0.element, markColor: markColors[$0.offset], area: CGRect(x: CGFloat($0.offset) * 0.25, y: 0.5, width: 0.25, height: 0.35))
        }
    }

    // Why a keyboard's Screen effect waits, nil while it runs (app/KeyboardPage.cs, Paused); the battery from 0x1004, -1 unknown.
    func pauseReason(away: Bool, battery: Int, charging: Bool) -> String? {
        if pauseWhenLocked && away { return "Paused while the screen is off or locked." }
        if pauseOnBattery && battery >= 0 && !charging && battery < ScreenSettings.batteryLimit {
            return "Paused: battery below \(ScreenSettings.batteryLimit)%."
        }
        return nil
    }

    // A new area in the middle of the screen, in the first colour no area has; nil once there are maxZones.
    mutating func add() -> Int? {
        guard zones.count < ScreenSettings.maxZones,
              let mark = ScreenSettings.markColors.first(where: { color in !zones.contains { $0.markColor == color } }) else { return nil }
        zones.append(Zone(name: "Zone \(zones.count + 1)", markColor: mark, area: CGRect(x: 0.375, y: 0.3, width: 0.25, height: 0.3)))
        return zones.count - 1
    }

    // The keys given to a removed area go to the one before it, as on Windows.
    mutating func remove(_ index: Int) {
        guard zones.count > 1, zones.indices.contains(index) else { return }
        zones.remove(at: index)
        for (id, zone) in keys where zone >= index { keys[id] = zone == index ? max(0, index - 1) : zone - 1 }
    }

    // A key's area: the one it was given, else the one above its column.
    func zoneOf(_ id: Int, _ x: Double) -> Int {
        if id >= 0, let zone = keys[id], zone < zones.count { return zone }
        return max(0, min(zones.count - 1, Int(x * Double(zones.count))))
    }

    // How many keys each area lights, the way the Screen effect places them.
    func counts(_ field: KeyField) -> [Int] {
        var counts = [Int](repeating: 0, count: zones.count)
        for i in 0..<field.count { counts[zoneOf(field.ids[i], field.x[i])] += 1 }
        return counts
    }

    static func number(_ value: CGFloat) -> String {
        let format = NumberFormatter()
        format.maximumFractionDigits = 3
        format.minimumIntegerDigits = 1
        format.locale = Locale(identifier: "en_US_POSIX")
        return format.string(from: NSNumber(value: Double(value))) ?? "0"
    }

    func toText() -> String {
        ["mon:" + monitor, "boost:\(boost)", "ms:\(interval)", "bright:\(bright)", "smooth:\(smooth ? 1 : 0)", "bat:\(pauseOnBattery ? 1 : 0)",
         "lock:\(pauseWhenLocked ? 1 : 0)",
         "zones:" + zones.map { zone in
            [zone.name, String(format: "%06X", zone.markColor), ScreenSettings.number(zone.area.minX), ScreenSettings.number(zone.area.minY),
             ScreenSettings.number(zone.area.width), ScreenSettings.number(zone.area.height)].joined(separator: ",")
         }.joined(separator: "/"),
         "keys:" + keys.sorted { $0.key < $1.key }.map { String(format: "%02X.%d", $0.key, $0.value) }.joined(separator: ","),
        ].joined(separator: ";")
    }

    static func fromText(_ text: String) -> ScreenSettings {
        var setup = ScreenSettings()
        if text.isEmpty { return setup }
        for part in text.components(separatedBy: ";") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = String(part[..<colon]), value = String(part[part.index(after: colon)...])
            func clamp(_ low: Int, _ high: Int) -> Int? { Int(value).map { max(low, min(high, $0)) } }
            switch key {
            case "mon": setup.monitor = value
            case "boost": setup.boost = clamp(0, 100) ?? setup.boost
            case "bright": setup.bright = clamp(1, 100) ?? setup.bright
            case "ms": setup.interval = Int(value).map { max(100, min(1000, $0 / 100 * 100)) } ?? setup.interval
            case "smooth": setup.smooth = value == "1"
            case "bat": setup.pauseOnBattery = value.components(separatedBy: ":")[0] == "1"
            case "lock": setup.pauseWhenLocked = value == "1"
            case "zones":
                let zones: [Zone] = value.components(separatedBy: "/").compactMap { zoneText in
                    let fields = zoneText.components(separatedBy: ",")
                    guard fields.count >= 6, let mark = Int(fields[1], radix: 16) else { return nil }
                    func fraction(_ i: Int) -> CGFloat { CGFloat(max(0, min(1, Double(fields[i]) ?? 0))) }
                    return Zone(name: fields[0], markColor: mark, area: CGRect(x: fraction(2), y: fraction(3), width: fraction(4), height: fraction(5)))
                }
                if !zones.isEmpty { setup.zones = Array(zones.prefix(markColors.count)) }
            case "keys":
                for entry in value.components(separatedBy: ",") where entry.contains(".") {
                    let parts = entry.components(separatedBy: ".")
                    if let id = Int(parts[0], radix: 16), let zone = Int(parts[1]) { setup.keys[id] = zone }
                }
            default: break
            }
        }
        return setup
    }

    // The G560's and the Litra's setups: their own areas when the text has another count (app/ZoneLighting.cs and
    // app/LitraProtocol.cs, Screen).
    static func corners(_ text: String) -> ScreenSettings {
        var setup = fromText(text)
        let names = ["Bottom left", "Bottom right", "Top left", "Top right"]
        if text.isEmpty || setup.zones.count != 4 {
            setup.zones = ScreenFollower.corners.enumerated().map { Zone(name: names[$0.offset], markColor: markColors[$0.offset], area: $0.element) }
        }
        for i in 0..<4 { setup.zones[i].name = names[i] }
        return setup
    }

    static func columns(_ text: String) -> ScreenSettings {
        var setup = fromText(text)
        if text.isEmpty || setup.zones.count != 7 {
            setup.zones = ScreenFollower.columns.enumerated().map { Zone(name: "\($0.offset + 1)", markColor: markColors[$0.offset], area: $0.element) }
        }
        return setup
    }
}

// Whether the screen is locked or off, for the Screen effect's pause (app/Screen.cs, Presence): the lock and unlock notices, and the
// screens' sleep and wake.
enum Presence {
    private(set) static var locked = false, displayOff = false
    private static var watching = false

    static var away: Bool { locked || displayOff }

    static func watch() {
        if watching { return }
        watching = true
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in locked = true }
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in locked = false }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in displayOff = true }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in displayOff = false }
    }
}
