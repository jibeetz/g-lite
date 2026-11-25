import Foundation
import IOKit.hid

enum GLiteError: Error, CustomStringConvertible {
    case hidpp(Int, String)
    case timeout(String)
    case notSupported(String)
    case refused(String)
    // A refusal that a backup can repair (the profile doesn't match its directory).
    case halfWritten(String)
    case io(String)
    case notPermitted(String)

    var description: String {
        switch self {
        case .hidpp(_, let text), .timeout(let text), .notSupported(let text), .refused(let text), .halfWritten(let text),
             .io(let text), .notPermitted(let text):
            return text
        }
    }
    var code: Int { if case .hidpp(let code, _) = self { return code }; return -1 }
    var isRefusal: Bool {
        switch self { case .refused, .halfWritten: return true; default: return false }
    }
}

// The run loop every device's input reports arrive on.
final class HidThread {
    static let shared = HidThread()
    private(set) var runLoop: CFRunLoop!

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext()
            CFRunLoopAddSource(self.runLoop, CFRunLoopSourceCreate(nil, 0, &context), .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "HID"
        thread.start()
        ready.wait()
    }

    func sync<T>(_ work: @escaping () -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { result = work(); done.signal() }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        return result!
    }
}

// What one reader has heard on a port. On Windows each open handle gets its own copy of every input report; a port fans its reports
// out to its readers the same way, so a scan, a screen and the watcher don't take each other's replies.
final class Reader {
    private let condition = NSCondition()
    private var reports: [[UInt8]] = []
    var heard: (([UInt8]) -> Void)?

    func put(_ report: [UInt8]) {
        if let heard = heard { heard(report); return }
        condition.lock()
        reports.append(report)
        if reports.count > 256 { reports.removeFirst() }
        condition.signal()
        condition.unlock()
    }

    // The next report, padded to 20 bytes, or nil at the deadline.
    func next(until deadline: Date) -> [UInt8]? {
        condition.lock(); defer { condition.unlock() }
        while reports.isEmpty { if !condition.wait(until: deadline) { return nil } }
        var report = reports.removeFirst()
        if report.count < 20 { report += [UInt8](repeating: 0, count: 20 - report.count) }
        return report
    }

    func drain() { condition.lock(); reports.removeAll(); condition.unlock() }
}

// One IOHIDDevice. On macOS a receiver's HID++ interface is one device with both vendor collections (FF00 usage 1, the 7-byte short
// reports, and usage 2, the 20-byte long ones), so both go through it.
final class Port {
    let device: IOHIDDevice
    let id: UInt64
    let productId: Int
    let product: String
    let transport: String
    let hasShort: Bool
    private var readers: [Reader] = []
    private let gate = NSLock()
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var opened = false

    init(device: IOHIDDevice, hasShort: Bool) {
        self.device = device
        self.hasShort = hasShort
        var entry: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entry)
        id = entry
        productId = Port.int(device, kIOHIDProductIDKey)
        product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
    }

    static func int(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    func open() throws {
        gate.lock(); defer { gate.unlock() }
        if opened { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            if result == kIOReturnNotPermitted {
                throw GLiteError.notPermitted("macOS refused to open the device: allow G-Lite in Privacy & Security, Input Monitoring")
            }
            throw GLiteError.io(String(format: "Can't open the device (error 0x%08x)", result))
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        HidThread.shared.sync {
            IOHIDDeviceRegisterInputReportCallback(self.device, self.buffer, 64, { context, _, _, _, _, report, length in
                guard let context = context else { return }
                let port = Unmanaged<Port>.fromOpaque(context).takeUnretainedValue()
                port.deliver(Array(UnsafeBufferPointer(start: report, count: length)))
            }, context)
            IOHIDDeviceScheduleWithRunLoop(self.device, HidThread.shared.runLoop, CFRunLoopMode.defaultMode.rawValue)
        }
        opened = true
    }

    private func deliver(_ report: [UInt8]) {
        guard report.count >= 7, report[0] == 0x10 || report[0] == 0x11 else { return }
        gate.lock(); let all = readers; gate.unlock()
        for reader in all { reader.put(report) }
    }

    func reader() throws -> Reader {
        try open()
        let reader = Reader()
        gate.lock(); readers.append(reader); gate.unlock()
        return reader
    }

    func remove(_ reader: Reader) {
        gate.lock(); readers.removeAll { $0 === reader }; gate.unlock()
    }

    // Feature reports, for the devices that don't speak HID++ (the G510): the first byte is the report id.
    var featureLength: Int { max(1, Port.int(device, kIOHIDMaxFeatureReportSizeKey)) }

    func getFeature(_ id: UInt8) throws -> [UInt8] {
        try open()
        var buffer = [UInt8](repeating: 0, count: featureLength)
        buffer[0] = id
        var length = buffer.count
        let result = buffer.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), $0.baseAddress!, &length)
        }
        if result != kIOReturnSuccess { throw GLiteError.io(String(format: "Couldn't read feature report %02X (0x%08x)", id, result)) }
        return Array(buffer.prefix(length))
    }

    func setFeature(_ report: [UInt8]) throws {
        try open()
        let padded = report + [UInt8](repeating: 0, count: max(0, featureLength - report.count))
        let result = padded.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(report[0]), $0.baseAddress!, padded.count)
        }
        if result != kIOReturnSuccess { throw GLiteError.io(String(format: "Couldn't set feature report %02X (0x%08x)", report[0], result)) }
    }

    // The first byte is the report id: 0x10 short, 0x11 long.
    func write(_ report: [UInt8]) throws {
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), $0.baseAddress!, report.count)
        }
        if result != kIOReturnSuccess {
            throw GLiteError.io(String(format: "The device stopped answering. Was it unplugged? (0x%08x)", result))
        }
    }
}

// HID++ 2.0 calls on one device index, and HID++ 1.0 registers (app/Hidpp.cs).
class Hidpp {
    let port: Port?
    private let reader: Reader?
    let deviceIndex: UInt8
    var direct: Bool { deviceIndex == 0xFF }
    var deviceLabel: String?
    private var features: [Int: UInt8] = [:]
    private var hiddenFeatures = Set<Int>()
    private var calls = Int.random(in: 0..<12)
    private let gate = NSLock()
    // Every call made, for tests.
    static var tap: ((String) -> Void)?

    init(port: Port, index: UInt8) throws {
        self.port = port
        reader = try port.reader()
        deviceIndex = index
    }

    // For the fake devices.
    init(fake index: UInt8) { port = nil; reader = nil; deviceIndex = index }

    deinit { if let reader = reader { port?.remove(reader) } }

    func featureIndex(_ id: Int) throws -> UInt8 {
        gate.lock(); let known = features[id]; gate.unlock()
        let index: UInt8
        if let known = known { index = known } else {
            let reply = try call(0, 0, [UInt8(id >> 8), UInt8(id & 0xFF)])
            index = reply[0]
            gate.lock(); features[id] = index; if reply[1] & 0x60 == 0x60 { hiddenFeatures.insert(id) }; gate.unlock()
        }
        if index == 0 { throw GLiteError.notSupported(String(format: "The device lacks feature %04x", id)) }
        return index
    }

    // Flagged hidden and internal by the device (root fn 0, byte 1 bits 6 and 5): meant for Logitech's own tools. Hidden alone isn't
    // enough, since a feature that works can carry it. Known after featureIndex.
    func hidden(_ id: Int) -> Bool { gate.lock(); defer { gate.unlock() }; return hiddenFeatures.contains(id) }

    private func featureId(_ index: UInt8) -> Int {
        gate.lock(); defer { gate.unlock() }
        return features.first { $0.value == index }?.key ?? 0
    }

    @discardableResult
    func call(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8] = []) throws -> [UInt8] {
        record(featureIndex, fn, parameters)
        guard let label = deviceLabel, featureIndex != 0 else { return try sendRetryingBusy(featureIndex, fn, parameters) }
        let id = featureId(featureIndex)
        let read = Log.isRead(id, fn)
        do {
            let reply = try sendRetryingBusy(featureIndex, fn, parameters)
            if !read { Log.sent(label, id, fn, parameters, "ok") }
            return reply
        } catch let error as GLiteError {
            if case .hidpp(let code, _) = error { Log.sent(label, id, fn, parameters, String(format: "error %02X", code)) }
            if case .timeout = error { Log.sent(label, id, fn, parameters, "no answer") }
            throw error
        }
    }

    // For animation frames: tapped for tests but kept out of the log.
    @discardableResult
    func callUnlogged(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8] = []) throws -> [UInt8] {
        record(featureIndex, fn, parameters)
        return try send(featureIndex, fn, parameters)
    }

    // Posted, no reply read, kept out of the log: 0x8080's colours (app/Hidpp.cs, PostUnlogged).
    func postUnlogged(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws {
        record(featureIndex, fn, parameters)
        try write(featureIndex, fn, parameters)
    }

    // Error 8, busy, is tried again after 30, 60 and 90 ms, as Solaar does (app/Hidpp.cs).
    private func sendRetryingBusy(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        var attempt = 1
        while true {
            do { return try send(featureIndex, fn, parameters) } catch let error as GLiteError {
                if error.code != 8 || attempt > 3 { throw error }
                Thread.sleep(forTimeInterval: 0.03 * Double(attempt))
                attempt += 1
            }
        }
    }

    private func record(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) {
        guard let tap = Hidpp.tap, featureIndex != 0 else { return }
        let id = featureId(featureIndex)
        var used = Array(parameters.prefix(16))
        while let last = used.last, last == 0 { used.removeLast() }
        tap((id != 0 ? String(format: "%04X", id) : String(format: "index %02X", featureIndex)) + String(format: " fn%X", fn)
            + (used.isEmpty ? "" : "  " + Log.hex(used, spaced: true)))
    }

    // HID++ 1.0 registers (app/Hidpp.cs, Register): short reports `10 <idx> <sub> <register> p0 p1 p2`, 0x81 reads and 0x80 sets a
    // short register, 0x83 reads and 0x82 sets a long one, 0x8F is an error. Sets are logged.
    @discardableResult
    func register(_ subId: UInt8, _ register: UInt8, _ parameters: [UInt8] = []) throws -> [UInt8] {
        let isSet = subId == 0x80 || subId == 0x82
        let text = String(format: "register %02X", register) + (parameters.isEmpty ? "" : "  " + Log.hex(parameters, spaced: true))
        Hidpp.tap?(String(format: "register %02X %02X", subId, register) + (parameters.isEmpty ? "" : "  " + Log.hex(parameters, spaced: true)))
        do {
            let reply = try sendRegister(subId, register, parameters)
            if isSet, let label = deviceLabel { Log.add(label, "sent", text, "ok") }
            return reply
        } catch let error as GLiteError {
            if let label = deviceLabel {
                if case .hidpp(let code, _) = error, isSet { Log.add(label, "sent", text, String(format: "error %02X", code)) }
                if case .timeout = error { Log.add(label, "sent", text, "no answer") }
            }
            throw error
        }
    }

    func sendRegister(_ subId: UInt8, _ register: UInt8, _ parameters: [UInt8]) throws -> [UInt8] {
        guard let port = port, let reader = reader, port.hasShort else { throw GLiteError.notSupported("The device has no HID++ 1.0 channel") }
        let isLong = subId == 0x82
        var message = [UInt8](repeating: 0, count: isLong ? 20 : 7)
        message[0] = isLong ? 0x11 : 0x10; message[1] = deviceIndex; message[2] = subId; message[3] = register
        for (i, value) in parameters.prefix(message.count - 4).enumerated() { message[4 + i] = value }
        try port.write(message)
        let deadline = Date().addingTimeInterval(3)
        while true {
            guard let reply = reader.next(until: deadline) else { throw GLiteError.timeout("The device didn't answer. Is it on?") }
            if reply[1] != deviceIndex { continue }
            if reply[2] == 0x8F && reply[3] == subId && reply[4] == register {
                throw GLiteError.hidpp(Int(reply[5]), String(format: "HID++ 1.0 error 0x%02x (register %02x)", reply[5], register))
            }
            if reply[2] == subId && reply[3] == register { return Array(reply[4...]) }
        }
    }

    // A memory upload's packets (0x92 first, then 0x93), each acked by 0x50 (app/Hidpp.cs, Upload).
    func upload(_ subId: UInt8, _ sequence: UInt8, _ data: [UInt8]) throws {
        Hidpp.tap?(String(format: "upload %02X %02X  ", subId, sequence) + Log.hex(data, spaced: true))
        let text = String(format: "upload %02X  %02X", subId, sequence)
        do {
            try sendUpload(subId, sequence, data)
            if let label = deviceLabel { Log.add(label, "sent", text, "ok") }
        } catch {
            if let label = deviceLabel { Log.add(label, "sent", text, "\(error)") }
            throw error
        }
    }

    func sendUpload(_ subId: UInt8, _ sequence: UInt8, _ data: [UInt8]) throws {
        guard let port = port, let reader = reader, port.hasShort else { throw GLiteError.notSupported("The device has no HID++ 1.0 channel") }
        var message = [UInt8](repeating: 0, count: 20)
        message[0] = 0x11; message[1] = deviceIndex; message[2] = subId; message[3] = sequence
        for (i, value) in data.prefix(16).enumerated() { message[4 + i] = value }
        try port.write(message)
        let deadline = Date().addingTimeInterval(3)
        while true {
            guard let reply = reader.next(until: deadline) else { throw GLiteError.timeout("The mouse didn't take the upload") }
            if reply[1] != deviceIndex { continue }
            if reply[2] == 0x8F && reply[3] == subId { throw GLiteError.hidpp(Int(reply[5]), String(format: "HID++ 1.0 error 0x%02x (upload)", reply[5])) }
            if reply[2] != 0x50 { continue }
            // An error ack doesn't repeat the sequence number (cvuchener's g500 doc/hidpp10.md: byte 4 "if there was no error").
            if reply[3] != 0x01 { throw GLiteError.hidpp(Int(reply[3]), String(format: "The mouse refused the upload (0x%02x)", reply[3])) }
            if reply[4] != sequence { continue }
            return
        }
    }

    // Feature reports, for the devices that don't speak HID++ (app/Hidpp.cs, GetFeature and SetFeature).
    func getFeature(_ id: UInt8) throws -> [UInt8] {
        Hidpp.tap?(String(format: "get feature %02X", id))
        return try readFeature(id)
    }

    func setFeature(_ report: [UInt8], quiet: Bool = false) throws {
        Hidpp.tap?("set feature  " + Log.hex(report, spaced: true))
        do {
            try writeFeature(report)
            if !quiet, let label = deviceLabel { Log.add(label, "sent", "feature  " + Log.hex(report, spaced: true), "ok") }
        } catch {
            if let label = deviceLabel { Log.add(label, "sent", "feature  " + Log.hex(report, spaced: true), "error") }
            throw error
        }
    }

    func readFeature(_ id: UInt8) throws -> [UInt8] {
        guard let port = port else { throw GLiteError.io("No device") }
        return try port.getFeature(id)
    }

    func writeFeature(_ report: [UInt8]) throws {
        guard let port = port else { throw GLiteError.io("No device") }
        try port.setFeature(report)
    }

    // For a call the device doesn't answer, like 0x1814 fn 1: it switches to another computer first.
    func sendWithoutReply(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws {
        record(featureIndex, fn, parameters)
        try write(featureIndex, fn, parameters)
        if let label = deviceLabel { Log.sent(label, featureId(featureIndex), fn, parameters, "sent") }
    }

    @discardableResult
    func write(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        guard let port = port else { throw GLiteError.io("No device") }
        gate.lock(); calls += 1; let swid = UInt8(1 + calls % 12); gate.unlock()
        var message = [UInt8](repeating: 0, count: 20)
        message[0] = 0x11; message[1] = deviceIndex; message[2] = featureIndex; message[3] = UInt8(fn << 4) | swid
        for (i, value) in parameters.prefix(16).enumerated() { message[4 + i] = value }
        try port.write(message)
        return message
    }

    func send(_ featureIndex: UInt8, _ fn: Int, _ parameters: [UInt8]) throws -> [UInt8] {
        guard let reader = reader else { throw GLiteError.io("No device") }
        let message = try write(featureIndex, fn, parameters)
        let deadline = Date().addingTimeInterval(3)
        while true {
            guard let reply = reader.next(until: deadline) else { throw GLiteError.timeout("The device didn't answer. Is it on?") }
            // Over Bluetooth a device may answer a request to 0xFF at index 0x00 (app/Hidpp.cs).
            if reply[1] != deviceIndex && !(direct && reply[1] == 0) { continue }
            if reply[2] == 0xFF && reply[3] == featureIndex && reply[4] == message[3] {
                throw GLiteError.hidpp(Int(reply[5]), String(format: "HID++ error 0x%02x (feature %d, fn %d)", reply[5], featureIndex, fn))
            }
            if reply[2] == featureIndex && reply[3] == message[3] { return Array(reply[4...]) }
        }
    }
}
