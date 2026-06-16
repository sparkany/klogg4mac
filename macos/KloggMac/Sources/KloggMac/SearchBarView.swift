//
//  SearchBarView.swift — search toolbar strip above the split log views.
//
//  Layout (left to right):
//    [Search field ···········] [Aa case] [.* regex] [match label] [spinner]
//
//  Callbacks:
//    onSearch(pattern, caseInsensitive, isRegex)  — called on Return / button tap
//    onCancel()                                   — called when spinner (× button) tapped
//
//  This view does not call the engine directly; CrawlerTab owns the engine and
//  sets the callbacks.
//

import AppKit

final class SearchBarView: NSView {

    // MARK: - Callbacks (set by CrawlerTab)

    var onSearch: ((_ pattern: String, _ caseInsensitive: Bool, _ isRegex: Bool) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Controls

    private let filterPopup   = NSPopUpButton()   // ▾ predefined filters picker
    private let searchField   = NSSearchField()
    private let caseButton    = NSButton()   // Aa — toggle case-sensitive
    private let regexButton   = NSButton()   // .* — toggle regex
    private let matchLabel    = NSTextField()
    private let spinner       = NSProgressIndicator()

    // MARK: - State

    private var isCaseInsensitive: Bool = true   // matches klogg default
    private var isRegex: Bool = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildSubviews()
        // Rebuild the picker whenever the stored filters change. Use the broadcast
        // notification (not the store's single onChange closure) so EVERY open tab's
        // picker refreshes — the closure can only have one subscriber, and with multiple
        // tabs only the last-created SearchBarView would have won it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(filtersChanged),
            name: .predefinedFiltersDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func filtersChanged() { reloadFilters() }

    // MARK: - Layout

    private func buildSubviews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Background matches the toolbar area.
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Predefined-filters picker (▾). The first item is a static title; choosing a
        // filter fills the field with its pattern + flags and runs the search.
        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        filterPopup.pullsDown = true            // title item stays put; acts as a menu
        filterPopup.bezelStyle = .rounded
        filterPopup.font = .systemFont(ofSize: 11)
        filterPopup.toolTip = "Predefined filters"
        filterPopup.target = self
        filterPopup.action = #selector(selectFilter(_:))
        addSubview(filterPopup)
        reloadFilters()

        // Search field.
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search (regex / plain text)"
        searchField.sendsSearchStringImmediately = false
        searchField.target = self
        searchField.action = #selector(searchAction(_:))
        addSubview(searchField)

        // Case-insensitive toggle button (Aa).
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

        // Regex toggle button (.*).
        regexButton.translatesAutoresizingMaskIntoConstraints = false
        regexButton.title = ".*"
        regexButton.setButtonType(.toggle)
        regexButton.bezelStyle = .rounded
        regexButton.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        regexButton.state = isRegex ? .on : .off
        regexButton.toolTip = "Regular expression"
        regexButton.target = self
        regexButton.action = #selector(toggleRegex(_:))
        addSubview(regexButton)

        // Match count label.
        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.isEditable = false
        matchLabel.isBordered = false
        matchLabel.drawsBackground = false
        matchLabel.alignment = .left
        matchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.stringValue = ""
        addSubview(matchLabel)

        // Spinner (hidden until a search is running).
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        // Height: compact — 28 pt like a toolbar.
        let height: CGFloat = 28
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),

            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            matchLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -6),
            matchLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            regexButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            regexButton.trailingAnchor.constraint(equalTo: matchLabel.leadingAnchor, constant: -6),
            regexButton.widthAnchor.constraint(equalToConstant: 32),

            caseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            caseButton.trailingAnchor.constraint(equalTo: regexButton.leadingAnchor, constant: -4),
            caseButton.widthAnchor.constraint(equalToConstant: 32),

            filterPopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filterPopup.centerYAnchor.constraint(equalTo: centerYAnchor),
            filterPopup.widthAnchor.constraint(equalToConstant: 44),

            searchField.leadingAnchor.constraint(equalTo: filterPopup.trailingAnchor, constant: 6),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: caseButton.leadingAnchor, constant: -8),
        ])

        // Bottom separator line.
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

    // MARK: - Actions

    @objc private func searchAction(_ sender: NSSearchField) {
        let pattern = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        onSearch?(pattern, isCaseInsensitive, isRegex)
    }

    @objc private func toggleCase(_ sender: NSButton) {
        isCaseInsensitive = (sender.state == .on)
    }

    @objc private func toggleRegex(_ sender: NSButton) {
        isRegex = (sender.state == .on)
    }

    // MARK: - Predefined filters

    /// Rebuild the picker menu from PredefinedFilterStore. A pull-down popup keeps its
    /// first item as the (non-selectable) title; stored filters follow.
    func reloadFilters() {
        filterPopup.removeAllItems()
        // Title item (shown on the button; ▾ glyph kept by the bezel).
        filterPopup.addItem(withTitle: "▾")
        for filter in PredefinedFilterStore.shared.filters {
            filterPopup.addItem(withTitle: filter.name.isEmpty ? filter.pattern : filter.name)
        }
        filterPopup.isEnabled = !PredefinedFilterStore.shared.filters.isEmpty
    }

    /// A predefined filter was chosen: load its pattern + flags into the field and run.
    @objc private func selectFilter(_ sender: NSPopUpButton) {
        // Index 0 is the title; stored filters start at 1.
        let idx = sender.indexOfSelectedItem - 1
        let filters = PredefinedFilterStore.shared.filters
        guard idx >= 0, idx < filters.count else { return }
        applyFilter(filters[idx])
    }

    /// Load a filter's pattern + flags into the controls and trigger a search.
    /// Exposed so the headless harness can drive the same code path as a menu pick.
    func applyFilter(_ filter: PredefinedFilter) {
        searchField.stringValue = filter.pattern
        isRegex = filter.useRegex
        isCaseInsensitive = filter.ignoreCase
        regexButton.state = isRegex ? .on : .off
        caseButton.state = isCaseInsensitive ? .on : .off
        guard !filter.pattern.isEmpty else { return }
        onSearch?(filter.pattern, isCaseInsensitive, isRegex)
    }

    // MARK: - Public API (called by CrawlerTab delegate methods)

    /// The text currently in the search field (for add/exclude combination).
    var currentPattern: String { searchField.stringValue }

    /// Whether regex mode is currently on.
    var isRegexMode: Bool { isRegex }

    /// Set the field to `pattern` (with explicit regex/case flags) and run the search.
    /// Used by the log-view context menu's Replace/Add/Exclude-search actions.
    func setSearchAndRun(pattern: String, isRegex: Bool, caseInsensitive: Bool) {
        searchField.stringValue = pattern
        self.isRegex = isRegex
        self.isCaseInsensitive = caseInsensitive
        regexButton.state = isRegex ? .on : .off
        caseButton.state = caseInsensitive ? .on : .off
        guard !pattern.isEmpty else { return }
        onSearch?(pattern, caseInsensitive, isRegex)
    }

    /// Move keyboard focus to the search text field.
    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    /// Show or hide the spinner.
    func showProgress(_ running: Bool) {
        if running {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    /// Update the match-count label.
    /// - Parameters:
    ///   - count: Number of matches found so far.
    ///   - finished: True when search has completed; false for interim progress.
    func updateMatchCount(_ count: Int, finished: Bool) {
        if count == 0 && !finished {
            matchLabel.stringValue = ""
        } else if finished {
            matchLabel.stringValue = count == 1 ? "1 match" : "\(count) matches"
            matchLabel.textColor = count == 0 ? .systemRed : .secondaryLabelColor
        } else {
            matchLabel.stringValue = "\(count)…"
            matchLabel.textColor = .secondaryLabelColor
        }
    }
}
