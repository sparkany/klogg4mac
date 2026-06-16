//
//  TabStripView.swift — custom tab strip with per-tab close buttons.
//
//  NSTabView's native top tabs (.topTabsBezelBorder) draw no close control, which
//  left users unable to close a file from the tab bar. We instead drive the
//  NSTabView in .noTabsNoBorder mode and render our own horizontal row of tab
//  buttons here — each a label that selects the tab plus an "×" that closes it,
//  mirroring klogg's TabbedCrawlerWidget close buttons.
//
//  The strip is a thin controller-agnostic view: it takes a list of titles + the
//  selected index and reports clicks via callbacks. TabController owns the model.
//

import AppKit

final class TabStripView: NSView {

    /// Fired when the user clicks a tab's body (request to select index).
    var onSelect: ((Int) -> Void)?
    /// Fired when the user clicks a tab's × (request to close index).
    var onClose: ((Int) -> Void)?

    /// Fixed strip height (matches a compact macOS tab bar).
    static let stripHeight: CGFloat = 28

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyStripBackground()

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: TabStripView.stripHeight)
    }

    private func applyStripBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStripBackground()
    }

    /// Rebuild the strip from the current titles + selected index.
    func reload(titles: [String], selected: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, title) in titles.enumerated() {
            stack.addArrangedSubview(makeTab(index: idx, title: title,
                                             selected: idx == selected))
        }
    }

    // MARK: - Tab item construction

    private func makeTab(index: Int, title: String, selected: Bool) -> NSView {
        let tab = TabItemView(index: index, title: title, selected: selected)
        tab.onSelect = { [weak self] i in self?.onSelect?(i) }
        tab.onClose  = { [weak self] i in self?.onClose?(i) }
        return tab
    }
}

// MARK: - TabItemView

/// One pill in the strip: a clickable title + a trailing × close button.
private final class TabItemView: NSView {

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let index: Int
    private let isSelected: Bool
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    init(index: Int, title: String, selected: Bool) {
        self.index = index
        self.isSelected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        applyPillBackground()

        label.stringValue = title
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = selected ? .selectedControlTextColor : .controlTextColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = ""
        if let img = NSImage(systemSymbolName: "xmark.circle.fill",
                             accessibilityDescription: "Close tab") {
            closeButton.image = img
        } else {
            closeButton.title = "×"
        }
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close (⌘W)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(label)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Re-resolve the pill background for the current appearance (frozen .cgColor
    /// would not follow a Light/Dark switch).
    private func applyPillBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected
                ? NSColor.selectedControlColor
                : NSColor.controlBackgroundColor).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPillBackground()
    }

    @objc private func closeClicked() {
        onClose?(index)
    }

    override func mouseDown(with event: NSEvent) {
        // A click anywhere on the pill (other than the × button, which consumes its
        // own click) selects this tab.
        onSelect?(index)
    }
}
