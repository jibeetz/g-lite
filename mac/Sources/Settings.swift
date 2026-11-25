import Foundation

// settings.txt with key=value lines, the same keys as on Windows (app/Settings.cs).
enum Settings {
    static let defaults = ["check-updates=1", "auto-update=0", "skip-version=", "tray-tip-shown=0", "theme=system"]
    static var folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GLite")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var location: URL { folder.appendingPathComponent("settings.txt") }
    private static let gate = NSLock()

    private static func read() -> [(String, String)] {
        let text = (try? String(contentsOf: location, encoding: .utf8)) ?? ""
        var pairs: [(String, String)] = []
        for line in defaults + text.components(separatedBy: .newlines) {
            guard let at = line.firstIndex(of: "="), at != line.startIndex else { continue }
            let key = line[..<at].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: at)...].trimmingCharacters(in: .whitespaces)
            if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = value } else { pairs.append((key, value)) }
        }
        return pairs
    }

    private static func write(_ pairs: [(String, String)]) {
        try? pairs.map { $0.0 + "=" + $0.1 }.joined(separator: "\n").appending("\n")
            .write(to: location, atomically: true, encoding: .utf8)
    }

    static func get(_ key: String) -> String {
        gate.lock(); defer { gate.unlock() }
        return read().first { $0.0 == key }?.1 ?? ""
    }

    static func set(_ key: String, _ value: String) {
        gate.lock(); defer { gate.unlock() }
        var pairs = read()
        if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = value } else { pairs.append((key, value)) }
        write(pairs)
    }

    static func keys() -> [String] {
        gate.lock(); defer { gate.unlock() }
        return read().map { $0.0 }
    }

    static func remove(_ key: String) {
        gate.lock(); defer { gate.unlock() }
        var pairs = read()
        pairs.removeAll { $0.0 == key }
        write(pairs)
    }
}
