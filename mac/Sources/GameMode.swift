import AppKit
import Carbon

// The keys the Game mode key turns off (app/GameMode.cs), through 0x4522 (disable keys by usage; docs/G815-G915.md, tried on the
// G815): fn 3 clears the list, fn 1 adds USB keyboard usages, 16 per call, ended by 00. The firmware turns off the Windows and Menu keys
// itself, and the list only applies while Game mode is on. Or through 0x4523 (the G515, the G915 X), a bitmap of the keyboard's control
// list (0x1B10). The keyboard keeps the list until it loses power, so G-Lite sends it again at each load.
enum GameModeKeys {
    static let alwaysOff = [0xE3, 0xE7, 0x65]

    // controlBitmap: a 0x4523 keyboard, whose list holds any key with a control, Windows and Menu too: the G515 leaves them on in
    // Game mode (tried).
    static func canPick(_ usage: Int, _ controlBitmap: Bool) -> Bool {
        if controlBitmap { return controlUsages.values.contains(usage) && KeyPresses.lightingId(usage) >= 0 }
        return usage >= 0 && KeyPresses.lightingId(usage) >= 0 && !alwaysOff.contains(usage)
    }

    static func clean(_ usages: [Int], _ controlBitmap: Bool) -> [Int] {
        Array(Set(usages.filter { canPick($0, controlBitmap) })).sorted()
    }

    // controls: the keyboard's control list, read once per connection (Controls) and kept by the caller.
    static func send(_ hidpp: Hidpp, _ usages: [Int], _ controlBitmap: Bool, controls: inout [Int]?) throws {
        if controlBitmap {
            if controls == nil { controls = try readControls(hidpp) }
            try hidpp.call(try hidpp.featureIndex(0x4523), 0, bitmap(controls!, usages))
            return
        }
        let feature = try hidpp.featureIndex(0x4522)
        try hidpp.call(feature, 3)
        for packet in packets(usages) { try hidpp.call(feature, 1, packet) }
    }

    // 0x4523 fn 0 takes a bitmap of the keyboard's control list (0x1B10), bit i for control i from the first byte's low bit: tried on a
    // G515 TKL, where byte 7 turned off A, D, G, J, L, à, Enter and End, controls 0x38-0x3F. 0x1B10 fn 0 counts the controls (128), fn 1
    // gives eight ids (big endian) from an index. Some ids are Solaar's (F1 0x00F6, F2-F8 0x00EF-0x00F5, Tab 0x010C, Home 0x0118); the
    // others are placed from where they sit in the G515's list, which follows the key matrix. Ids where JIS keyboards have their extra
    // keys (0x017C, 0x017E, 0x017F, 0x0180) aren't listed, so those stay on.
    static let controlUsages: [Int: Int] = {
        var usages: [Int: Int] = [:]
        for letter in 0..<26 { usages[0x0122 + letter] = 0x04 + letter }
        for digit in 1...9 { usages[0x0142 + digit] = 0x1D + digit }
        usages[0x0142] = 0x27
        usages[0x00F6] = 0x3A
        for key in 0..<7 { usages[0x00EF + key] = 0x3B + key }
        for key in 0..<4 { usages[0x014D + key] = 0x42 + key }
        let pairs = [
            0x0155, 0x28, 0x014C, 0x29, 0x0156, 0x2A, 0x010C, 0x2B, 0x0161, 0x2C, 0x0158, 0x2D, 0x0153, 0x2E, 0x015A, 0x2F,
            0x015B, 0x30, 0x011E, 0x31, 0x0169, 0x32, 0x015C, 0x33, 0x015D, 0x34, 0x010B, 0x35, 0x0160, 0x36, 0x015F, 0x37,
            0x015E, 0x38, 0x010D, 0x39, 0x004C, 0x46, 0x004E, 0x47, 0x004D, 0x48, 0x0116, 0x49, 0x0118, 0x4A, 0x011A, 0x4B,
            0x0117, 0x4C, 0x0119, 0x4D, 0x011B, 0x4E, 0x00EB, 0x4F, 0x00EC, 0x50, 0x0151, 0x51, 0x0152, 0x52, 0x016A, 0x64,
            0x004F, 0x65, 0x010F, 0xE0, 0x010E, 0xE1, 0x018B, 0xE2, 0x018C, 0xE3, 0x0114, 0xE4, 0x0115, 0xE5, 0x018D, 0xE6,
        ]
        for at in stride(from: 0, to: pairs.count, by: 2) { usages[pairs[at]] = pairs[at + 1] }
        return usages
    }()

    static func bitmap(_ controls: [Int], _ usages: [Int]) -> [UInt8] {
        var bitmap = [UInt8](repeating: 0, count: 16)
        for (index, control) in controls.prefix(128).enumerated() {
            if let usage = controlUsages[control], usages.contains(usage) { bitmap[index / 8] |= UInt8(1 << (index % 8)) }
        }
        return bitmap
    }

    static func readControls(_ hidpp: Hidpp) throws -> [Int] {
        let feature = try hidpp.featureIndex(0x1B10)
        let count = min(Int(try hidpp.call(feature, 0)[0]), 128)
        var controls = [Int](repeating: 0, count: count)
        for at in stride(from: 0, to: count, by: 8) {
            let reply = try hidpp.call(feature, 1, [UInt8(at)])
            for i in 0..<8 where at + i < count { controls[at + i] = Int(reply[i * 2]) << 8 | Int(reply[i * 2 + 1]) }
        }
        return controls
    }

    // A full packet has no 00 at its end: the keyboard takes 16 usages as the whole packet (OpenLogi).
    static func packets(_ usages: [Int]) -> [[UInt8]] {
        stride(from: 0, to: usages.count, by: 16).map { at in
            var packet = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 where at + i < usages.count { packet[i] = UInt8(usages[at + i]) }
            return packet
        }
    }

    static func toText(_ usages: [Int]) -> String { usages.map { String(format: "%02X", $0) }.joined() }

    static func fromText(_ text: String, _ controlBitmap: Bool) -> [Int] {
        let characters = Array(text)
        let usages = stride(from: 0, to: characters.count - 1, by: 2).compactMap { Int(String(characters[$0...$0 + 1]), radix: 16) }
        return clean(usages, controlBitmap)
    }

    // A preset ends in "!" and the usages in hex when it holds Game mode keys ("!" alone for none); one saved before has no "!" and
    // leaves the keys as they are (nil). The last "!" counts, since a Screen zone's name may hold one.
    static func split(_ preset: String) -> (preset: String, keys: String?) {
        guard let bang = preset.lastIndex(of: "!") else { return (preset, nil) }
        let tail = String(preset[preset.index(after: bang)...])
        if tail.count % 2 != 0 || !tail.allSatisfy({ $0.isHexDigit }) { return (preset, nil) }
        return (String(preset[..<bang]), tail)
    }
}

// A page's Game mode keys (app/KeyboardPage.cs and ZonesPage.cs): kept as gamemode.<device>, in presets after "!", and sent at once and
// again at each load.
final class GameKeys {
    let controlBitmap: Bool
    let experimental: Bool
    private(set) var keys: [Int]
    private var controls: [Int]?
    private let settingKey: String

    // Nil when the keyboard has no Game mode G-Lite can set.
    init?(_ device: FoundDevice, supported: Bool, experimental: Bool) {
        controlBitmap = !device.has(0x4522) && device.has(0x4523) && device.has(0x1B10)
        guard supported && (device.has(0x4522) || controlBitmap) else { return nil }
        self.experimental = experimental
        settingKey = "gamemode." + device.settingsKey
        keys = GameModeKeys.fromText(Settings.get(settingKey), controlBitmap)
    }

    var presetText: String { "!" + GameModeKeys.toText(keys) }

    var note: String {
        (experimental ? "Experimental, not tried on this keyboard yet. " : "") + "Select the keys you want to disable while gaming. "
            + (controlBitmap ? "" : "Windows and Menu keys are always disabled in Game mode. ")
            + "Changes apply immediately and can be saved in your G-Lite presets, but not in the keyboard's on-board memory."
    }

    // Changes the list and sends it; false when it was already that.
    @discardableResult
    func set(_ newKeys: [Int], on page: DevicePage) -> Bool {
        let list = GameModeKeys.clean(newKeys, controlBitmap)
        if list == keys { return false }
        keys = list
        let text = GameModeKeys.toText(list)
        if text.isEmpty { Settings.remove(settingKey) } else { Settings.set(settingKey, text) }
        page.logAction(text.isEmpty ? "Game mode keys cleared" : "Game mode keys " + list.map { String(format: "%02X", $0) }.joined(separator: " "))
        page.run({ hidpp in try self.send(hidpp) })
        page.edited()
        return true
    }

    func toggle(_ usage: Int, on page: DevicePage) {
        set(keys.contains(usage) ? keys.filter { $0 != usage } : keys + [usage], on: page)
    }

    func send(_ hidpp: Hidpp) throws { try GameModeKeys.send(hidpp, keys, controlBitmap, controls: &controls) }

    // At each load: a keyboard that lost power forgot them. A failure is only logged.
    func sendAgain(_ hidpp: Hidpp, _ who: String) {
        if keys.isEmpty { return }
        do { try send(hidpp) } catch { Log.add(who, "error", "Game mode keys: \(error)") }
    }
}

// What a key types with the Mac's keyboard layout in use (app/GameMode.cs, Typed), for the keys whose legend depends on it (letters,
// digits and punctuation); nil for the others, which keep the picture's name. Read once per layout, through the key's macOS key code
// (KeyPresses.usages, by position) and UCKeyTranslate.
enum TypedKeys {
    static let usages = Set(0x04...0x27).union(0x2D...0x38).union([0x64])
    private static var cache: (source: String, typed: [Int: String]) = ("", [:])

    static func typed(_ usage: Int) -> String? {
        guard usages.contains(usage), let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        if id != cache.source { cache = (id, read(source)) }
        return cache.typed[usage]
    }

    private static func read(_ source: TISInputSource) -> [Int: String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var typed: [Int: String] = [:]
        // On an ISO keyboard macOS swaps the key left of 1 (usage 35) and the one beside the left Shift (64): their key codes are
        // 0x0A and 0x32 the other way round from KeyPresses.usages' ANSI positions.
        let iso = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
        for (table, usage) in KeyPresses.usages where usages.contains(usage) {
            let code = iso && table == 0x32 ? 0x0A : iso && table == 0x0A ? 0x32 : table
            var dead: UInt32 = 0, length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            // No dead keys: a ^ or ¨ shows as itself, not as the start of an accented letter.
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters)
            let text = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            if status == noErr && !text.isEmpty { typed[usage] = text.uppercased() }
        }
        return typed
    }
}

// The Game view's box (app/GameMode.cs, GameModeBox): what Game mode does, the keyboard to pick keys on, and Clear.
final class GameModeBox: NSStackView {
    let picture: KeyPicture
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    private let game: GameKeys
    private weak var page: DevicePage?

    init(layout: KeyLayout, game: GameKeys, page: DevicePage, note text: String? = nil) {
        picture = KeyPicture(layout)
        self.game = game
        self.page = page
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        let note = Ui.hint(text ?? game.note)
        note.preferredMaxLayoutWidth = 560
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        picture.setAccessibilityLabel("Game mode keys")
        // The G915s' Fn key has the id the right Windows key has on the G815, and stays on.
        var fixed = Set<Int>()
        if !game.controlBitmap {
            for key in 0..<picture.count where picture.idOf(key) >= 0 && GameModeKeys.alwaysOff.contains(ZoneLighting.usage(picture.idOf(key)))
                && picture.nameOf(key) != "Fn" { fixed.insert(picture.idOf(key)) }
        }
        let bitmap = game.controlBitmap
        picture.picking = KeyPicture.Picking(picked: [], fixed: fixed, canPick: { GameModeKeys.canPick(ZoneLighting.usage($0), bitmap) },
                                             label: { id, name in TypedKeys.typed(ZoneLighting.usage(id)) ?? name })
        // Another keyboard layout picked in the menu bar: the legends follow.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                            object: nil, queue: .main) { [weak self] _ in self?.picture.needsDisplay = true }
        picture.keysPicked = { [weak self] keys in
            guard let self = self, let page = self.page else { return }
            for key in keys {
                let usage = ZoneLighting.usage(self.picture.idOf(key))
                if GameModeKeys.canPick(usage, bitmap) { self.game.toggle(usage, on: page) }
            }
            self.show()
        }
        clear.target = self
        clear.action = #selector(cleared)
        clear.setAccessibilityLabel("Clear the Game mode keys")
        addArrangedSubview(note)
        addArrangedSubview(picture)
        addArrangedSubview(clear)
        picture.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        show()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        picture.picking?.picked = Set(game.keys.map { KeyPresses.lightingId($0) })
        clear.isEnabled = !game.keys.isEmpty
    }

    @objc private func cleared() {
        guard let page = page else { return }
        game.set([], on: page)
        show()
    }
}
