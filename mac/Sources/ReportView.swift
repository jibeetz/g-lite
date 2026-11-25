import AppKit

// The device report's sheet (app/ReportView.cs): what G-Lite read, Read again, Copy, and Open GitHub issue with the report filled in
// (on the clipboard too, for a long one). Esc or Back closes it.
final class ReportView: NSViewController {
    static let issues = "https://github.com/csmarvz/g-lite/issues/new"
    private let noun: String, issueTitle: String
    private let read: (@escaping (String?, String?) -> Void) -> Void
    private let textView = NSTextView()
    private let size = Ui.value(), status = StatusLine()
    private let again = NSButton(title: "Read again", target: nil, action: nil)
    private let issue = NSButton(title: "Open GitHub issue", target: nil, action: nil)
    private let copy = NSButton(title: "Copy", target: nil, action: nil)
    private var text = ""

    init(noun: String, title: String, read: @escaping (@escaping (String?, String?) -> Void) -> Void) {
        self.noun = noun
        issueTitle = title
        self.read = read
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func title(for device: FoundDevice) -> String {
        "Device report: " + (device.shortName.isEmpty ? "Logitech device" : device.shortName)
            + (device.wirelessId != 0 ? String(format: " (%04X)", device.wirelessId) : "")
    }

    override func loadView() {
        let intro = NSTextField(wrappingLabelWithString: "What G-Lite reads from this \(noun). It has no serial number, no name you gave the device and no Mac path.")
        intro.preferredMaxLayoutWidth = 440
        again.target = self; again.action = #selector(readAgain)
        let head = NSStackView(views: [intro, NSView(), again])
        head.alignment = .centerY

        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Device report")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 400).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 600).isActive = true
        let reportHead = NSStackView(views: [Ui.secondary("Report"), NSView(), size])

        let back = NSButton(title: "Back", target: self, action: #selector(close))
        back.keyEquivalent = "\u{1b}"
        issue.target = self; issue.action = #selector(openIssue)
        copy.target = self; copy.action = #selector(copyText)
        copy.keyEquivalent = "\r"
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, back, issue, copy])

        let content = NSStackView(views: [Ui.box("Device report", head), reportHead, scroll, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        for view in [content.arrangedSubviews[0], reportHead, footer] { view.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true }
        let sheet = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        sheet.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: sheet.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: sheet.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: sheet.bottomAnchor, constant: -16),
        ])
        view = sheet
        readAgain()
    }

    @objc private func readAgain() {
        for button in [again, issue, copy] { button.isEnabled = false }
        textView.string = "Reading the device. This takes a few seconds and changes nothing on it."
        size.stringValue = ""
        status.show("Reading…")
        read { [weak self] report, error in
            guard let self = self else { return }
            self.again.isEnabled = true
            guard let report = report else {
                self.textView.string = self.text.isEmpty ? "G-Lite couldn't read the device: " + (error ?? "") : self.text
                self.issue.isEnabled = !self.text.isEmpty
                self.copy.isEnabled = !self.text.isEmpty
                self.status.show(error ?? "", error: true)
                return
            }
            self.text = String(report.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" })
            self.textView.string = self.text
            let lines = self.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").count
            self.size.stringValue = String(format: "%.1f KB, %d lines", Double(self.text.utf8.count) / 1024, lines)
            self.issue.isEnabled = true
            self.copy.isEnabled = true
            self.status.show("Read only. Nothing is sent.")
        }
    }

    private func toClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyText() {
        toClipboard(text)
        status.show("Copied to the clipboard")
    }

    // The report in the new issue when it fits a URL, else on the clipboard to paste.
    @objc private func openIssue() {
        let fenced = "```\n" + text + "```\n"
        toClipboard(fenced)
        let whole = fenced.count < 4000
        var parts = URLComponents(string: ReportView.issues)!
        parts.queryItems = [URLQueryItem(name: "title", value: issueTitle),
                            URLQueryItem(name: "body", value: whole ? fenced : "Paste the report from G-Lite here. It's on your clipboard.\n\n")]
        guard let url = parts.url, NSWorkspace.shared.open(url) else { status.show("Couldn't open the browser", error: true); return }
        status.show(whole ? "Opened a new issue with the report" : "Copied. Paste it into the new issue.")
    }

    @objc private func close() { dismiss(nil) }
}
