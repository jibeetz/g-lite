import AppKit

// A row per button or G key with what it does (app/Buttons.cs, ButtonRows), for the mice's Bindings view and the keyboards' G keys:
// the actions' list, a binding the list lacks shown by its name first, and Keystroke… recording the next keys pressed in the window,
// with Ctrl, Shift, Alt (Option) and Win (Command); Esc cancels. Two rows a line past ten (the G600 has 20).
final class ButtonRows: NSStackView {
    private let hint = Ui.hint("")
    private let grid = NSGridView()
    private let actions: [ButtonAction]
    private var popups: [NSPopUpButton] = [], nameLabels: [NSTextField] = [], described: [Bool] = []
    private var names: [String] = [], bindings: [[UInt8]?] = [], editable = false, pressed = -1, note = ""
    private var keyMonitor: Any?
    private(set) var recording = -1
    var assigned: ((Int, [UInt8]) -> Void)?

    init(actions: [ButtonAction]) {
        self.actions = actions
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        addArrangedSubview(hint)
        addArrangedSubview(grid)
    }

    required init?(coder: NSCoder) { fatalError() }

    // pressed: the row shown in bold (the mouse's button spy); note: the hint while nothing is recorded.
    func show(names newNames: [String], bindings newBindings: [[UInt8]?], editable canEdit: Bool, pressed pressedRow: Int = -1, note text: String = "") {
        names = newNames; bindings = newBindings; editable = canEdit; pressed = pressedRow; note = text
        if recording >= names.count || !editable { stopRecording() }
        let count = names.count
        if popups.count != count {
            while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
            popups = (0..<count).map { index in
                let popup = NSPopUpButton()
                popup.tag = index
                popup.target = self
                popup.action = #selector(picked)
                popup.widthAnchor.constraint(equalToConstant: 170).isActive = true
                return popup
            }
            nameLabels = names.map { Ui.label($0) }
            described = [Bool](repeating: false, count: count)
            let perRow = count > 10 ? 2 : 1
            for start in stride(from: 0, to: count, by: perRow) {
                var cells: [NSView] = []
                for index in start..<min(start + perRow, count) { cells += [nameLabels[index], popups[index]] }
                grid.addRow(with: cells)
            }
        }
        for index in 0..<count {
            let binding = index < bindings.count ? bindings[index] : nil
            let action = Bindings.find(actions, binding)
            let popup = popups[index]
            popup.removeAllItems()
            described[index] = action < 0
            if action < 0 { popup.addItem(withTitle: Bindings.describe(binding)) }
            popup.addItems(withTitles: actions.map { $0.name } + ["Keystroke…"])
            popup.selectItem(at: action < 0 ? 0 : action)
            popup.isEnabled = editable && recording < 0
            nameLabels[index].stringValue = names[index]
            nameLabels[index].textColor = index == pressed ? .controlAccentColor : .labelColor
            nameLabels[index].font = index == pressed ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        }
        hint.stringValue = recording >= 0 ? "Press the keys for \(names[recording]), or Esc to cancel." : note
        hint.isHidden = hint.stringValue.isEmpty
    }

    private func redraw() { show(names: names, bindings: bindings, editable: editable, pressed: pressed, note: note) }

    @objc private func picked(_ sender: NSPopUpButton) {
        let row = sender.tag
        let index = sender.indexOfSelectedItem - (described[row] ? 1 : 0)
        if index < 0 { return }
        if index >= actions.count { startRecording(row); return }
        assigned?(row, actions[index].bytes)
    }

    private func startRecording(_ row: Int) {
        stopRecording()
        recording = row
        redraw()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.recording >= 0 else { return event }
            if event.keyCode == 0x35 { self.stopRecording(); self.redraw(); return nil }
            guard let usage = KeyPresses.usages[Int(event.keyCode)] else { return nil }
            let flags = event.modifierFlags
            let modifiers = (flags.contains(.control) ? 1 : 0) | (flags.contains(.shift) ? 2 : 0) | (flags.contains(.option) ? 4 : 0)
                | (flags.contains(.command) ? 8 : 0)
            let row = self.recording
            self.stopRecording()
            self.assigned?(row, Bindings.key(modifiers, usage))
            self.redraw()
            return nil
        }
    }

    func stopRecording() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        recording = -1
    }
}
