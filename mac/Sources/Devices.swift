import Foundation
import IOKit.hid

// What the scan learned about a device (app/FoundDevice.cs).
final class FoundDevice {
    var key = "", name = "", kind = "device", link = "", firmware = "", models = ""
    var port: Port?
    var index: UInt8 = 0xFF
    var wirelessId = 0, battery = -1, millivolts = 0, batteryId = 0
    var batteryFeature: UInt8 = 0
    var batteryFromVoltage = false, charging = false, asleep = false
    // Doesn't speak HID++ (the G510, the gamepads in D mode): listed from its USB id; the vendor collection is the G510's lighting.
    var plainHid = false, hasVendorCollection = false, hidpp10 = false
    // The USB product id, for the devices told apart by it.
    var usbId = 0
    var features: [Int] = []

    func has(_ feature: Int) -> Bool { features.contains(feature) }

    var isG515: Bool {
        let upper = name.uppercased()
        return upper.contains("G515") && !upper.contains("RAPID") && has(0x8071) && has(0x8040) && has(0x8101)
    }
    var isG: Bool { FoundDevice.looksG(name) || isLitra }
    var isG915: Bool {
        let upper = name.uppercased()
        return (upper.contains("G915") || upper.contains("G815")) && !upper.contains("G915 X")
            && has(0x8071) && has(0x8040) && has(0x8100) && !has(0x8101)
    }
    var isLedKeyboard: Bool { kind == "keyboard" && has(0x8070) && !has(0x8071) }
    var isHeadset: Bool { kind == "headset" && has(0x8300) }
    // A Litra by its name or USB id (C900–C903); with 0x1990, its front light, G-Lite can set it.
    var isLitra: Bool { name.uppercased().contains("LITRA") || (0xC900...0xC903).contains(port?.productId ?? 0) }
    var isLight: Bool { isLitra && has(0x1990) }
    // The old HID++ 1.0 mice, by USB id or the G700's wireless id (app/FoundDevice.cs).
    var isG9x: Bool { hidpp10 && [0xC066, 0xC249].contains(usbId) }
    var isG500: Bool { hidpp10 && ([0xC068, 0xC24E, 0xC06B, 0xC07C].contains(usbId) || wirelessId == 0x1023 || wirelessId == 0x102A) }
    var isG5: Bool { hidpp10 && [0xC041, 0xC049].contains(usbId) }
    var isG9: Bool { hidpp10 && usbId == 0xC048 }
    var g500Model: G9xModel {
        if wirelessId == 0x1023 { return .g700 }
        if wirelessId == 0x102A { return .g700s }
        return usbId == 0xC24E ? .g500s : usbId == 0xC06B ? .g700 : usbId == 0xC07C ? .g700s : .g500
    }
    // The G600 and G300 don't speak HID++: their settings are feature reports on their vendor collection (G600.swift, G300.swift).
    var isG600: Bool { plainHid && hasVendorCollection && usbId == 0xC24A }
    var isG300: Bool { plainHid && hasVendorCollection && usbId == 0xC246 }
    var isG510: Bool { plainHid && hasVendorCollection && [0xC22D, 0xC22E].contains(usbId) }
    var isG560: Bool { name.uppercased().contains("G560") && has(0x8070) }
    // Any other G keyboard with 0x8071 and 0x8040 gets live lighting (app/KeyboardKinds.cs): the G512 X 75, the G915 X, the G515 RAPID.
    var isRgbKeyboard: Bool { kind == "keyboard" && has(0x8071) && has(0x8040) }
    var isMouse: Bool { kind == "mouse" && (has(0x2201) || has(0x2202)) }
    // The G305 and G304 (4074) have one status LED that 0x8070 drives live, but the mouse ignores the profile's lighting record: saved
    // as Static, the LED went off at the reload (tried on a G305; libratbag lists no LEDs for it).
    var lightIsLiveOnly: Bool { wirelessId == 0x4074 }
    var wired: Bool { link == "USB" }

    var settingsKey: String { String(shortName.lowercased().filter { $0.isLetter || $0.isNumber }) }

    var shortName: String {
        var text = FoundDevice.replace(name, "^" + FoundDevice.gamingFirst, "")
        text = FoundDevice.replace(text, #"(\s+(Wireless\s+)?(RGB\s+)?Mechanical)?\s+Gaming\s+(Mouse|Headset|Keyboard)$"#, "")
        return FoundDevice.replace(text, #"\s+LIGHTSPEED\b"#, "")
    }

    var batteryText: String { battery < 0 ? "" : "\(battery)%" + (charging ? ", charging" : "") }

    static func replace(_ text: String, _ pattern: String, _ with: String) -> String {
        text.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
    }

    // Some older devices put the model last: "Gaming Keyboard G213".
    static let gamingFirst = #"((\w+\s+)*?Gaming\s+(Keyboard|Mouse|Headset)\s+(?=G\s?\d))"#

    static func looksG(_ name: String) -> Bool {
        name.range(of: #"^(Logitech\s+)?"# + gamingFirst + #"?(G\s?\d|G\s+PRO|PRO\b|ASTRO|A\d0\b)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func modelText(_ info: [UInt8]?) -> String {
        guard let info = info, info.count >= 13 else { return "" }
        let transports = Int(info[5]) << 8 | Int(info[6])
        let ids = (0..<3).map { Int(info[7 + 2 * $0]) << 8 | Int(info[8 + 2 * $0]) }
        let names = ["Bluetooth", "Bluetooth", "LIGHTSPEED", "USB"]
        let labels = (0..<4).filter { transports >> $0 & 1 != 0 }.map { names[$0] }
        let matches = !labels.isEmpty && labels.count <= 3
            && ids.prefix(labels.count).allSatisfy { $0 != 0 } && ids.dropFirst(labels.count).allSatisfy { $0 == 0 }
        if !matches { return ids.filter { $0 != 0 }.map { String(format: "%04X", $0) }.joined(separator: ", ") }
        let order = ["USB", "LIGHTSPEED", "Bluetooth"]
        return labels.enumerated().map { ($0.element, ids[$0.offset]) }
            .sorted { order.firstIndex(of: $0.0)! < order.firstIndex(of: $1.0)! }
            .map { $0.0 + " " + String(format: "%04X", $0.1) }.joined(separator: ", ")
    }

    static func firmwareText(_ info: [UInt8]) -> String {
        let prefix = String(info[1...3].prefix { $0 >= 0x20 && $0 < 0x7F }.map { Character(UnicodeScalar($0)) })
            .trimmingCharacters(in: .whitespaces)
        return (prefix + " " + String(format: "%02X.%02X, build %02X%02X", info[4], info[5], info[6], info[7]))
            .trimmingCharacters(in: .whitespaces)
    }

    static func fromVolts(_ millivolts: Int) -> Int { max(0, min(100, (millivolts - 3500) * 100 / 600)) }

    // A few points of G HUB's charging model for the G Pro Wireless (app/FoundDevice.cs).
    static let chargingCurve = [3270, 2, 3670, 3, 3790, 5, 3910, 8, 4000, 20, 4050, 33, 4100, 46, 4150, 57, 4200, 68]

    static func fromChargingVolts(_ millivolts: Int) -> Int {
        let curve = chargingCurve
        if millivolts <= curve[0] { return curve[1] }
        for i in stride(from: 2, to: curve.count, by: 2) where millivolts <= curve[i] {
            return curve[i - 1] + (millivolts - curve[i - 2]) * (curve[i + 1] - curve[i - 1]) / (curve[i] - curve[i - 2])
        }
        return curve[curve.count - 1]
    }
}

// The scan's calls, with short timeouts and no errors thrown (app/Devices.cs, ScanProbe).
final class Probe {
    static let softwareId: UInt8 = 0x0D
    let port: Port
    private let reader: Reader
    private var lastError = -1

    init(_ port: Port) throws { self.port = port; reader = try port.reader() }
    deinit { port.remove(reader) }

    // 1 for a HID++ 1.0 device: it answers with error 01, invalid sub-ID (Solaar's base.ping). 0 for no answer.
    func ping(_ index: UInt8, _ timeout: Int) -> Int {
        lastError = -1
        if let reply = send(index, 0, 1, timeout, [0, 0, 0x5A]) { return Int(reply[0]) }
        return lastError == 1 ? 1 : 0
    }

    func feature(_ index: UInt8, _ id: Int) -> UInt8 { call(index, 0, 0, [UInt8(id >> 8), UInt8(id & 0xFF)])?[0] ?? 0 }

    func call(_ index: UInt8, _ feature: UInt8, _ fn: Int, _ parameters: [UInt8] = []) -> [UInt8]? {
        send(index, feature, fn, 3000, parameters)
    }

    private func send(_ index: UInt8, _ feature: UInt8, _ fn: Int, _ timeout: Int, _ parameters: [UInt8]) -> [UInt8]? {
        var message = [UInt8](repeating: 0, count: 20)
        message[0] = 0x11; message[1] = index; message[2] = feature; message[3] = UInt8(fn << 4) | Probe.softwareId
        for (i, value) in parameters.prefix(16).enumerated() { message[4 + i] = value }
        reader.drain()
        guard (try? port.write(message)) != nil else { return nil }
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000)
        while let reply = reader.next(until: deadline) {
            if reply[1] != index { continue }
            if reply[2] == 0x8F && reply[3] == feature { lastError = Int(reply[5]); return nil }
            if reply[2] == 0xFF && reply[3] == feature && reply[4] == message[3] { return nil }
            if reply[2] == feature && reply[3] == message[3] { return Array(reply[4...]) }
        }
        return nil
    }

    func register(_ index: UInt8, _ subId: UInt8, _ register: UInt8, _ parameter: UInt8) -> [UInt8]? {
        guard port.hasShort else { return nil }
        reader.drain()
        guard (try? port.write([0x10, index, subId, register, parameter, 0, 0])) != nil else { return nil }
        let deadline = Date().addingTimeInterval(1)
        while let reply = reader.next(until: deadline) {
            if reply[1] != index { continue }
            if reply[2] == 0x8F && reply[3] == subId { return nil }
            if reply[2] == subId && reply[3] == register { return Array(reply[4...]) }
        }
        return nil
    }
}

enum Devices {
    static let kinds = ["keyboard", "device", "device", "mouse", "mouse", "mouse", "device", "device", "headset"]
    static let batteryFeatures = [0x1004, 0x1000, 0x1001, 0x1F20]

    // A receiver's 0x41 notice: flags bit 6 is set while the link is down (app/Devices.cs).
    static func linkUp(_ report: [UInt8]) -> Bool { report.count > 4 && report[4] & 0x40 == 0 }

    private static var manager: IOHIDManager = {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        return manager
    }()
    private static var ports: [UInt64: Port] = [:]
    private static let gate = NSLock()

    // Called on the main queue when a Logitech device comes or goes.
    static func watchPlugging(_ changed: @escaping () -> Void) {
        let box = Unmanaged.passRetained(ChangeBox(changed)).toOpaque()
        HidThread.shared.sync {
            let callback: IOHIDDeviceCallback = { context, _, _, _ in
                let box = Unmanaged<ChangeBox>.fromOpaque(context!).takeUnretainedValue()
                DispatchQueue.main.async { box.changed() }
            }
            IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, box)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, box)
            IOHIDManagerScheduleWithRunLoop(manager, HidThread.shared.runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    final class ChangeBox { let changed: () -> Void; init(_ changed: @escaping () -> Void) { self.changed = changed } }

    // The HID++ interfaces: a vendor collection taking 20-byte reports, FF00 usage 2 on receivers and USB devices, FF43 usage 0202
    // over Bluetooth.
    static func hidppPorts() -> [Port] {
        let devices = HidThread.shared.sync { IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] }
        gate.lock(); defer { gate.unlock() }
        var found: [Port] = []
        for device in devices {
            let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]] ?? []
            let usages = pairs.map { ($0[kIOHIDDeviceUsagePageKey] ?? 0, $0[kIOHIDDeviceUsageKey] ?? 0) }
            if plainNames[Port.int(device, kIOHIDProductIDKey)] != nil { continue }
            let long = usages.contains { ($0.0 == 0xFF00 && $0.1 == 2) || ($0.0 == 0xFF43 && $0.1 == 0x0202) }
            let output = Port.int(device, kIOHIDMaxOutputReportSizeKey)
            // Like Windows (app/Devices.cs, Ports), also any vendor collection whose output reports are 20 bytes: a headset's dongle
            // (the PRO X Wireless's 0ABA answers HID++ itself) may not use the receivers' usages.
            if !(long && output >= 20) && !(usages.contains { $0.0 >= 0xFF00 } && output == 20) { continue }
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entry)
            let port = ports[entry] ?? Port(device: device, hasShort: usages.contains { $0.0 == 0xFF00 && $0.1 == 1 })
            ports[entry] = port
            found.append(port)
        }
        let ids = Set(found.map { $0.id })
        ports = ports.filter { ids.contains($0.key) }
        return found
    }

    // The devices that don't speak HID++ (app/Devices.cs, PlainNames): the G510 and G510s, and the F310, F510 and F710 gamepads in
    // D mode (docs/G510.md, docs/gamepads.md).
    static let plainNames: [Int: (String, String)] = [
        0xC22D: ("G510 Gaming Keyboard", "keyboard"), 0xC22E: ("G510 Gaming Keyboard", "keyboard"),
        0xC24A: ("G600 Gaming Mouse", "mouse"), 0xC246: ("G300 Gaming Mouse", "mouse"),
        0xC216: ("Gamepad F310", "gamepad"), 0xC218: ("Rumble Gamepad F510", "gamepad"), 0xC219: ("Wireless Gamepad F710", "gamepad"),
    ]

    // One per product id; the G510 takes its feature reports on its vendor collection (usage page FF00, MI_01&COL02 in an owner's
    // report), which on a Mac is the interface that lists that page.
    static func plainDevices() -> [FoundDevice] {
        let devices = HidThread.shared.sync { IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] }
        var found: [Int: FoundDevice] = [:]
        for device in devices {
            let productId = Port.int(device, kIOHIDProductIDKey)
            guard let (known, kind) = plainNames[productId] else { continue }
            let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]] ?? []
            // The G600 and the G300 take theirs on usage page FF80 (LGS's device files; the G300's from PeriHub).
            let vendorPage = [0xC22D: 0xFF00, 0xC22E: 0xFF00, 0xC24A: 0xFF80, 0xC246: 0xFF80][productId]
            let vendor = vendorPage.map { page in pairs.contains { $0[kIOHIDDeviceUsagePageKey] == page } } ?? false
            if let already = found[productId], already.hasVendorCollection || !vendor { continue }
            let port = Port(device: device, hasShort: false)
            let entry = FoundDevice()
            entry.key = String(format: "plain|%04X", productId); entry.port = port; entry.usbId = productId; entry.plainHid = true; entry.hasVendorCollection = vendor
            let product = FoundDevice.replace(port.product, #"^Logitech\s+"#, "")
            entry.name = FoundDevice.looksG(product) ? product : known
            entry.kind = kind; entry.link = "USB"; entry.models = String(format: "USB %04X", productId)
            found[productId] = entry
        }
        return found.values.sorted { $0.key < $1.key }
    }

    static func linkOf(_ port: Port) -> String {
        if port.transport.hasPrefix("Bluetooth") { return "Bluetooth" }
        switch port.productId {
        case 0xC52B, 0xC532, 0xC534: return "Unifying"
        case 0xC548: return "Bolt"
        case 0xC531: return "Wireless"
        default: return "LIGHTSPEED"
        }
    }

    // Whether the last scan was refused a device: Input Monitoring isn't granted to this build.
    static var refused = false

    static func scan() -> [FoundDevice] {
        let ports = hidppPorts()
        refused = false
        if ports.isEmpty { Log.add("G-Lite", "error", "the scan found no HID++ interface") }
        var all: [FoundDevice] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for port in ports {
            DispatchQueue.global().async(group: group) {
                var found: [FoundDevice] = []
                do { found = try scanPort(port) } catch {
                    if case GLiteError.notPermitted = error { refused = true }
                    Log.add("G-Lite", "error", "couldn't scan " + (port.product.isEmpty ? "a Logitech device" : port.product) + ": \(error)")
                }
                lock.lock(); all += found; lock.unlock()
            }
        }
        _ = group.wait(timeout: .now() + 20)
        lock.lock(); let everything = all + plainDevices(); lock.unlock()
        // An asleep receiver slot is dropped when an awake device lists its wireless id, like a keyboard on its cable.
        let devices = everything.filter { device in
            !(device.asleep && device.wirelessId != 0 && everything.contains { other in
                !other.asleep && other.models.range(of: "\\b" + String(format: "%04X", device.wirelessId) + "\\b",
                                                    options: .regularExpression) != nil
            })
        }
        for device in devices where device.isLitra { device.kind = "light" }
        for device in devices where !device.asleep && device.wirelessId != 0 {
            Settings.set("seen." + String(format: "%04X", device.wirelessId), device.name + "|" + device.kind)
        }
        let kindOrder = ["keyboard": 0, "mouse": 1, "headset": 2]
        return devices.filter { !$0.name.isEmpty }.sorted {
            ($0.isG ? 0 : 1, kindOrder[$0.kind] ?? 3, $0.name) < ($1.isG ? 0 : 1, kindOrder[$1.kind] ?? 3, $1.name)
        }
    }

    // A HID++ 2.0 device at 0xFF, else the receiver's slots (HID++ 2.0 or 1.0, probeHidpp10), else an old HID++ 1.0 USB device at
    // index 0; the plain HID devices are found apart (plainDevices).
    static func scanPort(_ port: Port) throws -> [FoundDevice] {
        let probe = try Probe(port)
        if probe.ping(0xFF, 800) >= 2 {
            let device = describe(probe, 0xFF, linkOf(port) == "Bluetooth" ? "Bluetooth" : "USB")
            if device.link == "USB" && device.kind == "headset" && batteryFeatures.contains(where: device.has) {
                device.link = "LIGHTSPEED"
            }
            return [device]
        }
        guard port.hasShort else { return [] }
        let link = linkOf(port)
        var found: [FoundDevice] = []
        for slot in UInt8(1)...6 {
            var pair = probe.register(0xFF, 0x83, 0xB5, 0x20 + slot - 1)
            var wirelessId: Int, kind: Int
            if let listed = pair { wirelessId = Int(listed[3]) << 8 | Int(listed[4]); kind = Int(listed[7]) } else {
                // Bolt receivers keep pairings in 0x5N, with the wireless id's bytes swapped (Solaar's BoltReceiver).
                pair = link == "Bolt" ? probe.register(0xFF, 0x83, 0xB5, 0x50 + slot) : nil
                // The G700's receiver (C531) is a Nano receiver with one device (Solaar); whether it lists it in 0xB5 isn't known, so
                // slot 1 is tried anyway.
                if pair == nil && !(link == "Wireless" && slot == 1) { continue }
                wirelessId = pair.map { Int($0[3]) << 8 | Int($0[2]) } ?? 0
                kind = pair.map { Int($0[1] & 0x0F) } ?? 2
            }
            let device: FoundDevice
            // A slot the receiver didn't list (the C531's slot 1) gets a short ping: an asleep or absent mouse shouldn't hold up
            // every scan.
            let protocolVersion = probe.ping(slot, pair == nil ? 1000 : 3500)
            if protocolVersion >= 2 {
                device = describe(probe, slot, link)
            } else if protocolVersion == 1 {
                device = probeHidpp10(probe, slot, link, wirelessId)
            } else {
                device = FoundDevice()
                device.port = port; device.index = slot; device.link = link; device.asleep = true
                let seen = Settings.get("seen." + String(format: "%04X", wirelessId)).components(separatedBy: "|")
                device.name = !seen[0].isEmpty ? seen[0] : link == "LIGHTSPEED" ? "G device" : ""
                device.kind = seen.count > 1 ? seen[1] : kind == 1 ? "keyboard" : kind == 2 ? "mouse" : "device"
            }
            device.wirelessId = wirelessId
            device.key = "\(port.id)|\(slot)"
            found.append(device)
        }
        // Neither a direct device nor a receiver: an old HID++ 1.0 USB device at index 0 (register 0xF1, firmware), like the G9x.
        if found.isEmpty, let firmware = probe.register(0x00, 0x81, 0xF1, 0x01) {
            let device = probeHidpp10(probe, firmware)
            if device.kind != "device" { found.append(device) }
        }
        return found
    }

    // Wireless HID++ 1.0 devices, named by their wireless id (Solaar's descriptors).
    static let oldWireless: [Int: (String, String)] = [0x1023: ("G700 Gaming Mouse", "mouse"), 0x102A: ("G700s Gaming Mouse", "mouse")]

    static func firmwareText(_ firmware: [UInt8], _ build: [UInt8]?) -> String {
        String(format: "%02X.%02X", firmware[1], firmware[2]) + (build.map { String(format: ", build %02X%02X", $0[1], $0[2]) } ?? "")
    }

    // A HID++ 1.0 device in a receiver slot: it answered the HID++ 2.0 ping with "invalid sub-ID".
    static func probeHidpp10(_ probe: Probe, _ slot: UInt8, _ link: String, _ wirelessId: Int) -> FoundDevice {
        let firmware = probe.register(slot, 0x81, 0xF1, 0x01)
        let build = firmware == nil ? nil : probe.register(slot, 0x81, 0xF1, 0x02)
        let known = oldWireless[wirelessId] ?? (link == "Wireless" ? "G700 / G700s" : "", "mouse")
        let device = FoundDevice()
        device.port = probe.port; device.index = slot; device.link = link; device.hidpp10 = true
        device.name = known.0; device.kind = known.1
        device.firmware = firmware.map { firmwareText($0, build) } ?? ""
        device.models = wirelessId == 0 ? "" : link + String(format: " %04X", wirelessId)
        return device
    }

    // An old HID++ 1.0 USB device, named from its USB product string.
    static func probeHidpp10(_ probe: Probe, _ firmware: [UInt8]) -> FoundDevice {
        let build = probe.register(0x00, 0x81, 0xF1, 0x02)
        let device = FoundDevice()
        device.port = probe.port; device.index = 0; device.key = "\(probe.port.id)|0"; device.link = "USB"; device.hidpp10 = true
        device.name = FoundDevice.replace(probe.port.product, #"^Logitech\s+"#, "")
        let lower = device.name.lowercased()
        device.kind = lower.contains("mouse") ? "mouse" : lower.contains("keyboard") ? "keyboard" : lower.contains("headset") ? "headset" : "device"
        device.firmware = firmwareText(firmware, build)
        device.usbId = probe.port.productId
        device.models = String(format: "USB %04X", probe.port.productId)
        return device
    }

    static func describe(_ probe: Probe, _ index: UInt8, _ link: String) -> FoundDevice {
        let device = FoundDevice()
        device.port = probe.port; device.index = index; device.link = link; device.key = "\(probe.port.id)|\(index)"
        let featureSet = probe.feature(index, 0x0001)
        if featureSet != 0, let count = probe.call(index, featureSet, 0) {
            for i in 1...max(1, Int(count[0])) where i <= count[0] {
                if let id = probe.call(index, featureSet, 1, [UInt8(i)]) { device.features.append(Int(id[0]) << 8 | Int(id[1])) }
            }
        }
        let nameFeature = probe.feature(index, 0x0005)
        if nameFeature != 0 {
            let length = probe.call(index, nameFeature, 0).map { Int($0[0]) }
            var name = ""
            var offset = 0
            while let length = length, offset < length {
                guard let part = probe.call(index, nameFeature, 1, [UInt8(offset)]) else { break }
                name += String(part.prefix(16).prefix { $0 != 0 }.map { Character(UnicodeScalar($0)) })
                offset += 16
            }
            device.name = String(name.prefix(length ?? name.count)).trimmingCharacters(in: .whitespaces)
            if let type = probe.call(index, nameFeature, 2), Int(type[0]) < kinds.count { device.kind = kinds[Int(type[0])] }
        }
        if device.name.isEmpty && index == 0xFF {
            device.name = FoundDevice.replace(probe.port.product, #"^Logitech\s+"#, "")
        }
        let firmwareFeature = probe.feature(index, 0x0003)
        let entities = firmwareFeature == 0 ? nil : probe.call(index, firmwareFeature, 0)
        device.models = FoundDevice.modelText(entities)
        // The running firmware is the main application (type 0) marked active, byte 8 bit 0 (spec x0003 v4).
        var info: [UInt8]?
        var entity = 0
        while let entities = entities, entity < entities[0], info == nil || info![8] & 1 == 0 {
            if let reply = probe.call(index, firmwareFeature, 1, [UInt8(entity)]), reply[0] == 0, info == nil || reply[8] & 1 != 0 {
                info = reply
            }
            entity += 1
        }
        if let info = info { device.firmware = FoundDevice.firmwareText(info) }
        for id in batteryFeatures {
            let featureIndex = probe.feature(index, id)
            if featureIndex == 0 { continue }
            guard let reply = probe.call(index, featureIndex, id == 0x1004 ? 1 : 0) else { continue }
            device.batteryFeature = featureIndex
            device.batteryId = id
            decode(device, reply)
            break
        }
        return device
    }

    static func readBattery(_ device: FoundDevice) {
        guard device.batteryFeature != 0, let port = device.port, let probe = try? Probe(port),
              let reply = probe.call(device.index, device.batteryFeature, device.batteryId == 0x1004 ? 1 : 0) else { return }
        decode(device, reply)
    }

    static func decode(_ device: FoundDevice, _ reply: [UInt8]) {
        if device.batteryId == 0x1004 { device.battery = Int(reply[0]); device.charging = reply[2] == 1 || reply[2] == 2; return }
        if device.batteryId == 0x1000 {
            device.battery = Int(reply[0]); device.charging = reply[2] == 1 || reply[2] == 2 || reply[2] == 4; return
        }
        device.millivolts = Int(reply[0]) << 8 | Int(reply[1])
        device.batteryFromVoltage = true
        device.charging = device.batteryId == 0x1001 ? reply[2] & 0x80 != 0 : reply[2] == 3
        device.battery = !device.charging ? FoundDevice.fromVolts(device.millivolts)
            : device.batteryId == 0x1001 && reply[2] & 0x07 == 1 ? 100
            : FoundDevice.fromChargingVolts(device.millivolts)
    }
}

// Listens to each device's port: a receiver's 0x41 (a device came or went), battery events, and the device's other HID++ events
// (software id 0, which G-Lite's own calls never use), handed to its screen (app/Devices.cs, DeviceWatcher; MainWindow.Heard).
final class DeviceWatcher {
    private var readers: [(Port, Reader)] = []

    init(_ devices: [FoundDevice], linkChanged: @escaping () -> Void, battery: @escaping (FoundDevice) -> Void,
         event: @escaping (FoundDevice, [UInt8]) -> Void) {
        var seen = Set<UInt64>()
        for device in devices {
            guard let port = device.port, !seen.contains(port.id), let reader = try? port.reader() else { continue }
            seen.insert(port.id)
            let mine = devices.filter { $0.port === port }
            reader.heard = { report in
                if report[2] == 0x41 { DispatchQueue.main.async(execute: linkChanged); return }
                guard report[0] == 0x11, report[3] & 0x0F == 0, report[2] != 0xFF,
                      let device = mine.first(where: { $0.index == report[1] }) else { return }
                if device.batteryFeature != 0 && report[2] == device.batteryFeature && report[3] == 0 {
                    Devices.decode(device, Array(report[4...]))
                    DispatchQueue.main.async { battery(device) }
                    return
                }
                DispatchQueue.main.async { event(device, report) }
            }
            readers.append((port, reader))
        }
    }

    func stop() { for (port, reader) in readers { port.remove(reader) }; readers.removeAll() }
}
