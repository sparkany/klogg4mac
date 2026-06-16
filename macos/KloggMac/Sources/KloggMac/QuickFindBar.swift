//
//  QuickFindBar.swift — slim incremental find overlay (Wave 6).
//
//  Mirrors klogg's QuickFindWidget (src/ui/src/quickfindwidget.cpp): a thin bar that
//  drops in over the active log view (Cmd+F) with a text field that finds matches
//  INCREMENTALLY as the user types, navigates next/previous, wraps around, and shows
//  a "no match" / "wrapped" notification. It is DISTINCT from SearchBarView — QuickFind
//  navigates matches in-place in the main view rather than building a filtered list.
//
//  Layout (left to right):
//    [ < ] [ > ] [ Find: ················ ] [ Aa ] [ status label ]   [ × ]
//
//  Callbacks (set by CrawlerTab, which owns the engine + main view):
//    onChange(needle, caseInsensitive)  — text changed: restart incremental find
//    onNext / onPrevious                — Return / Shift-Return or arrow buttons
//    onClose                            — Esc or close button
//

import AppKit

final class QuickFindBar: NSView {

    // MARK: - Callbacks

    var onChange: ((_ needle: String, _ caseInsensitive: Bool) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    // MARK: - Controls

    private let field      = NSTextField()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let caseButton = NSButton()   // Aa — toggle case sensitivity
    private let statusLabel = NSTextField()
    private let closeButton = NSButton()

    // MARK: - State

    /// QuickFind defaults to case-insensitive, like klogg's quickfind.
    private(set) var isCaseInsensitive = true

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeBackground()
    }

    /// Re-resolve the layer background against the current appearance (a frozen
    /// .cgColor would stay dark when the system switches to Light).
    private func applyChromeBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        applyChromeBackground()

        prevButton.translatesAutoresizingMaskIntoConstraints = false
        prevButton.title = "‹"
        prevButton.bezelStyle = .rounded
        prevButton.font = .systemFont(ofSize: 13, weight: .bold)
        prevButton.toolTip = "Previous match (Shift-Return)"
        prevButton.target = self
        prevButton.action = #selector(prevAction(_:))
        addSubview(prevButton)

        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.title = "›"
        nextButton.bezelStyle = .rounded
        nextButton.font = .systemFont(ofSize: 13, weight: .bold)
        nextButton.toolTip = "Next match (Return)"
        nextButton.target = self
        nextButton.action = #selector(nextAction(_:))
        addSubview(nextButton)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Find in view"
        field.focusRingType = .none
        field.delegate = self
        // Live incremental find: fire on each keystroke.
        field.target = self
        field.action = #selector(returnAction(_:))   // Return = next
        addSubview(field)

        caseButton.translatesAutoresizingMaskIntoConstraints = false
        caseButton.title = "Aa"
        caseButton.setButtonType(.toggle)
        caseButton.bezelStyle = .rounded
        caseButton.font = .systemFont(ofSize: 11)
        caseButton.state = isCaseInsensitive ? .on : .off
        caseButton.toolTip = "Case insensitive"
        caseButton.target = self
        caseButton.action = #selector(toggleCase(_:))
        addSubview(caseButton)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.drawsBackground = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""
        addSubview(statusLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.title = "✕"
        closeButton.bezelStyle = .rounded
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 12)
        closeButton.toolTip = "Close (Esc)"
        closeButton.target = self
        closeButton.action = #selector(closeAction(_:))
        addSubview(closeButton)

        let h: CGFloat = 30
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: h),

            prevButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 28),

            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 28),

            field.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            caseButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            caseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            caseButton.widthAnchor.constraint(equalToConstant: 32),

            statusLabel.leadingAnchor.constraint(equalTo: caseButton.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
        ])

        // Bottom separator rule.
        let sep = NSBox()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.boxType = .separator
        addSubview(sep)
        NSLayoutConstraint.activate([
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    // MARK: - Public API

    var needle: String { field.stringValue }

    /// Focus the field and select existing text (so the user can retype immediately).
    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Update the status label. `kind` styles the colour: .info grey, .nomatch red.
    enum StatusKind { case info, nomatch }
    func setStatus(_ text: String, kind: StatusKind = .info) {
        statusLabel.stringValue = text
        statusLabel.textColor = (kind == .nomatch) ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Actions

    @objc private func returnAction(_ sender: Any?) {
        // NSTextField fires its action on Return; the field delegate routes
        // Shift-Return separately, so a plain action means "next".
        onNext?()
    }

    @objc private func nextAction(_ sender: Any?)   { onNext?() }
    @objc private func prevAction(_ sender: Any?)   { onPrevious?() }
    @objc private func closeAction(_ sender: Any?)  { onClose?() }

    @objc private func toggleCase(_ sender: NSButton) {
        isCaseInsensitive = (sender.state == .on)
        // Re-run the find with the new case option.
        onChange?(field.stringValue, isCaseInsensitive)
    }
}

// MARK: - NSTextFieldDelegate (incremental find + key routing)

extension QuickFindBar: NSTextFieldDelegate {

    /// Fires on every keystroke → incremental find.
    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue, isCaseInsensitive)
    }

    /// Intercept Esc (close), Return / Shift-Return (next / previous).
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Distinguish Shift-Return (previous) from Return (next).
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        default:
            return false
        }
    }
}
