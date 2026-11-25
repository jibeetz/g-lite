import Foundation
import IOKit.hid

// The device report (app/Report.cs): what G-Lite reads from a device, to paste into an issue when adding support for it. Read only:
// every HID++ 2.0 call goes through Reader.readOnlyCall, which refuses any function not in reads (or getOrSet with 0 first). Same
// sections and text as Windows, so a report reads the same from either.
enum Report {
    static let reads: [Int: [Int]] = [
        0x0001: [0, 1], 0x0003: [0, 1], 0x1990: [0, 2, 3, 7, 8], 0x1814: [0], 0x1815: [0, 1], 0x1982: [0, 2], 0x1B04: [0, 1],
        0x1F20: [0, 1], 0x2110: [0], 0x2111: [0, 1], 0x2121: [0, 1, 3], 0x2150: [0, 1], 0x2201: [0, 1, 2], 0x2202: [0, 1, 2, 3, 4, 5],
        0x4540: [0], 0x8010: [0], 0x8020: [0], 0x8040: [0, 1], 0x8060: [0, 1], 0x8061: [0, 1, 2], 0x8070: [0, 1, 2], 0x8071: [0],
        0x8081: [0], 0x8100: [0, 2, 4, 5, 0xB], 0x8110: [0], 0x8101: [8, 0xC], 0x8300: [0], 0x8310: [0, 1, 2],
    ]

    // Functions that read when their first byte is 0 and write when it's 1: 0x8071 fn 5 (software control), fn 7 (power-mode settings)
    // and fn 8 (power mode), per docs/lighting-control.md. The report calls them with 0 only.
    static let getOrSet: [Int: [Int]] = [0x8071: [5, 7, 8]]

    static func isRead(_ feature: Int, _ fn: Int, _ parameters: [UInt8]) -> Bool {
        if reads[feature]?.contains(fn) == true { return true }
        return getOrSet[feature]?.contains(fn) == true && parameters.first == 0
    }

    static let names: [Int: String] = [
        0x0001: "feature set", 0x0003: "firmware", 0x0005: "name", 0x0007: "friendly name", 0x0020: "config change", 0x1000: "battery",
        0x1001: "battery voltage", 0x1004: "battery", 0x1300: "LED control", 0x1814: "change host", 0x1815: "hosts info",
        0x1982: "backlight", 0x1990: "illumination", 0x1B04: "controls", 0x1D4B: "wireless status", 0x1F20: "battery and auto-off",
        0x2110: "SmartShift", 0x2111: "SmartShift", 0x2121: "scroll wheel", 0x2150: "thumb wheel", 0x2201: "DPI", 0x2202: "DPI, X and Y",
        0x8061: "report rate, to 8 kHz", 0x4540: "keyboard layout", 0x8010: "G keys", 0x8020: "M keys", 0x8030: "MR key",
        0x8040: "brightness", 0x8060: "report rate", 0x8070: "LED effects", 0x8071: "RGB effects", 0x8080: "per-key lighting",
        0x8081: "per-key lighting", 0x8100: "onboard profiles", 0x8101: "onboard files", 0x8110: "button spy", 0x8300: "sidetone",
        0x8310: "equalizer",
    ]

    static func name(_ id: Int) -> String { names[id] ?? "" }

    final class Reader {
        let device: Hidpp
        var output = ""
        var error: String?
        private var misses = 0

        init(_ device: Hidpp) { self.device = device }

        func line(_ text: String = "") { output += text + "\n" }

        func readOnlyCall(_ feature: Int, _ fn: Int, _ parameters: [UInt8] = []) -> [UInt8]? {
            guard Report.isRead(feature, fn, parameters) else {
                error = String(format: "not a known read: feature %04X fn %d", feature, fn)
                return nil
            }
            error = nil
            if misses >= 2 { error = "no answer"; return nil }
            do {
                let reply = try device.callUnlogged(try device.featureIndex(feature), fn, parameters)
                misses = 0
                return reply
            } catch GLiteError.hidpp(let code, _) { error = String(format: "error %02X", code) }
            catch GLiteError.notSupported { error = "missing" }
            catch GLiteError.timeout { misses += 1; error = "no answer" }
            catch { self.error = "\(error)" }
            return nil
        }

        @discardableResult
        func show(_ label: String, _ feature: Int, _ fn: Int, _ parameters: [UInt8] = []) -> [UInt8]? {
            let reply = readOnlyCall(feature, fn, parameters)
            line(label + "=" + (reply.map { Report.hex($0, " ") } ?? error ?? ""))
            return reply
        }
    }

    static func build(_ hidpp: Hidpp, _ found: FoundDevice, _ screen: String) -> String {
        let reader = Reader(hidpp)
        reader.output = header(found, screen) {
            found.battery >= 0 || !found.has(0x1F20)
                ? (found.battery < 0 ? "–" : "\(found.battery)%") + (found.millivolts > 0 ? ", \(found.millivolts) mV" : "")
                    + (found.charging ? ", charging" : "")
                : headsetBattery(reader)
        }
        for id in features(reader, found) where reads[id] != nil && id != 0x0001 {
            reader.line()
            reader.line(String(format: "%04X ", id) + name(id))
            section(reader, found, id)
        }
        return reader.output
    }

    static func registers(_ device: Hidpp, _ found: FoundDevice, _ screen: String) -> String {
        var text = header(found, screen) { "–" }
        text += "\nHID++ 1.0 registers\n"
        var misses = 0
        var register = 0
        while register < 0x100 && misses < 2 {
            for subId: UInt8 in [0x81, 0x83] {
                if let value = readRegister(device, subId, UInt8(register), &misses) {
                    text += (subId == 0x81 ? "short " : "long ") + String(format: "%02X", register) + "="
                        + hex(Array(value.prefix(subId == 0x81 ? 3 : 16)), " ") + "\n"
                }
            }
            register += 1
        }
        let current = readRegister(device, 0x81, 0x0F, &misses)
        guard misses < 2, let directory = try? G9xRegisters.readPage(device, 1) else { return text }
        var pageNumbers = [1]
        var entry = 0
        while entry + 2 < 510 && directory[entry] != 0xFF && pageNumbers.count < 17 {
            if directory[entry] >= 2 && directory[entry] < 32 { pageNumbers.append(Int(directory[entry])) }
            entry += 3
        }
        let currentPage = current.map { $0[0] == 0 && $0[1] < 16 ? G9xRegisters.entry(directory, Int($0[1])) : -1 } ?? -1
        for pageNumber in pageNumbers {
            guard let page = pageNumber == 1 ? directory : try? G9xRegisters.readPage(device, pageNumber) else { break }
            text += "\npage " + String(format: "%02X", pageNumber) + (G9xRegisters.valid(page) ? "" : ", bad checksum")
                + (pageNumber == currentPage ? ", current" : "") + "\n"
            for offset in stride(from: 0, to: 512, by: 16) {
                let row = Array(page[offset..<min(offset + 16, page.count)])
                if offset > 0 && offset < 496 && (row.allSatisfy { $0 == 0xFF } || row.allSatisfy { $0 == 0 }) { continue }
                text += String(format: "%03X", offset) + "=" + hex(row, " ") + "\n"
            }
        }
        return text
    }

    // A device that doesn't speak HID++ (app/Report.cs, PlainHidReport): its collection's report fields and its feature reports, read
    // with IOHIDDeviceGetReport. Windows lists every collection of the USB device; here it's the one the scan found.
    static func plainHid(_ found: FoundDevice, _ screen: String) -> String {
        var text = header(found, screen) { "–" }
        guard let port = found.port else { return text + "\nno device\n" }
        let device = port.device
        func property(_ key: String) -> Int { Port.int(device, key) }
        text += "\ncollection " + String(format: "usage=%04X:%04X input=%d output=%d feature=%d", property(kIOHIDPrimaryUsagePageKey),
                                          property(kIOHIDPrimaryUsageKey), property(kIOHIDMaxInputReportSizeKey),
                                          property(kIOHIDMaxOutputReportSizeKey), property(kIOHIDMaxFeatureReportSizeKey)) + "\n"
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        var featureIds = Set<Int>()
        for element in elements {
            let type = IOHIDElementGetType(element)
            let kind: String
            switch type {
            case kIOHIDElementTypeInput_Misc, kIOHIDElementTypeInput_Button, kIOHIDElementTypeInput_Axis, kIOHIDElementTypeInput_ScanCodes:
                kind = "input"
            case kIOHIDElementTypeOutput: kind = "output"
            case kIOHIDElementTypeFeature: kind = "feature"
            default: continue
            }
            let id = Int(IOHIDElementGetReportID(element))
            if kind == "feature" { featureIds.insert(id) }
            text += kind + String(format: " id=%02X page=%04X usage=%04X bits=%d count=%d logical=%d..%d", id, IOHIDElementGetUsagePage(element),
                                  IOHIDElementGetUsage(element), IOHIDElementGetReportSize(element), IOHIDElementGetReportCount(element),
                                  IOHIDElementGetLogicalMin(element), IOHIDElementGetLogicalMax(element)) + "\n"
        }
        if featureIds.isEmpty || property(kIOHIDMaxFeatureReportSizeKey) <= 0 { return text }
        let sorted = featureIds.sorted()
        text += "feature ids=" + sorted.map { String(format: "%02X", $0) }.joined(separator: " ") + "\n"
        for id in sorted {
            text += "feature " + String(format: "%02X", id) + "="
            do { text += hex(try port.getFeature(UInt8(id)), " ") + "\n" } catch { text += "\(error)\n" }
        }
        return text
    }

    private static func readRegister(_ device: Hidpp, _ subId: UInt8, _ register: UInt8, _ misses: inout Int) -> [UInt8]? {
        do { let value = try device.register(subId, register); misses = 0; return value }
        catch GLiteError.hidpp { misses = 0 }
        catch GLiteError.timeout { misses += 1 }
        catch { misses = 2 }
        return nil
    }

    private static func header(_ found: FoundDevice, _ screen: String, _ battery: () -> String) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        func row(_ name: String, _ value: String) -> String { name.padding(toLength: 10, withPad: " ", startingAt: 0) + value + "\n" }
        let slot = found.index == 0xFF || found.hidpp10 ? "" : ", slot \(found.index)"
        let usb = found.port.map { String(format: ", USB 046D:%04X", $0.productId) } ?? ""
        return "G-Lite device report\n" + "G-Lite " + version() + ", " + macOS() + "\n" + stamp.string(from: Date()) + "\n\n"
            + row("Device", found.name.isEmpty ? "–" : found.name) + row("Kind", found.kind)
            + row("Link", found.link + slot + (found.hidpp10 ? ", HID++ 1.0" : "")
                    + (found.wirelessId != 0 ? String(format: ", ID %04X", found.wirelessId) : "") + usb)
            + row("Model", found.models.isEmpty ? "–" : found.models) + row("Firmware", found.firmware.isEmpty ? "–" : found.firmware)
            + row("Battery", battery()) + row("Screen", screen)
    }

    private static func features(_ reader: Reader, _ found: FoundDevice) -> [Int] {
        var ids: [Int] = []
        reader.line()
        guard let count = reader.readOnlyCall(0x0001, 0) else {
            reader.line("Features (from the scan)")
            ids = found.features
            for id in ids { reader.line(String(format: "%04X  ", id) + name(id)) }
            return ids
        }
        reader.line("Features")
        for i in 1...max(1, Int(count[0])) where count[0] > 0 {
            guard let entry = reader.readOnlyCall(0x0001, 1, [UInt8(i)]) else { reader.line(String(format: "%02X ", i) + (reader.error ?? "")); continue }
            let id = Int(entry[0]) << 8 | Int(entry[1])
            ids.append(id)
            let flags = (entry[2] & 0x80 != 0 ? " obsolete" : "") + (entry[2] & 0x40 != 0 ? " hidden" : "") + (entry[2] & 0x20 != 0 ? " internal" : "")
            let version = "v\(entry[3])".padding(toLength: 3, withPad: " ", startingAt: 0)
            reader.line((String(format: "%02X %04X ", i, id) + version + " " + (name(id) + flags).trimmingCharacters(in: .whitespaces))
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        return ids
    }

    private static func section(_ reader: Reader, _ found: FoundDevice, _ id: Int) {
        switch id {
        case 0x0003:
            let count = reader.readOnlyCall(0x0003, 0)
            for entity in 0..<min(Int(count?[0] ?? 0), 8) {
                var info = reader.readOnlyCall(0x0003, 1, [UInt8(entity)])
                if info != nil { for i in 11..<info!.count { info![i] = 0 } }
                reader.line("entity \(entity)=" + (info.map { hex($0, " ") } ?? reader.error ?? ""))
            }
        case 0x1B04:
            let count = reader.show("count", 0x1B04, 0)
            for i in 0..<min(Int(count?[0] ?? 0), 48) { reader.show("control \(i)", 0x1B04, 1, [UInt8(i)]) }
        case 0x1990:
            reader.show("on", id, 0); reader.show("brightness info", id, 2); reader.show("brightness", id, 3)
            reader.show("temperature info", id, 7); reader.show("temperature", id, 8)
        case 0x1F20: reader.show("battery", id, 0); reader.show("auto-off", id, 1)
        case 0x2121: reader.show("wheel", id, 0); reader.show("mode", id, 1); reader.show("ratchet", id, 3)
        case 0x2110: reader.show("smartshift", id, 0)
        case 0x2111: reader.show("capabilities", id, 0); reader.show("smartshift", id, 1)
        case 0x2150: reader.show("info", id, 0); reader.show("status", id, 1)
        case 0x1982: reader.show("config", id, 0); reader.show("info", id, 2)
        case 0x1814: reader.show("hosts", id, 0)
        case 0x1815:
            // fn 1 gives each computer's status, bus and name length. Its name (fn 3) stays out: it's often the owner's name.
            let info = reader.show("info", id, 0)
            for host in 0..<min(Int(info?[2] ?? 0), 6) { reader.show("host \(host)", id, 1, [UInt8(host)]) }
        case 0x2201: reader.show("sensors", id, 0); reader.show("dpi list", id, 1, [0]); reader.show("dpi", id, 2, [0])
        case 0x2202:
            reader.show("sensors", id, 0); reader.show("sensor", id, 1, [0]); reader.show("dpi ranges", id, 2, [0, 0, 0])
            reader.show("dpi ranges, page 1", id, 2, [0, 0, 1]); reader.show("dpi list", id, 3, [0, 0]); reader.show("lift-off list", id, 4, [0])
            reader.show("dpi", id, 5, [0])
        case 0x8061:
            reader.show("rates, wired", id, 0, [0]); reader.show("rates, wireless", id, 0, [1]); reader.show("rates now", id, 1)
            reader.show("now, wired", id, 2, [0]); reader.show("now, wireless", id, 2, [1])
        case 0x4540: reader.show("layout", id, 0)
        case 0x8010, 0x8020: reader.show("count", id, 0)
        case 0x8040: reader.show("info", id, 0); reader.show("now", id, 1)
        case 0x8060: reader.show("rates", id, 0); reader.show("now", id, 1)
        case 0x8070:
            let info = reader.show("info", id, 0)
            for zoneIndex in 0..<min(Int(info?[0] ?? 0), 8) {
                let zone = reader.show("zone \(zoneIndex)", id, 1, [UInt8(zoneIndex), 0xFF, 0])
                for effect in 0..<min(Int(zone?[3] ?? 0), 32) {
                    reader.show("zone \(zoneIndex) effect \(effect)", id, 2, [UInt8(zoneIndex), UInt8(effect), 0xFF, 0])
                }
            }
        case 0x8071:
            for cluster in 0..<8 {
                if let place = reader.readOnlyCall(id, 0, [UInt8(cluster), 0xFF, 0]) { reader.line("cluster \(cluster)=" + hex(place, " ")) }
                var effects = 0
                for effect in 0..<32 {
                    guard let info = reader.readOnlyCall(id, 0, [UInt8(cluster), UInt8(effect), 0]) else { break }
                    reader.line("cluster \(cluster) effect \(effect)=" + hex(info, " "))
                    effects += 1
                }
                if effects == 0 { break }
            }
            reader.show("control", id, 5, [0, 0, 0]); reader.show("power settings", id, 7, [0, 0, 0]); reader.show("power mode", id, 8, [0, 0, 0])
        case 0x8081:
            var lit: [Int] = []
            for page in 0..<3 {
                guard let bits = reader.show("page \(page)", id, 0, [0, UInt8(page), 0]) else { continue }
                for i in 0..<14 { for bit in 0..<8 where bits[2 + i] >> bit & 1 != 0 { lit.append(page * 112 + i * 8 + bit) } }
            }
            reader.line("lit ids=" + lit.map { String(format: "%02X", $0) }.joined(separator: " "))
        case 0x8100: profiles(reader)
        case 0x8101:
            let user = file(reader, 0x0000, 16)
            if found.kind == "keyboard" { _ = file(reader, 0x0008, profileSize(user)) }
            let factory = file(reader, 0x0100, 16)
            if found.kind == "keyboard" { _ = file(reader, 0x0101, profileSize(factory)) }
        case 0x8110: reader.show("buttons", id, 0)
        case 0x8300: reader.show("sidetone", id, 0)
        case 0x8310:
            let info = reader.show("info", id, 0)
            for start in stride(from: 0, to: min(Int(info?[0] ?? 0), 32), by: 7) { reader.show("frequencies \(start)", id, 1, [UInt8(start)]) }
            reader.show("bands", id, 2)
        default: break
        }
    }

    private static func headsetBattery(_ reader: Reader) -> String {
        guard let reply = reader.readOnlyCall(0x1F20, 0) else { return "–" }
        let millivolts = Int(reply[0]) << 8 | Int(reply[1])
        return "~\(reply[2] == 3 ? FoundDevice.fromChargingVolts(millivolts) : FoundDevice.fromVolts(millivolts))%, \(millivolts) mV"
            + (reply[2] == 3 ? ", charging" : "")
    }

    private static func profiles(_ reader: Reader) {
        let info = reader.show("info", 0x8100, 0)
        reader.show("mode", 0x8100, 2)
        reader.show("current", 0x8100, 4)
        reader.show("dpi index", 0x8100, 0xB)
        guard let info = info else { return }
        let size = Int(info[7]) << 8 | Int(info[8])
        if size < 16 || size > 0x1000 { reader.line("sector size \(size), not read"); return }
        let directory = sector(reader, 0x0000, size)
        var sectors: [Int] = []
        var i = 0
        while let directory = directory, i + 1 < directory.count && sectors.count < 8 {
            let at = Int(directory[i]) << 8 | Int(directory[i + 1])
            if at == 0xFFFF { break }
            if at > 0 && at < 0x100 && !sectors.contains(at) { sectors.append(at) }
            i += 4
        }
        for at in sectors { _ = sector(reader, at, size) }
        _ = sector(reader, 0x0100, size)
        for profile in stride(from: 1, through: min(Int(info[4]), 8), by: 1) { _ = sector(reader, 0x0100 + profile, size) }
        otherSectors(reader, min(Int(info[6]), 32), sectors, size)
    }

    // Every other user sector, for the macros: a button entry 00 <sector> <offset> points to one, and a macro too long for a sector
    // goes on in another that no button points to (docs/G815-G915.md). Unused ones (all FF, or all 00) on one line.
    private static func otherSectors(_ reader: Reader, _ count: Int, _ read: [Int], _ size: Int) {
        var unused: [String] = [], unreadable: [String] = []
        for sector in stride(from: 1, to: count, by: 1) where !read.contains(sector) {
            switch readSector(reader, sector, size) {
            case .failure(let error): unreadable.append(String(format: "%04X (", sector) + error + ")")
            case .success(let data):
                if data.allSatisfy({ $0 == 0xFF }) || data.allSatisfy({ $0 == 0 }) { unused.append(String(format: "%04X", sector)) }
                else { reader.line(String(format: "%04X=", sector) + hex(data, "")) }
            }
        }
        if !unused.isEmpty { reader.line("unused=" + unused.joined(separator: " ")) }
        if !unreadable.isEmpty { reader.line("unreadable=" + unreadable.joined(separator: " ")) }
    }

    private enum SectorRead { case success([UInt8]), failure(String) }

    private static func sector(_ reader: Reader, _ sector: Int, _ size: Int) -> [UInt8]? {
        switch readSector(reader, sector, size) {
        case .success(let data): reader.line(String(format: "%04X=", sector) + hex(data, "")); return data
        case .failure(let error): reader.line(String(format: "%04X=", sector) + error); return nil
        }
    }

    private static func readSector(_ reader: Reader, _ sector: Int, _ size: Int) -> SectorRead {
        var data = [UInt8](repeating: 0, count: size)
        for offset in stride(from: 0, to: size, by: 16) {
            let at = min(offset, size - 16)
            guard let chunk = reader.readOnlyCall(0x8100, 5, [UInt8(sector >> 8 & 0xFF), UInt8(sector & 0xFF), UInt8(at >> 8 & 0xFF), UInt8(at & 0xFF)])
            else { return .failure(reader.error ?? "") }
            for i in 0..<min(16, size - offset) { data[offset + i] = chunk[offset - at + i] }
        }
        return .success(data)
    }

    private static func file(_ reader: Reader, _ address: Int, _ size: Int) -> [UInt8]? {
        if reader.readOnlyCall(0x8101, 8, [UInt8(address >> 8 & 0xFF), UInt8(address & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]) == nil {
            reader.line(String(format: "%04X=", address) + (reader.error ?? ""))
            return nil
        }
        var collected: [UInt8] = []
        for offset in stride(from: 0, to: size, by: 16) {
            guard let chunk = reader.readOnlyCall(0x8101, 0xC, [UInt8(offset >> 8 & 0xFF), UInt8(offset & 0xFF)]) else {
                reader.line(String(format: "%04X=", address) + (reader.error ?? ""))
                return nil
            }
            collected += chunk
        }
        let data = Array(collected.prefix(size))
        reader.line(String(format: "%04X=", address) + hex(data, ""))
        return data
    }

    private static func profileSize(_ directory: [UInt8]?) -> Int {
        guard let directory = directory, directory.count == 16, directory[5] == 0x01, directory[6] == 0x81, directory[7] == 0x01,
              directory[8] == 0x40 else { return 99 }
        return directory[9] >= 16 ? Int(directory[9]) : 99
    }

    static func hex(_ bytes: [UInt8], _ gap: String) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: gap) }

    static func version() -> String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    // "macOS 15.6, build 24G84", from "Version 15.6 (Build 24G84)".
    static func macOS() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        let text = ProcessInfo.processInfo.operatingSystemVersionString
        let build = text.range(of: "Build ").map { String(text[$0.upperBound...].prefix { $0 != ")" }) }
        return "macOS " + number + (build.map { ", build " + $0 } ?? "")
    }
}
