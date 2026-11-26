import AppKit

// The rows layout of Windows 0.1.0-beta (app/Rows.cs), like macOS's System Settings: titled sections, one below the other, of rows
// each with a title and a hint at the left and one control at the right. A page keeps the device's picture above them (sticky) and
// scrolls the sections under it. A row or section the device doesn't have is hidden (isHidden), one that doesn't apply now greyed
// (RowView.enable); a stack view leaves hidden views out, so nothing moves by hand as Windows' RowLayout does.
enum Rows {
    static let height: CGFloat = 56, inset: CGFloat = 16
    // Every kind of control has one width in a row, so the same control looks the same on every screen.
    static let controlWidth: CGFloat = 240, valueWidth: CGFloat = 64

    // A section: its title, then its rows in a rounded box.
    static func section(_ title: String, _ rows: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let box = SectionBox(rows)
        let section = NSStackView(views: [heading, box])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        box.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    // A row: title and hint at the left, the control at the right, centred in the row's height.
    static func row(_ title: String, _ hint: String, _ control: NSView) -> RowView { RowView(title, hint, control) }

    // A slider with its value at its left, as "100%".
    static func slider(_ slider: NSSlider, _ value: NSTextField) -> NSView {
        value.alignment = .right
        let holder = NSStackView(views: [value, slider])
        holder.spacing = 8
        value.widthAnchor.constraint(equalToConstant: valueWidth).isActive = true
        slider.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        return holder
    }

    // A paragraph across a section, as tall as its lines.
    static func note(_ text: String) -> NSView {
        let label = Ui.hint(text)
        label.preferredMaxLayoutWidth = 560
        let holder = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -14),
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -inset),
        ])
        return holder
    }

    // The page: header, then the sticky picture (if any), then the sections, which scroll; the status line and buttons at the
    // bottom, under a line.
    static func page(header: NSView, sticky: NSView?, sections: [NSView], status: NSView?, buttons: [NSView]) -> NSView {
        let top = NSStackView(views: [header] + (sticky.map { [$0] } ?? []))
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 18
        if let sticky = sticky { sticky.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true }

        let content = NSStackView(views: sections)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        for section in sections { section.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let document = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
        ])

        let line = NSBox()
        line.boxType = .separator
        let footer = NSStackView(views: (status.map { [$0] } ?? []) + buttons)
        footer.distribution = .fill
        status?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in buttons { button.setContentHuggingPriority(.required, for: .horizontal) }

        let page = NSView()
        for view in [top, scroll, line, footer] { view.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: page.safeAreaLayoutGuide.topAnchor, constant: 16),
            top.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            top.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            footer.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -14),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        return page
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// A section's rows in a rounded box, a rule above each shown row but the first.
final class SectionBox: NSBox {
    private let stack: NSStackView

    init(_ rows: [NSView]) {
        stack = NSStackView(views: rows)
        super.init(frame: .zero)
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 8
        borderWidth = 1
        borderColor = .separatorColor
        fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.04) : NSColor.black.withAlphaComponent(0.025)
        }
        contentViewMargins = .zero
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        // In a holder pinned to the stack: as the box's content view itself the stack wasn't sized by its rows.
        let holder = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: holder.topAnchor),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
        contentView = holder
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        var first = true
        for view in stack.arrangedSubviews where !view.isHidden {
            (view as? RowView)?.ruled = !first
            first = false
        }
    }
}

final class RowView: NSView {
    let title: NSTextField, hint: NSTextField
    let control: NSView
    var ruled = false { didSet { if ruled != oldValue { needsDisplay = true } } }

    init(_ titleText: String, _ hintText: String, _ rowControl: NSView) {
        title = NSTextField(labelWithString: titleText)
        hint = NSTextField(wrappingLabelWithString: hintText)
        control = rowControl
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        // A hint too long for its line wraps, and the row grows past its usual height.
        hint.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        for label in [title, hint] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        // The control keeps its size; the text takes the rest of the row.
        if let stack = control as? NSStackView { stack.setHuggingPriority(.required, for: .horizontal) }
        control.setContentHuggingPriority(.required, for: .horizontal)
        let text = NSStackView(views: [title, hint])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        for view in [text, control] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Rows.height),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Rows.inset),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Rows.inset),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // A row whose setting doesn't apply now is greyed, both lines.
    func enable(_ on: Bool) {
        title.textColor = on ? .labelColor : .tertiaryLabelColor
        hint.textColor = on ? .secondaryLabelColor : .tertiaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard ruled else { return }
        NSColor.separatorColor.setFill()
        // Flipped or not, the rule goes along the row's top edge.
        let y = isFlipped ? 0 : bounds.height - 1
        NSRect(x: Rows.inset, y: y, width: bounds.width - 2 * Rows.inset, height: 1).fill()
    }
}
