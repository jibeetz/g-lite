import AppKit

// The When idle box (app/KeyboardPage.cs): Dim after, Dim to and Turn off after, a lighting's idle, dim and sleep, saved with it.
final class IdleBox: NSObject {
    static let idleSeconds = [0, 15, 30, 60, 120, 300, 600]
    static let idleNames = ["Never", "15 s", "30 s", "1 min", "2 min", "5 min", "10 min"]
    static let dimPercents = [0, 10, 25, 50, 75]
    static let dimNames = ["Dark", "10%", "25%", "50%", "75%"]
    static let sleepSeconds = [0, 60, 120, 300, 600, 900, 1800]
    static let sleepNames = ["Never", "1 min", "2 min", "5 min", "10 min", "15 min", "30 min"]

    private let dimAfter = NSPopUpButton(), dimTo = NSPopUpButton(), turnOff = NSPopUpButton()
    // The G915 TKL reads 0 as at once, not never (tried on an owner's keyboard), so the profile keyboards don't offer Never.
    private let never: Int
    var changed: ((_ idle: Int, _ dim: Int, _ sleep: Int) -> Void)?
    // The When idle section's rows.
    private(set) var rows: [RowView] = []

    init(offersNever: Bool) {
        never = offersNever ? 0 : 1
        super.init()
        dimAfter.addItems(withTitles: Array(IdleBox.idleNames.dropFirst(never)))
        dimTo.addItems(withTitles: IdleBox.dimNames)
        turnOff.addItems(withTitles: Array(IdleBox.sleepNames.dropFirst(never)))
        for (popup, name, hint) in [(dimAfter, "Dim after", "Time without typing before the keys dim"),
                                    (dimTo, "Dim to", "How bright the keys stay while dimmed"),
                                    (turnOff, "Turn off after", "Time without typing before the lighting goes off")] {
            popup.target = self
            popup.action = #selector(picked)
            popup.widthAnchor.constraint(equalToConstant: Rows.controlWidth).isActive = true
            popup.setAccessibilityLabel(name)
            rows.append(Rows.row(name, hint, popup))
        }
    }

    static func nearest(_ values: [Int], _ value: Int) -> Int {
        values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
    }

    func show(_ lighting: Lighting, enabled: Bool) {
        dimAfter.selectItem(at: IdleBox.nearest(Array(IdleBox.idleSeconds.dropFirst(never)), lighting.idle))
        dimTo.selectItem(at: IdleBox.nearest(IdleBox.dimPercents, lighting.dim))
        turnOff.selectItem(at: IdleBox.nearest(Array(IdleBox.sleepSeconds.dropFirst(never)), lighting.sleep))
        dimAfter.isEnabled = enabled
        dimTo.isEnabled = enabled && lighting.idle > 0
        turnOff.isEnabled = enabled
        for (row, popup) in zip(rows, [dimAfter, dimTo, turnOff]) { row.enable(popup.isEnabled) }
    }

    @objc private func picked() {
        changed?(IdleBox.idleSeconds[max(0, dimAfter.indexOfSelectedItem) + never], IdleBox.dimPercents[max(0, dimTo.indexOfSelectedItem)],
                 IdleBox.sleepSeconds[max(0, turnOff.indexOfSelectedItem) + never])
    }
}

// How long since the last key press or mouse move on the Mac (Windows: GetLastInputInfo, WindowHelpers.IdleSeconds).
enum IdleTime {
    static var seconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
