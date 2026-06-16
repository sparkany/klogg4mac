//
//  SearchBarView.swift — search toolbar strip between the split log views.
//
//  Layout (left to right, mirrors klogg crawlerwidget.cpp searchLineLayout):
//    [Marks and matches ▾] [Aa] [.*] [≠] [&|] [↻] [filters ▾]
//    [Search field ······] [🔍] [match label] [spinner]
//
//  Toggles map 1:1 to klogg's search-line buttons:
//    Aa = matchCaseButton_ · .* = useRegexpButton_ · ≠ = inverseButton_ ·
//    &| = booleanButton_   · ↻ = searchRefreshButton_ · 🔍 = searchButton_
//
//  Callbacks:
//    onSearch(pattern, caseInsensitive, isRegex, inverse, boolean) — Return / 🔍 tap
//    onCancel()                — spinner (×) tapped
//    onAutoRefreshChanged(on)  — ↻ toggled
//
//  This view does not call the engine directly; CrawlerTab owns the engine and
//  sets the callbacks.
//

import AppKit

/// What the filtered (lower) pane displays. Mirrors klogg's
/// LogFilteredData::VisibilityFlags (Marks / Matches), selected via the
/// "Marks and matches" combobox at the left of the search line
/// (crawlerwidget.cpp: visibilityBox_).
enum FilteredVisibility: Int, CaseIterable {
    case marksAndMatches = 0   // klogg default (Marks | Matches)
    case marks           = 1
    case matches         = 2

    /// The combobox item titles, in klogg's order.
    var title: String {
        switch self {
        case .marksAndMatches: return "Marks and matches"
        case .marks:           return "Marks"
        case .matches:         return "Matches"
        }
    }
}

final class SearchBarView: NSView {

    // MARK: - Callbacks (set by CrawlerTab)

    /// Run a search. `inverse` shows non-matching lines (klogg inverseButton_);
    /// `boolean` parses the pattern as a logical combination (klogg booleanButton_).
    var onSearch: ((_ pattern: String, _ caseInsensitive: Bool, _ isRegex: Bool,
                    _ inverse: Bool, _ boolean: Bool) -> Void)?
    var onCancel: (() -> Void)?
    /// Fired when the user picks a different filtered-view visibility mode.
    var onVisibilityChanged: ((FilteredVisibility) -> Void)?
    /// Fired when the auto-refresh toggle changes (klogg searchRefreshButton_), so the
    /// owner can enable/disable re-running the search as the file grows.
    var onAutoRefreshChanged: ((Bool) -> Void)?

    // MARK: - Controls

    private let visibilityPopup = NSPopUpButton()   // "Marks and matches ▾" view-mode selector
    private let filterPopup   = NSPopUpButton()   // ▾ predefined filters picker
    private let searchField   = NSSearchField()
    private let caseButton    = NSButton()   // Aa — toggle case-sensitive (klogg matchCaseButton_)
    private let regexButton   = NSButton()   // .* — toggle regex (klogg useRegexpButton_)
    private let inverseButton = NSButton()   // ≠  — inverse / exclude match (klogg inverseButton_)
    private let booleanButton = NSButton()   // &| — boolean combination (klogg booleanButton_)
    private let refreshButton = NSButton()   // ↻  — auto-refresh (klogg searchRefreshButton_)
    private let searchButton  = NSButton()   // 🔍 — run the search (klogg searchButton_)
    private let matchLabel    = NSTextField()
    private let spinner       = NSProgressIndicator()

    // MARK: - State

    // Initial toggle states mirror klogg's CrawlerWidgetContext, persisted in
    // AppPreferences. caseInsensitive is the inverse of klogg's matchCase.
    private var isCaseInsensitive: Bool = AppPreferences.shared.searchIgnoreCase
    private var isRegex: Bool = AppPreferences.shared.searchUseRegex
    /// Inverse / exclude match — filtered view shows NON-matching lines.
    private var isInverse: Bool = AppPreferences.shared.searchInverse
    /// Boolean-combination mode — pattern parsed as a logical expression.
    private var isBoolean: Bool = AppPreferences.shared.searchBoolean
    /// Auto-refresh — re-run the search as the file grows (klogg searchRefreshButton_).
    private var isAutoRefresh: Bool = AppPreferences.shared.searchAutoRefresh
    /// Current filtered-view visibility (klogg default: Marks and matches).
    private(set) var visibility: FilteredVisibility = .marksAndMatches

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
        // Rebuild the search-history dropdown when the saved-search list changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(historyChanged),
            name: .savedSearchesDidChange, object: nil)
    }

    @objc private func historyChanged() { rebuildHistoryMenu() }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func filtersChanged() { reloadFilters() }

    // MARK: - Appearance

    /// Re-resolve the layer background against the current appearance.
    private func applyChromeBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeBackground()
    }

    // MARK: - Layout

    private func buildSubviews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Background matches the toolbar area. (Resolved through the current
        // appearance and refreshed on theme change — a frozen .cgColor would stay
        // dark after the user switches the system to Light.)
        wantsLayer = true
        applyChromeBackground()

        // View-mode selector ("Marks and matches ▾"): chooses what the lower pane
        // shows (klogg visibilityBox_). A pop-up (not pull-down) so the current mode
        // shows on the button. Selecting an item re-filters the lower pane.
        visibilityPopup.translatesAutoresizingMaskIntoConstraints = false
        visibilityPopup.pullsDown = false
        visibilityPopup.bezelStyle = .rounded
        visibilityPopup.font = .systemFont(ofSize: 11)
        visibilityPopup.toolTip = "What to show in the filtered view"
        visibilityPopup.target = self
        visibilityPopup.action = #selector(selectVisibility(_:))
        for mode in FilteredVisibility.allCases {
            visibilityPopup.addItem(withTitle: mode.title)
        }
        visibilityPopup.selectItem(at: visibility.rawValue)
        addSubview(visibilityPopup)

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

        // Search-history dropdown (klogg's savedSearches combo). The magnifying-glass
        // template menu lists recent searches; picking one runs it.
        rebuildHistoryMenu()

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

        // Regex toggle button (.*) — klogg useRegexpButton_.
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

        // Inverse / exclude-match toggle (≠) — klogg inverseButton_. When ON the
        // filtered view shows lines that do NOT match.
        inverseButton.translatesAutoresizingMaskIntoConstraints = false
        inverseButton.title = "≠"
        inverseButton.setButtonType(.toggle)
        inverseButton.bezelStyle = .rounded
        inverseButton.font = .systemFont(ofSize: 12)
        inverseButton.state = isInverse ? .on : .off
        inverseButton.toolTip = "Inverse match (show non-matching lines)"
        inverseButton.target = self
        inverseButton.action = #selector(toggleInverse(_:))
        addSubview(inverseButton)

        // Boolean-combination toggle (&|) — klogg booleanButton_. When ON the pattern
        // is parsed as a logical expression: "foo and not(bar)", quoted sub-patterns.
        booleanButton.translatesAutoresizingMaskIntoConstraints = false
        booleanButton.title = "&|"
        booleanButton.setButtonType(.toggle)
        booleanButton.bezelStyle = .rounded
        booleanButton.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        booleanButton.state = isBoolean ? .on : .off
        booleanButton.toolTip = "Enable regular expression logical combining"
        booleanButton.target = self
        booleanButton.action = #selector(toggleBoolean(_:))
        addSubview(booleanButton)

        // Auto-refresh toggle (↻) — klogg searchRefreshButton_. When ON the search
        // re-runs as the file grows (with Follow).
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.title = "↻"
        refreshButton.setButtonType(.toggle)
        refreshButton.bezelStyle = .rounded
        refreshButton.font = .systemFont(ofSize: 12)
        refreshButton.state = isAutoRefresh ? .on : .off
        refreshButton.toolTip = "Auto-refresh search as the file grows"
        refreshButton.target = self
        refreshButton.action = #selector(toggleRefresh(_:))
        addSubview(refreshButton)

        // Search push-button (🔍) — klogg searchButton_. Runs the current pattern,
        // equivalent to pressing Return in the field.
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.title = "🔍"
        searchButton.setButtonType(.momentaryPushIn)
        searchButton.bezelStyle = .rounded
        searchButton.font = .systemFont(ofSize: 11)
        searchButton.toolTip = "Search"
        searchButton.target = self
        searchButton.action = #selector(searchButtonTapped(_:))
        addSubview(searchButton)

        // Match count label ("N matches found.") — right-aligned, klogg searchInfoLine_.
        matchLabel.translatesAutoresizingMaskIntoConstraints = false
        matchLabel.isEditable = false
        matchLabel.isBordered = false
        matchLabel.drawsBackground = false
        matchLabel.alignment = .right
        matchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.stringValue = ""
        matchLabel.lineBreakMode = .byTruncatingTail
        addSubview(matchLabel)

        // Spinner (hidden until a search is running).
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        // Height: compact — 28 pt like a toolbar.
        // Layout (klogg searchLineLayout order, left→right): view-mode selector,
        // Aa, .*, predefined-filters ▾, search field, then the right-aligned
        // "N matches found." label + spinner.
        let height: CGFloat = 28
        let matchTrailing = matchLabel.trailingAnchor.constraint(
            equalTo: spinner.leadingAnchor, constant: -6)
        // Let the match label shrink before the search field does.
        matchLabel.setContentHuggingPriority(.required, for: .horizontal)
        matchLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),

            // Left cluster: view-mode | Aa | .* | filters ▾
            visibilityPopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            visibilityPopup.centerYAnchor.constraint(equalTo: centerYAnchor),
            visibilityPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

            caseButton.leadingAnchor.constraint(equalTo: visibilityPopup.trailingAnchor, constant: 6),
            caseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            caseButton.widthAnchor.constraint(equalToConstant: 32),

            regexButton.leadingAnchor.constraint(equalTo: caseButton.trailingAnchor, constant: 4),
            regexButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            regexButton.widthAnchor.constraint(equalToConstant: 32),

            inverseButton.leadingAnchor.constraint(equalTo: regexButton.trailingAnchor, constant: 4),
            inverseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            inverseButton.widthAnchor.constraint(equalToConstant: 30),

            booleanButton.leadingAnchor.constraint(equalTo: inverseButton.trailingAnchor, constant: 4),
            booleanButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            booleanButton.widthAnchor.constraint(equalToConstant: 32),

            refreshButton.leadingAnchor.constraint(equalTo: booleanButton.trailingAnchor, constant: 4),
            refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 30),

            filterPopup.leadingAnchor.constraint(equalTo: refreshButton.trailingAnchor, constant: 6),
            filterPopup.centerYAnchor.constraint(equalTo: centerYAnchor),
            filterPopup.widthAnchor.constraint(equalToConstant: 44),

            // Search field stretches to the search push-button.
            searchField.leadingAnchor.constraint(equalTo: filterPopup.trailingAnchor, constant: 6),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -4),

            searchButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchButton.trailingAnchor.constraint(equalTo: matchLabel.leadingAnchor, constant: -8),
            searchButton.widthAnchor.constraint(equalToConstant: 34),

            // Right cluster: "N matches found." + spinner.
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            matchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            matchTrailing,
            matchLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
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
        runSearch(sender.stringValue)
    }

    @objc private func searchButtonTapped(_ sender: NSButton) {
        runSearch(searchField.stringValue)
    }

    /// Record the pattern in the recent-search history (klogg addRecent) and fire the
    /// search with the current toggle states. Shared by Return, the search button, and
    /// the history menu.
    private func runSearch(_ raw: String) {
        let pattern = raw.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        SavedSearchesStore.shared.addRecent(pattern)
        onSearch?(pattern, isCaseInsensitive, isRegex, isInverse, isBoolean)
    }

    // MARK: - Search history dropdown (klogg savedSearches)

    /// Rebuild the search field's dropdown menu to list recent searches. The first item
    /// is a non-selectable "Recent searches" header; each recent search runs on click;
    /// a trailing "Clear history" wipes the store.
    private func rebuildHistoryMenu() {
        let menu = NSMenu()
        let recents = SavedSearchesStore.shared.recentSearches()
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No recent searches", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Recent searches", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for r in recents {
                let item = NSMenuItem(title: r, action: #selector(selectHistory(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = r
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear history", action: #selector(clearHistory(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
        (searchField.cell as? NSSearchFieldCell)?.searchMenuTemplate = menu
    }

    @objc private func selectHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        searchField.stringValue = text
        onSearch?(text, isCaseInsensitive, isRegex, isInverse, isBoolean)
    }

    @objc private func clearHistory(_ sender: NSMenuItem) {
        SavedSearchesStore.shared.clear()
    }

    @objc private func toggleCase(_ sender: NSButton) {
        isCaseInsensitive = (sender.state == .on)
        AppPreferences.shared.searchIgnoreCase = isCaseInsensitive
    }

    @objc private func toggleRegex(_ sender: NSButton) {
        isRegex = (sender.state == .on)
        AppPreferences.shared.searchUseRegex = isRegex
    }

    @objc private func toggleInverse(_ sender: NSButton) {
        isInverse = (sender.state == .on)
        AppPreferences.shared.searchInverse = isInverse
    }

    @objc private func toggleBoolean(_ sender: NSButton) {
        isBoolean = (sender.state == .on)
        AppPreferences.shared.searchBoolean = isBoolean
    }

    @objc private func toggleRefresh(_ sender: NSButton) {
        isAutoRefresh = (sender.state == .on)
        AppPreferences.shared.searchAutoRefresh = isAutoRefresh
        onAutoRefreshChanged?(isAutoRefresh)
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
        onSearch?(filter.pattern, isCaseInsensitive, isRegex, isInverse, isBoolean)
    }

    // MARK: - Public API (called by CrawlerTab delegate methods)

    /// The text currently in the search field (for add/exclude combination).
    var currentPattern: String { searchField.stringValue }

    /// Whether regex mode is currently on.
    var isRegexMode: Bool { isRegex }

    /// Whether boolean-combination mode is currently on (klogg booleanButton_).
    var isBooleanMode: Bool { isBoolean }

    /// Force boolean-combination mode on/off and reflect it in the toggle. Used by the
    /// context-menu "Exclude from search", which switches klogg into boolean mode.
    func setBooleanMode(_ on: Bool) {
        isBoolean = on
        booleanButton.state = on ? .on : .off
        AppPreferences.shared.searchBoolean = on
    }

    /// Set the field to `pattern` (with explicit regex/case flags) and run the search.
    /// Used by the log-view context menu's Replace/Add/Exclude-search actions. Honours
    /// the CURRENT inverse + boolean toggle states (klogg replaceCurrentSearch reads the
    /// live button states, including any change the action made via setBooleanMode).
    func setSearchAndRun(pattern: String, isRegex: Bool, caseInsensitive: Bool) {
        searchField.stringValue = pattern
        self.isRegex = isRegex
        self.isCaseInsensitive = caseInsensitive
        regexButton.state = isRegex ? .on : .off
        caseButton.state = caseInsensitive ? .on : .off
        guard !pattern.isEmpty else { return }
        onSearch?(pattern, caseInsensitive, isRegex, isInverse, isBoolean)
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

    /// Show the "Error in expression" message in red (klogg searchInfoLine_ ErrorPalette).
    /// Used when the pattern fails to compile (invalid regex / boolean expression).
    func showSearchError() {
        matchLabel.stringValue = "Error in expression"
        matchLabel.textColor = .systemRed
    }

    /// Update the match-count label.
    /// - Parameters:
    ///   - count: Number of matches found so far.
    ///   - finished: True when search has completed; false for interim progress.
    func updateMatchCount(_ count: Int, finished: Bool) {
        // klogg's searchInfoLine_ text: "N matches found." (singular "1 match found.").
        if count == 0 && !finished {
            matchLabel.stringValue = ""
        } else if finished {
            matchLabel.stringValue = count == 1 ? "1 match found." : "\(count) matches found."
            matchLabel.textColor = count == 0 ? .systemRed : .secondaryLabelColor
        } else {
            matchLabel.stringValue = "\(count)…"
            matchLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Filtered-view visibility (klogg visibilityBox_)

    @objc private func selectVisibility(_ sender: NSPopUpButton) {
        guard let mode = FilteredVisibility(rawValue: sender.indexOfSelectedItem) else { return }
        visibility = mode
        onVisibilityChanged?(mode)
    }

    /// Programmatically set the filtered-view visibility mode (headless tests +
    /// menu wiring). Updates the button and fires the change callback.
    func setVisibility(_ mode: FilteredVisibility) {
        visibility = mode
        visibilityPopup.selectItem(at: mode.rawValue)
        onVisibilityChanged?(mode)
    }

    /// Current match-count label text (headless assertions).
    var selfTestMatchLabelText: String { matchLabel.stringValue }

    // MARK: - Toggle state (headless + programmatic)

    /// Set the inverse toggle and reflect it in the button (headless tests + menu wiring).
    func setInverse(_ on: Bool) {
        isInverse = on
        inverseButton.state = on ? .on : .off
        AppPreferences.shared.searchInverse = on
    }

    /// Set the auto-refresh toggle and reflect it (headless + menu). Fires the callback.
    func setAutoRefresh(_ on: Bool) {
        isAutoRefresh = on
        refreshButton.state = on ? .on : .off
        AppPreferences.shared.searchAutoRefresh = on
        onAutoRefreshChanged?(on)
    }

    var selfTestInverse: Bool { isInverse }
    var selfTestBoolean: Bool { isBoolean }
    var selfTestAutoRefresh: Bool { isAutoRefresh }

    /// Empty the search field (headless: start a combine sequence from a clean field).
    func clearFieldForTest() { searchField.stringValue = "" }
}
