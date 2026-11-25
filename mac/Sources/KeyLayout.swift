import Foundation

// A keyboard's key map (app/KeyLayout.cs), from the same app/models/*.json files, which mac/build.sh copies into the app. A row is
// `Label:width|...` (or `Label:width:height`, `Label:width:height:lip` for an L), `_n` a gap of n units; `ids` has the 0x8081 lighting
// id of each key in hex, `--` for none, or with "kind": "zones" the 0x8070 zone of each key (the G213).
struct KeyLayout {
    var name: String
    var rows: [String]
    var ids: [String]
    // The ids are 0x8070 zones (the G213), not lighting ids.
    var zones = false
    // The keys drawn in their own shape instead of a key cap: Logo the G mark, Wheel the volume roller, others round buttons.
    var shaped: [String] = []

    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("models") }

    static func load(_ file: String) -> KeyLayout? {
        guard let url = folder?.appendingPathComponent(file), let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> KeyLayout? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let name = json["name"] as? String,
              let rows = json["rows"] as? [String] else { return nil }
        return KeyLayout(name: name, rows: rows, ids: json["ids"] as? [String] ?? [], zones: json["kind"] as? String == "zones",
                         shaped: json["shaped"] as? [String] ?? [])
    }

    // Whether a 0x4540 layout code has ISO's shape: 1 is ANSI, 2 and up ISO (Solaar), JIS included, whose Enter is ISO's L. 0, unknown,
    // stays ANSI.
    static func isIso(_ layoutCode: Int) -> Bool { layoutCode >= 2 }

    private static func keyIndex(_ row: [String], _ token: Int) -> Int { row.prefix(token).filter { !$0.hasPrefix("_") }.count }

    private static func number(_ value: Float) -> String {
        let format = NumberFormatter()
        format.maximumFractionDigits = 2
        format.minimumIntegerDigits = 1
        format.locale = Locale(identifier: "en_US_POSIX")
        return format.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // The ISO picture, built from the ANSI one: \ goes and Enter becomes an L from the Tab row (it keeps its id), the Caps row's Enter
    // becomes #, the left Shift shortens for <>, the right Alt is AltGr. # and <> are lighting ids 2F and 61, or on a layout of zones
    // the zone of the key they replace or sit by. Nil for a layout without these keys.
    func iso() -> KeyLayout? {
        var rows = self.rows.map { $0.components(separatedBy: "|") }
        var ids = (0..<self.rows.count).map { $0 < self.ids.count ? self.ids[$0].split(separator: " ").map(String.init) : [] }
        guard let tab = rows.firstIndex(where: { $0.contains("\\:1.5") }), let caps = rows.firstIndex(where: { $0.contains("Enter:2.25") }),
              let shift = rows.firstIndex(where: { $0.contains("Shift:2.25") }) else { return nil }
        let backslash = rows[tab].firstIndex(of: "\\:1.5")!, enter = rows[caps].firstIndex(of: "Enter:2.25")!
        let leftShift = rows[shift].firstIndex(of: "Shift:2.25")!
        let backslashKey = KeyLayout.keyIndex(rows[tab], backslash), enterKey = KeyLayout.keyIndex(rows[caps], enter)
        let shiftKey = KeyLayout.keyIndex(rows[shift], leftShift)
        let enterId = enterKey < ids[caps].count ? ids[caps][enterKey] : "--"

        rows[tab][backslash] = "Enter:1.25:2:.25"
        rows[tab].insert("_.25", at: backslash)
        if backslashKey < ids[tab].count { ids[tab][backslashKey] = enterId }

        rows[caps][enter] = "#"
        if enter + 1 < rows[caps].count && rows[caps][enter + 1].hasPrefix("_") {
            rows[caps][enter + 1] = "_" + KeyLayout.number((Float(rows[caps][enter + 1].dropFirst()) ?? 0) + 1.25)
        } else if enter + 1 < rows[caps].count {
            rows[caps].insert("_1.25", at: enter + 1)
        }
        if !zones && enterKey < ids[caps].count { ids[caps][enterKey] = "2F" }

        rows[shift][leftShift] = "Shift:1.25"
        rows[shift].insert("<>", at: leftShift + 1)
        if shiftKey < ids[shift].count { ids[shift].insert(zones ? ids[shift][shiftKey] : "61", at: shiftKey + 1) }

        for r in 0..<rows.count {
            let alts = rows[r].indices.filter { rows[r][$0].components(separatedBy: ":")[0] == "Alt" }
            if alts.count == 2 { rows[r][alts[1]] = "AltGr" + rows[r][alts[1]].dropFirst(3) }
        }
        return KeyLayout(name: name, rows: rows.map { $0.joined(separator: "|") }, ids: self.ids.isEmpty ? [] : ids.map { $0.joined(separator: " ") },
                         zones: zones, shaped: shaped)
    }

    // Each key's id, in reading order, -1 for a key with no known LED.
    func keyIds() -> [Int] {
        var all: [Int] = []
        for (r, row) in rows.enumerated() {
            let rowIds = r < ids.count ? ids[r].split(separator: " ").map(String.init) : []
            var keyIndex = 0
            for cell in row.components(separatedBy: "|") where !cell.hasPrefix("_") {
                all.append(keyIndex < rowIds.count && rowIds[keyIndex] != "--" ? Int(rowIds[keyIndex], radix: 16) ?? -1 : -1)
                keyIndex += 1
            }
        }
        return all
    }

    func keyNames() -> [String] {
        rows.flatMap { $0.components(separatedBy: "|") }.filter { !$0.hasPrefix("_") }.map { $0.components(separatedBy: ":")[0] }
    }

    // The picture a live keyboard gets from its name (app/KeyboardKinds.cs, File and For): the G915 family and the G512 X 75 their own,
    // others one picked by size. A borrowed G515 picture loses its top strip, a borrowed G512 X 75 one its knobs.
    static func forKeyboard(_ device: FoundDevice) -> KeyLayout? {
        let upper = device.name.uppercased(), small = upper.contains("TKL")
        let own = device.isG915 ? (upper.contains("G815") ? "g815.json" : small ? "g915-tkl.json" : "g915.json")
            : upper.contains("G512 X 75") ? "g512-x-75.json" : nil
        if let own = own { return load(own) }
        let file = upper.contains("G915 X") ? (small ? "g915-x-tkl.json" : "g915-x.json") : upper.contains(" 60") ? "g-60.json"
            : upper.contains(" 75") ? "g512-x-75.json" : upper.contains(" 98") ? "g-full.json" : "g515-tkl.json"
        guard var layout = load(file) else { return nil }
        layout.name = device.shortName
        if file == "g515-tkl.json" {
            layout.rows = Array(layout.rows.dropFirst(2))
            layout.ids = Array(layout.ids.dropFirst(2))
        }
        if file == "g512-x-75.json" {
            layout.rows = Array(layout.rows.prefix(7))
            layout.ids = Array(layout.ids.prefix(7))
            if let knob = layout.rows[0].range(of: "|_.4|Knob") { layout.rows[0] = String(layout.rows[0][..<knob.lowerBound]) }
            layout.ids[0] = layout.ids[0].replacingOccurrences(of: " -- --", with: "")
        }
        if file == "g515-tkl.json" || file == "g512-x-75.json" { layout.shaped = [] }
        return layout
    }

    // The zones keyboards' pictures (app/ZoneLighting.cs, Picture): the G213's ids are zones; the G512 and G513 have the G413's layout.
    static func forZones(_ device: FoundDevice) -> KeyLayout? {
        guard device.kind == "keyboard" else { return nil }
        let name = device.shortName.uppercased()
        return name == "G213" ? load("g213.json") : name.hasPrefix("G413") || name.hasPrefix("G512") || name.hasPrefix("G513") ? load("g413.json") : nil
    }
}
