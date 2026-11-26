import AppKit

// A row per button or G key with what it does (app/Buttons.cs, ButtonRows), for the mice's Bindings view and the keyboards' G keys:
// the actions' list, a binding the list lacks shown by its name first, and Keystroke… recording the next keys pressed in the window,
// with Ctrl, Shift, Alt (Option) and Win (Command); Esc cancels. A row each (Rows), the hint above them, for a section of its own.
final class ButtonRows: NSStackView {
    private let hint = Ui.hint("")
    private let hintHolder = NSView()
    private let actions: [ButtonAction]
    private var popups: [NSPopUpButton] = [], rows: [RowView] = [], described: [Bool] = []
    private var names: [String] = [], bindings: [[UInt8]?] = [], editable = false, pressed = -1, note = ""
    private var keyMonitor: Any?
    private(set) var recording = -1
    var assigned: ((Int, [UInt8]) -> Void)?

    init(actions: [ButtonAction]) {
        self.actions = actions
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        hintHolder.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: hintHolder.topAnchor, constant: 14),
            hint.bottomAnchor.constraint(equalTo: hintHolder.bottomAnchor, constant: -10),
            hint.leadingAnchor.constraint(equalTo: hintHolder.leadingAnchor, constant: Rows.inset),
            hint.trailingAnchor.constraint(equalTo: hintHolder.trailingAnchor, constant: -Rows.inset),
        ])
        addArrangedSubview(hintHolder)
        hintHolder.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // pressed: the row shown in bold (the mouse's button spy); note: the hint while nothing is recorded.
    func show(names newNames: [String], bindings newBindings: [[UInt8]?], editable canEdit: Bool, pressed pressedRow: Int = -1, note text: String = "") {
        names = newNames; bindings = newBindings; editable = canEdit; pressed = pressedRow; note = text
        if recording >= names.count || !editable { stopRecording() }
        let count = names.count
        if popups.count != count {
            for row in rows { row.removeFromSuperview() }
            popups = (0..<count).map { index in
                let popup = NSPopUpButton()
                popup.tag = index
                popup.target = self
                popup.action = #selector(picked)
                popup.widthAnchor.constraint(equalToConstant: Rows.controlWidth).isActive = true
                return popup
            }
            rows = (0..<count).map { Rows.row(names[$0], "", popups[$0]) }
            for (index, row) in rows.enumerated() {
                addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
                row.ruled = index > 0
            }
            described = [Bool](repeating: false, count: count)
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
            rows[index].title.stringValue = names[index]
            rows[index].title.textColor = index == pressed ? .controlAccentColor : .labelColor
            rows[index].title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: index == pressed ? .bold : .medium)
        }
        hint.stringValue = recording >= 0 ? "Press the keys for \(names[recording]), or Esc to cancel." : note
        hintHolder.isHidden = hint.stringValue.isEmpty
        if let first = rows.first { first.ruled = !hintHolder.isHidden }
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
