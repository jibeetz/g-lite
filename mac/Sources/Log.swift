import Foundation

// log.txt next to settings.txt, in the Windows format (app/Log.cs): time, device, kind, text, result, tab-separated.
enum Log {
    // In the temp folder with --demo, as on Windows.
    static var folder = Settings.folder
    static var file: URL { folder.appendingPathComponent("log.txt") }
    static var old: URL { folder.appendingPathComponent("log.old.txt") }
    private static let gate = NSLock()
    private static let max = 512 * 1024
    private static let stamp: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format
    }()

    // The functions known to only read (app/Report.cs, Report.Reads): their calls aren't logged.
    static let reads: [Int: Set<Int>] = [
        0x0001: [0, 1], 0x0003: [0, 1], 0x1990: [0, 2, 3, 7, 8], 0x1814: [0], 0x1815: [0, 1], 0x1982: [0, 2],
        0x1B04: [0, 1], 0x1F20: [0, 1], 0x2110: [0], 0x2111: [0, 1], 0x2121: [0, 1, 3], 0x2150: [0, 1],
        0x2201: [0, 1, 2], 0x2202: [0, 1, 2, 3, 4, 5], 0x4540: [0], 0x8010: [0], 0x8020: [0], 0x8040: [0, 1],
        0x8060: [0, 1], 0x8061: [0, 1, 2], 0x8070: [0, 1, 2], 0x8071: [0], 0x8081: [0], 0x8100: [0, 2, 4, 5, 0xB],
        0x8110: [0], 0x8101: [8, 0xC], 0x8300: [0], 0x8310: [0, 1, 2],
    ]

    static func isRead(_ id: Int, _ fn: Int) -> Bool { reads[id]?.contains(fn) ?? false }

    static func add(_ who: String, _ kind: String, _ text: String, _ result: String = "") {
        let line = [stamp.string(from: Date()), oneLine(who), kind, oneLine(text), result].joined(separator: "\t") + "\n"
        gate.lock(); defer { gate.unlock() }
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size > max {
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: file, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
        } else {
            try? data.write(to: file)
        }
    }

    static func sent(_ who: String, _ id: Int, _ fn: Int, _ parameters: [UInt8], _ result: String) {
        add(who, "sent", String(format: "%04X fn%X", id, fn) + (parameters.isEmpty ? "" : "  " + hex(parameters, spaced: true)), result)
    }

    static func hex(_ bytes: [UInt8], spaced: Bool = false) -> String {
        bytes.map { String(format: spaced ? "%02X" : "%02x", $0) }.joined(separator: spaced ? " " : "")
    }

    struct Line { var time, who, kind, text, result: String; var times = 1 }

    static func size() -> Int { (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0 }

    static func read() -> [Line] {
        gate.lock(); let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""; gate.unlock()
        return text.components(separatedBy: .newlines).compactMap { row in
            let columns = row.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\t")
            return columns.count == 5 ? Line(time: columns[0], who: columns[1], kind: columns[2], text: columns[3], result: columns[4]) : nil
        }
    }

    static func clear() {
        gate.lock(); defer { gate.unlock() }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: old)
    }

    // Sends of the same call in a row show as one line with a count (app/Log.cs).
    static func mergeRepeatedSends(_ lines: [Line]) -> [Line] {
        var merged: [Line] = []
        for line in lines {
            if let last = merged.last, line.kind == "sent", last.kind == "sent", last.who == line.who, last.result == line.result,
               firstWord(last.text) == firstWord(line.text) {
                merged[merged.count - 1].times += 1
                continue
            }
            merged.append(line)
        }
        return merged
    }

    private static func firstWord(_ text: String) -> String { text.components(separatedBy: "  ")[0] }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func format(_ line: Line) -> String {
        let who = line.who.count > 14 ? String(line.who.prefix(13)) + "…" : line.who
        var text = line.text
        if line.kind == "sent" {
            let call = firstWord(line.text)
            text = pad(call, 10) + pad(line.result + (line.times > 1 ? " ×\(line.times)" : ""), 12)
                + String(line.text.dropFirst(call.count)).trimmingCharacters(in: .whitespaces)
        }
        return (line.time + "  " + pad(who, 15) + pad(line.kind, 8) + text).trimmingCharacters(in: .whitespaces)
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
