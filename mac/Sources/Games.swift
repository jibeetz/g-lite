import AppKit

// The games on a virtual G515 TKL (app/Game.cs, app/KeyboardView.cs), opened by a click on the sidebar's G-Lite heading, as Windows
// opens them from the G-Lite title. Played on a grid of 15 columns by the keyboard's bottom 5 rows; a key covers the cells under it.
struct Cell: Equatable { var x: Int, y: Int }

enum GameKey { case up, down, left, right, space, flag, other }

class Game {
    static let columns = 15, rows = 5
    var score = 0, over = false
    var interval: Int { 400 }
    var help: String { "" }
    func step() {}
    func key(_ key: GameKey) {}
    func at(_ y: Int, _ x: Int) -> Int { 0 }
}

final class Blocks: Game {
    static let shapes: [[Int]] = [
        [0, 0, 1, 0, 2, 0, 3, 0], [0, 0, 1, 0, 0, 1, 1, 1], [0, 0, 1, 0, 2, 0, 1, 1], [1, 0, 2, 0, 0, 1, 1, 1],
        [0, 0, 1, 0, 1, 1, 2, 1], [0, 0, 0, 1, 1, 1, 2, 1], [2, 0, 0, 1, 1, 1, 2, 1],
    ]
    static let colors = [0xFF3B3B, 0xFF9A1F, 0xFFE03B, 0x3BE06A, 0x3BD5FF, 0x4A6BFF, 0xC04AFF]
    var cells = [[Int]](repeating: [Int](repeating: 0, count: Game.columns), count: Game.rows)
    private var piece: [Int] = [], pieceX = 0, pieceY = 0, color = 0

    override init() { super.init(); spawn() }

    override var interval: Int { max(120, 650 - score * 30) }
    override var help: String { "↑↓ move   ← rotate   → down   Space drop   Esc stop      lines \(score)" }

    override func key(_ key: GameKey) {
        switch key {
        case .up: move(-1)
        case .down: move(1)
        case .left: rotate()
        case .right: _ = fall()
        case .space: while fall() {}
        default: break
        }
    }

    override func step() { _ = fall() }

    private func fits(_ shape: [Int], _ dx: Int, _ dy: Int) -> Bool {
        for i in 0..<4 {
            let x = shape[2 * i] + dx, y = shape[2 * i + 1] + dy
            if x < 0 || x >= Game.columns || y < 0 || y >= Game.rows || cells[y][x] != 0 { return false }
        }
        return true
    }

    private func spawn() {
        let shape = Int.random(in: 0..<Blocks.shapes.count)
        piece = Blocks.shapes[shape]; color = Blocks.colors[shape]; pieceX = 0; pieceY = Int.random(in: 0..<Game.rows - 1)
        if !fits(piece, pieceX, pieceY) { over = true }
    }

    private func move(_ dy: Int) { if !over && fits(piece, pieceX, pieceY + dy) { pieceY += dy } }

    private func rotate() {
        if over { return }
        var rotated = [Int](repeating: 0, count: 8)
        for i in 0..<4 { rotated[2 * i] = piece[2 * i + 1]; rotated[2 * i + 1] = 3 - piece[2 * i] }
        let minX = (0..<4).map { rotated[2 * $0] }.min()!, minY = (0..<4).map { rotated[2 * $0 + 1] }.min()!
        for i in 0..<4 { rotated[2 * i] -= minX; rotated[2 * i + 1] -= minY }
        for kick in [0, -1, 1, -2, 2] where fits(rotated, pieceX, pieceY + kick) { piece = rotated; pieceY += kick; return }
    }

    private func fall() -> Bool {
        if over { return false }
        if fits(piece, pieceX + 1, pieceY) { pieceX += 1; return true }
        for i in 0..<4 { cells[piece[2 * i + 1] + pieceY][piece[2 * i] + pieceX] = color }
        clearFull()
        spawn()
        return false
    }

    func clearFull() {
        var x = Game.columns - 1
        while x >= 0 {
            if (0..<Game.rows).allSatisfy({ cells[$0][x] != 0 }) {
                for column in stride(from: x, to: 0, by: -1) { for y in 0..<Game.rows { cells[y][column] = cells[y][column - 1] } }
                for y in 0..<Game.rows { cells[y][0] = 0 }
                score += 1
            } else { x -= 1 }
        }
    }

    override func at(_ y: Int, _ x: Int) -> Int {
        if !over { for i in 0..<4 where piece[2 * i] + pieceX == x && piece[2 * i + 1] + pieceY == y { return color } }
        return cells[y][x]
    }
}

class KeyGame: Game {
    var keyAt = [[Int]](repeating: [Int](repeating: -1, count: Game.columns), count: Game.rows)
    var board: [Int] = []

    init(_ cells: [[Cell]?]) {
        super.init()
        for (index, keyCells) in cells.enumerated() {
            guard let keyCells = keyCells else { continue }
            board.append(index)
            for cell in keyCells { keyAt[cell.y][cell.x] = index }
        }
    }

    // To the next key in that direction, skipping cells of the key it starts on.
    func move(_ start: Cell, _ dx: Int, _ dy: Int, wrap: Bool) -> Cell {
        let from = keyAt[start.y][start.x]
        var x = start.x, y = start.y
        for _ in 0..<Game.columns * Game.rows {
            x += dx; y += dy
            if wrap { x = (x + Game.columns) % Game.columns; y = (y + Game.rows) % Game.rows }
            else if x < 0 || x >= Game.columns || y < 0 || y >= Game.rows { return start }
            if keyAt[y][x] >= 0 && keyAt[y][x] != from { return Cell(x: x, y: y) }
        }
        return start
    }
}

final class Snake: KeyGame {
    private var body: [Int] = [], head = Cell(x: 4, y: 2), direction = Cell(x: 1, y: 0), next = Cell(x: 1, y: 0), food = -1

    override init(_ cells: [[Cell]?]) {
        super.init(cells)
        for x in stride(from: 4, through: 2, by: -1) { body.append(keyAt[2][x]) }
        feed()
    }

    override var interval: Int { max(110, 320 - score * 12) }
    override var help: String { "arrows steer   Esc stop      length \(body.count)" }

    private func feed() {
        let free = board.filter { !body.contains($0) }
        if free.isEmpty { over = true } else { food = free.randomElement()! }
    }

    override func key(_ key: GameKey) {
        let wanted: Cell
        switch key {
        case .up: wanted = Cell(x: 0, y: -1)
        case .down: wanted = Cell(x: 0, y: 1)
        case .left: wanted = Cell(x: -1, y: 0)
        case .right: wanted = Cell(x: 1, y: 0)
        default: wanted = direction
        }
        if wanted.x != -direction.x || wanted.y != -direction.y { next = wanted }
    }

    override func step() {
        if over { return }
        direction = next
        head = move(head, direction.x, direction.y, wrap: true)
        let key = keyAt[head.y][head.x], eat = key == food
        if !eat { body.removeLast() }
        if body.contains(key) { over = true; return }
        body.insert(key, at: 0)
        if eat { score += 1; feed() }
    }

    override func at(_ y: Int, _ x: Int) -> Int {
        let key = keyAt[y][x]
        if key < 0 { return 0 }
        if body[0] == key { return 0xB8FF6A }
        if body.contains(key) { return 0x2FBF4A }
        return food == key && !over ? 0xFF3030 : 0
    }
}

final class Mines: KeyGame {
    static let count = 10
    static let legendColors = [0x707070, 0x3B7BFF, 0x3BE06A, 0xFFE03B, 0xC04AFF, 0xFF9A1F]
    static let legendNames = ["0", "1", "2", "3", "4+", "flag"]
    var mine: [Bool]
    var placed = false
    private var state: [Int], near: [[Int]]
    private var cursor = Cell(x: Game.columns / 2, y: Game.rows / 2), flags = 0, blink = false

    // Neighbours are the keys within 5 points, so they follow the keys' shapes, not the grid.
    init(_ keys: [CGRect], _ cells: [[Cell]?]) {
        mine = [Bool](repeating: false, count: keys.count)
        state = [Int](repeating: 0, count: keys.count)
        near = [[Int]](repeating: [], count: keys.count)
        super.init(cells)
        for i in board {
            let area = keys[i].insetBy(dx: -5, dy: -5)
            near[i] = board.filter { $0 != i && area.intersects(keys[$0]) }
        }
    }

    override var interval: Int { 400 }
    override var help: String { "arrows move   Space open   F flag   Esc stop      mines \(Mines.count - flags)" }

    override func step() { blink.toggle() }

    override func key(_ key: GameKey) {
        if over { return }
        switch key {
        case .left: cursor = move(cursor, -1, 0, wrap: false)
        case .right: cursor = move(cursor, 1, 0, wrap: false)
        case .up: cursor = move(cursor, 0, -1, wrap: false)
        case .down: cursor = move(cursor, 0, 1, wrap: false)
        default: break
        }
        let selected = keyAt[cursor.y][cursor.x]
        if key == .space { open(selected) }
        if key == .flag && state[selected] != 1 { state[selected] = 2 - state[selected]; flags += state[selected] == 2 ? 1 : -1 }
        blink = true
    }

    private func place(_ first: Int) {
        placed = true
        var minesPlaced = 0
        while minesPlaced < Mines.count {
            let key = board.randomElement()!
            if mine[key] || key == first || near[first].contains(key) { continue }
            mine[key] = true
            minesPlaced += 1
        }
    }

    func minesAround(_ key: Int) -> Int { near[key].filter { mine[$0] }.count }

    func open(_ key: Int) {
        if state[key] != 0 { return }
        if !placed { place(key) }
        if mine[key] { over = true; return }
        var todo = [key]
        while let i = todo.popLast() {
            if state[i] != 0 { continue }
            state[i] = 1
            score += 1
            if minesAround(i) == 0 { todo += near[i].filter { state[$0] == 0 && !mine[$0] } }
        }
        if !board.contains(where: { !mine[$0] && state[$0] != 1 }) { over = true }
    }

    func opened(_ key: Int) -> Bool { state[key] == 1 }

    override func at(_ y: Int, _ x: Int) -> Int {
        let key = keyAt[y][x]
        if key < 0 { return 0 }
        if blink && !over && key == keyAt[cursor.y][cursor.x] { return 0xFFFFFF }
        if over && mine[key] && state[key] != 2 { return 0xFF3030 }
        if state[key] == 2 { return Mines.legendColors[5] }
        if state[key] != 1 { return 0 }
        return Mines.legendColors[min(minesAround(key), 4)]
    }
}

// The window: the keys in the factory animation's rainbow, or the game. Windows' borderless window has its own close button; this
// one is a plain titled window.
final class GamesWindow: NSWindowController, NSWindowDelegate {
    private let board: GamesBoard

    static func make() -> GamesWindow? { KeyLayout.load("g515-tkl.json").map { GamesWindow(model: $0) } }

    init(model: KeyLayout) {
        board = GamesBoard(model)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: board.frame.size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = model.name
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 28 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.contentView = board
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    // Left of the main window, as on Windows.
    func toggle(beside main: NSWindow?) {
        guard let window = window else { return }
        if window.isVisible { window.close(); return }
        if let main = main {
            let area = main.screen?.visibleFrame ?? main.frame
            window.setFrameTopLeftPoint(NSPoint(x: max(area.minX, main.frame.minX - window.frame.width - 8), y: main.frame.maxY))
        }
        board.start()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(board)
    }

    func windowWillClose(_ notification: Notification) { board.stop() }
}

final class GamesBoard: NSView {
    static let keyUnit: CGFloat = 40, pad: CGFloat = 16, headerHeight: CGFloat = 40
    private var keys: [(box: CGRect, label: String)] = []
    private(set) var cells: [[Cell]?] = []
    private var width: CGFloat = 0, height: CGFloat = 0
    private var game: Game?, make: (() -> Game)?, nextStep = 0.0
    private var timer: Timer?
    private let started = Date()
    private var buttons: [NSButton] = [], stopButton = NSButton()

    init(_ model: KeyLayout) {
        super.init(frame: .zero)
        let unit = GamesBoard.keyUnit, pad = GamesBoard.pad
        for row in model.rows {
            var x: CGFloat = 0, tall: CGFloat = 0
            let y = height
            for token in row.components(separatedBy: "|") {
                if token.hasPrefix("_") { x += CGFloat(Double(token.dropFirst()) ?? 0) * unit; continue }
                let parts = token.components(separatedBy: ":")
                let keyWidth = parts.count > 1 ? CGFloat(Double(parts[1]) ?? 1) * unit : unit
                let keyHeight = parts.count > 2 ? CGFloat(Double(parts[2]) ?? 1) * unit : unit
                keys.append((CGRect(x: pad + x, y: GamesBoard.headerHeight + pad + y, width: keyWidth - 4, height: keyHeight - 4), parts[0]))
                x += keyWidth
                tall = max(tall, min(keyHeight, unit))
                width = max(width, x)
            }
            height += tall > 0 ? tall : x
        }
        cells = GamesBoard.cells(keys.map { $0.box })
        frame = NSRect(x: 0, y: 0, width: width + 2 * pad, height: GamesBoard.headerHeight + height + 2 * pad + 20)
        var right = frame.width - 12
        for (name, make) in [("Snake", { Snake(self.cells) as Game }), ("Blocks", { Blocks() as Game }),
                             ("Mines", { Mines(self.keys.map { $0.box }, self.cells) as Game })] {
            right -= 72
            buttons.append(button(name, right) { [unowned self] in self.play(make) })
        }
        stopButton = button("Stop", frame.width - 12 - 72) { [unowned self] in self.game = nil; self.refreshButtons() }
        refreshButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Each key's cells in the bottom five rows: the columns whose centre falls on it.
    static func cells(_ boxes: [CGRect]) -> [[Cell]?] {
        let rows = Array(Set(boxes.map { $0.minY })).sorted()
        return boxes.map { box in
            let row = (rows.firstIndex(of: box.minY) ?? 0) - (rows.count - Game.rows)
            if row < 0 { return nil }
            let columns = (0..<Game.columns).filter { column in
                let centre = pad + (CGFloat(column) + 0.5) * keyUnit
                return centre >= box.minX && centre < box.maxX + 4
            }
            return columns.isEmpty ? nil : columns.map { Cell(x: $0, y: row) }
        }
    }

    private func button(_ title: String, _ x: CGFloat, _ action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .recessed
        button.frame = NSRect(x: x, y: 10, width: 68, height: 24)
        addSubview(button)
        return button
    }

    private func refreshButtons() {
        for button in buttons { button.isHidden = game != nil }
        stopButton.isHidden = game == nil
        needsDisplay = true
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() { timer?.invalidate(); timer = nil; game = nil; refreshButtons() }

    private var milliseconds: Double { Date().timeIntervalSince(started) * 1000 }

    private func play(_ newGame: @escaping () -> Game) {
        make = newGame
        let game = newGame()
        self.game = game
        nextStep = milliseconds + Double(game.interval)
        refreshButtons()
        window?.makeFirstResponder(self)
    }

    private func tick() {
        if let game = game, !game.over, milliseconds >= nextStep { game.step(); nextStep = milliseconds + Double(game.interval) }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let game = game else { super.keyDown(with: event); return }
        if event.keyCode == 0x35 { self.game = nil; refreshButtons(); return }
        if game.over, let make = make { play(make); return }
        let key: GameKey
        switch event.keyCode {
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        case 49: key = .space
        case 3: key = .flag
        default: key = .other
        }
        game.key(key)
        needsDisplay = true
    }

    private static func color(_ rgb: Int, _ factor: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255 * factor, green: CGFloat(rgb >> 8 & 0xFF) / 255 * factor,
                blue: CGFloat(rgb & 0xFF) / 255 * factor, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 28 / 255, alpha: 1).setFill()
        bounds.fill()
        let seconds = milliseconds / 1000, pad = GamesBoard.pad
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let keyFont = NSFont.systemFont(ofSize: 10)
        for (index, key) in keys.enumerated() {
            let box = key.box
            var fill = NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 32 / 255, alpha: 1)
            // Windows' factory animation, approximated: a rainbow moving left to right.
            let x = Double((box.midX - pad) / width)
            var color = NSColor(hue: CGFloat(((seconds / 8 - x).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)),
                                saturation: 1, brightness: 1, alpha: 1)
            if let game = game {
                let hit = cells[index]?.lazy.map { game.at($0.y, $0.x) }.first { $0 != 0 } ?? 0
                let arrow = ["↑", "↓", "←", "→"].contains(key.label)
                color = hit != 0 ? GamesBoard.color(game.over && !(game is Mines) ? 0xFF2828 : hit)
                    : arrow ? NSColor(white: 120 / 255, alpha: 1) : NSColor(white: 45 / 255, alpha: 1)
                if hit != 0 { fill = GamesBoard.color(game.over && !(game is Mines) ? 0xFF2828 : hit, 0.45) }
            }
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            fill.setFill()
            path.fill()
            NSColor(srgbRed: 55 / 255, green: 55 / 255, blue: 58 / 255, alpha: 1).setStroke()
            path.stroke()
            let text = NSAttributedString(string: key.label, attributes: [.font: keyFont, .foregroundColor: color, .paragraphStyle: centred])
            let textHeight = text.size().height
            text.draw(in: NSRect(x: box.minX, y: box.midY - textHeight / 2, width: box.width, height: textHeight))
            color.withAlphaComponent(90 / 255).setFill()
            NSRect(x: box.minX + 6, y: box.maxY - 4, width: box.width - 12, height: 2).fill()
        }
        let footerFont = NSFont.systemFont(ofSize: 12), grey = NSColor(white: 150 / 255, alpha: 1)
        var what = "factory animation (approximation)"
        if let game = game { what = game.over ? "game over      score \(game.score)      any key to play again" : game.help }
        let footerY = bounds.height - 26
        NSAttributedString(string: what, attributes: [.font: footerFont, .foregroundColor: grey]).draw(at: NSPoint(x: pad, y: footerY))
        if let game = game as? Mines, !game.over {
            var legendX = bounds.width - pad
            for i in stride(from: Mines.legendNames.count - 1, through: 0, by: -1) {
                let name = NSAttributedString(string: Mines.legendNames[i], attributes: [.font: footerFont, .foregroundColor: grey])
                legendX -= name.size().width
                name.draw(at: NSPoint(x: legendX, y: footerY))
                legendX -= 12
                GamesBoard.color(Mines.legendColors[i]).setFill()
                NSRect(x: legendX, y: footerY + 3, width: 10, height: 10).fill()
                legendX -= 12
            }
        }
    }
}

private final class ClosureButton: NSButton {
    private var closure: () -> Void = {}

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        closure = action
        target = self
        self.action = #selector(clicked)
    }

    @objc private func clicked() { closure() }
}
