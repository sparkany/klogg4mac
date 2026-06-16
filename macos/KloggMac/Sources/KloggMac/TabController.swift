//
//  TabController.swift — Multi-tab host (mirrors klogg's TabbedCrawlerWidget).
//
//  Each tab is a CrawlerTab: one KloggEngine + a vertical NSSplitView hosting
//  two LogScrollView instances (main view on top, filtered view below).
//  The tab bar uses NSTabView (topTabsBezelBorder), which gives native macOS tabs.
//
//  Public API:
//    openFile(path:)        — open in a new tab (or activate existing)
//    closeCurrentTab()      — close the active tab
//    closeAllTabs()         — close every tab
//    currentFilePath        — path of the active tab's file (nil if none open)
//    currentLineCount       — line count of the active tab's engine
//    statusBar              — the StatusBarView to update on changes
//    _tabs                  — ordered list of CrawlerTabs (read by MainWindowController)
//

import AppKit
import KloggBridge

// MARK: - CrawlerTab

/// One tab: an engine + search bar + split-view hosting main log view + filtered view.
final class CrawlerTab: NSViewController, KloggEngineDelegate {

    let engine: KloggEngine
    /// Path the engine actually indexes. For compressed logs this is a decompressed
    /// temp file; for ordinary files it equals `displayPath`.
    let filePath: String
    /// Original path shown to the user (tab label, recents, favorites, marks key).
    /// Differs from `filePath` only when the source was a compressed archive.
    let displayPath: String
    let mainView: LogScrollView
    let filteredView: LogScrollView
    private let searchBar = SearchBarView()

    /// Per-file line marks (bookmarks), shared by the main + filtered views (marks are
    /// keyed by SOURCE line). Persisted per file path; isolated under --selftest.
    let marksStore: MarksStore

    /// Set by TabController so context-menu "Send to scratchpad" reaches the shared
    /// scratchpad window. Returns the scratchpad controller (lazily shown).
    var scratchpadProvider: (() -> ScratchpadWindowController?)?

    // Overview minimap (Wave 8): a thin strip to the right of the log split showing
    // the whole file with search-match positions. Width toggles 0/stripWidth.
    private let overview = OverviewView()
    private var overviewWidth: NSLayoutConstraint?
    /// Whether the overview strip is visible (persisted in AppPreferences).
    private(set) var isOverviewVisible = AppPreferences.shared.overviewVisible

    // QuickFind (Wave 6): an incremental in-place find bar over the main view.
    private let quickFindBar = QuickFindBar()
    private lazy var quickFind = QuickFindController(engine: engine)
    /// Top constraint of the QuickFind bar; toggled to slide it in/out.
    private var quickFindHeight: NSLayoutConstraint?

    // Callbacks fired on the main thread.
    var onLoadingFinished: ((CrawlerTab, Bool) -> Void)?
    var onLoadingProgress: ((CrawlerTab, Int) -> Void)?
    /// Fired when the main view's current line changes (0-based) so the owner can
    /// update the status bar's "Ln:N/Total" field (klogg lineNumberHandler).
    var onMainLineChanged: ((Int) -> Void)?

    /// Follow (tail -f) mode. When ON the engine watches the file for growth and we
    /// auto-scroll the main view to the tail whenever a re-index finishes.
    private(set) var isFollowing = false

    init(filePath: String, displayPath: String? = nil) {
        self.filePath = filePath
        self.displayPath = displayPath ?? filePath
        self.engine = KloggEngine()
        self.mainView     = LogScrollView(engine: engine, mode: .main)
        self.filteredView = LogScrollView(engine: engine, mode: .filtered)
        // Marks are keyed by the user-facing path so they survive across the
        // (regenerated) decompression temp file on reopen.
        self.marksStore   = MarksStore(filePath: self.displayPath)
        super.init(nibName: nil, bundle: nil)
        engine.delegate = self

        // Both views draw + toggle the same per-file marks (by source line).
        mainView.marksStore = marksStore
        filteredView.marksStore = marksStore
        // Default save-to-file name derives from the user-facing file name.
        let baseName = (self.displayPath as NSString).lastPathComponent
        mainView.sourceName = baseName
        filteredView.sourceName = baseName
        // Repaint both views when marks change (e.g. toggled from the other view).
        NotificationCenter.default.addObserver(self, selector: #selector(marksChanged),
                                               name: .marksDidChange, object: marksStore)

        // Live updates: when highlighter rules or preferences change, both log
        // views must rebuild compiled rules / re-resolve font / repaint.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(highlightersChanged),
                       name: .highlightersDidChange, object: nil)
        nc.addObserver(self, selector: #selector(highlightersChanged),
                       name: .colorLabelsDidChange, object: nil)
        nc.addObserver(self, selector: #selector(preferencesChanged),
                       name: .preferencesDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func highlightersChanged() {
        mainView.applyHighlighters()
        filteredView.applyHighlighters()
    }

    @objc private func marksChanged() {
        mainView.refresh()
        // When the lower pane includes marks, its content set changed — recompute it.
        if searchBar.visibility != .matches {
            recomputeFilteredVisibility()
        } else {
            filteredView.refresh()
            // Marks moved but the filtered set didn't — still repaint the scrollbar
            // markers so the main-view marks show/clear on the trough.
            refreshScrollbarMarkers()
        }
    }

    /// Build the context-menu action set both views share (search + scratchpad).
    /// Search combination mirrors klogg's replace/add/exclude semantics, expressed as
    /// regex against our engine (replace=literal; add=alternation; exclude=lookahead).
    private func makeContextActions() -> LogViewContextActions {
        var actions = LogViewContextActions()
        // Replace / Add / Exclude mirror klogg's CrawlerWidget exactly (crawlerwidget.cpp
        // replaceSearch / addToSearch / excludeFromSearch). klogg combines patterns using
        // its boolean-expression layer ("foo or bar", "foo and not(bar)") or regex
        // alternation ("foo|bar"), driven by the live regex/boolean toggle states — NOT
        // ad-hoc lookahead. The engine's RegularExpression understands these natively.
        actions.replaceSearch     = { [weak self] text in self?.replaceSearch(text) }
        actions.addToSearch       = { [weak self] text in self?.addToSearch(text) }
        actions.excludeFromSearch = { [weak self] text in self?.excludeFromSearch(text) }
        actions.setSearchStart = { [weak self] line in
            self?.setSearchStart(line: line)
        }
        actions.setSearchEnd = { [weak self] line in
            self?.setSearchEnd(line: line)
        }
        actions.clearSearchLimits = { [weak self] in
            self?.clearSearchLimits()
        }
        actions.sendToScratchpad = { [weak self] text in
            guard let self = self, !text.isEmpty else { return }
            self.scratchpadProvider?()?.appendText(text)
        }
        actions.replaceScratchpad = { [weak self] text in
            guard let self = self, !text.isEmpty else { return }
            self.scratchpadProvider?()?.replaceText(text)
        }
        return actions
    }

    @objc private func preferencesChanged() {
        // Font change (relayout) + view prefs (line numbers / ANSI / text wrap) + repaint.
        mainView.applyFontPreference()
        filteredView.applyFontPreference()
        mainView.applyViewPreferences()
        filteredView.applyViewPreferences()
        // The variate-highlight-colours preference affects compiled highlight spans.
        mainView.applyHighlighters()
        filteredView.applyHighlighters()
        // Keep the recent-file / search-history caps in sync with the prefs.
        RecentFiles.shared.applyMaxCount()
        SavedSearchesStore.shared.applyMaxHistory()
        // Re-apply (or clear) the main-view search wash now that the
        // highlightSearchInMain preference may have changed.
        if let s = lastSearch {
            mainView.setSearchHighlight(pattern: s.pattern,
                                        caseInsensitive: s.caseInsensitive,
                                        isRegex: s.isRegex)
        }
    }

    override func loadView() {
        // klogg's CrawlerWidget splitter: the main log view on top, and a "bottom
        // window" below that stacks the search/filter line ON TOP of the filtered
        // view (crawlerwidget.cpp: addWidget(logMainView_); addWidget(bottomWindow)
        // where bottomWindow = [searchLineLayout, tabbedFilteredView_]). So the search
        // bar is the divider area between the two panes, not above the whole split.
        let split = NSSplitView(frame: .zero)
        split.isVertical = false      // stacked: main above, bottom window below
        split.dividerStyle = .thin

        // Bottom window: search/filter bar on top of the filtered view.
        let bottomPane = NSView(frame: .zero)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        quickFindBar.translatesAutoresizingMaskIntoConstraints = false
        filteredView.translatesAutoresizingMaskIntoConstraints = false
        bottomPane.addSubview(searchBar)
        bottomPane.addSubview(filteredView)

        // QuickFind bar floats over the MAIN view (Cmd+F), so host it in the main
        // pane's container. We wrap the main view so the QuickFind bar can slide in
        // above it without disturbing the split.
        let topPane = NSView(frame: .zero)
        mainView.translatesAutoresizingMaskIntoConstraints = false
        topPane.addSubview(quickFindBar)
        topPane.addSubview(mainView)

        split.addArrangedSubview(topPane)
        split.addArrangedSubview(bottomPane)
        split.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: .zero)
        container.addSubview(split)
        container.addSubview(overview)

        // QuickFind bar is collapsed to zero height (hidden) until Cmd+F.
        let qfHeight = quickFindBar.heightAnchor.constraint(equalToConstant: 0)
        quickFindHeight = qfHeight
        quickFindBar.isHidden = true

        // Overview strip: pinned to the trailing edge, spanning the split's height.
        let ovWidth = overview.widthAnchor.constraint(
            equalToConstant: isOverviewVisible ? OverviewView.stripWidth : 0)
        overviewWidth = ovWidth
        overview.isHidden = !isOverviewVisible

        NSLayoutConstraint.activate([
            // Top pane: QuickFind bar (collapsible) above the main view.
            quickFindBar.topAnchor.constraint(equalTo: topPane.topAnchor),
            quickFindBar.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            quickFindBar.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            qfHeight,
            mainView.topAnchor.constraint(equalTo: quickFindBar.bottomAnchor),
            mainView.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            mainView.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            mainView.bottomAnchor.constraint(equalTo: topPane.bottomAnchor),

            // Bottom pane: search/filter bar above the filtered view.
            searchBar.topAnchor.constraint(equalTo: bottomPane.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: bottomPane.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: bottomPane.trailingAnchor),
            filteredView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            filteredView.leadingAnchor.constraint(equalTo: bottomPane.leadingAnchor),
            filteredView.trailingAnchor.constraint(equalTo: bottomPane.trailingAnchor),
            filteredView.bottomAnchor.constraint(equalTo: bottomPane.bottomAnchor),

            // Split fills the container, leaving room for the overview strip.
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: overview.leadingAnchor),

            overview.topAnchor.constraint(equalTo: split.topAnchor),
            overview.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            overview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ovWidth,
        ])
        self.view = container

        wireOverview()
        wireQuickFind()

        // Apply the persisted text-wrap preference to both views on load.
        mainView.applyTextWrapPreference()
        filteredView.applyTextWrapPreference()

        // Defer the divider position until the view has a real size.
        DispatchQueue.main.async { [weak split] in
            guard let split = split, split.bounds.height > 0 else { return }
            split.setPosition(split.bounds.height * 0.7, ofDividerAt: 0)
        }

        // Wire search bar actions.
        searchBar.onSearch = { [weak self] pattern, caseInsensitive, isRegex, inverse, boolean in
            self?.startSearch(pattern: pattern,
                              caseInsensitive: caseInsensitive,
                              isRegex: isRegex,
                              inverse: inverse,
                              boolean: boolean)
        }
        searchBar.onCancel = { [weak self] in
            self?.engine.cancel()
        }
        // Auto-refresh toggle (klogg searchRefreshButton_): remember the state so a
        // file-growth re-index re-runs the search.
        searchBar.onAutoRefreshChanged = { [weak self] on in
            self?.isSearchAutoRefresh = on
        }
        isSearchAutoRefresh = AppPreferences.shared.searchAutoRefresh
        // Filtered-view visibility mode (klogg visibilityBox_): recompute what the
        // lower pane shows (Matches / Marks / Marks and matches).
        searchBar.onVisibilityChanged = { [weak self] _ in
            self?.recomputeFilteredVisibility()
        }

        // Scrolling the main view repositions the overview's viewport indicator.
        mainView.onScroll = { [weak self] in self?.refreshOverviewViewport() }

        // Clicking a filtered-view row jumps the main view to the matching source line.
        // sourceLine(forRow:) honours the current visibility mode (match index OR the
        // explicit source-line list for Marks / Marks-and-matches).
        filteredView.onLineSelected = { [weak self] row in
            guard let self = self else { return }
            let sourceLine = self.filteredView.sourceLine(forRow: row)
            guard sourceLine >= 0 else { return }
            self.mainView.scrollToLine(sourceLine)
        }

        // Wire the klogg-style log-view context menu (search/scratchpad) on both views.
        let actions = makeContextActions()
        mainView.contextActions = actions
        filteredView.contextActions = actions

        // Clicking a line in the main view updates the status bar position field.
        mainView.onLineSelected = { [weak self] line in
            self?.onMainLineChanged?(line)
        }
    }

    // MARK: - Overview minimap (Wave 8)

    private func wireOverview() {
        overview.matchLineAt = { [weak self] i in
            guard let self = self else { return -1 }
            let src = self.engine.searchMatchLine(at: UInt(i))
            return src == UInt.max ? -1 : Int(src)
        }
        overview.onScrollToLine = { [weak self] line in
            self?.mainView.scrollToLine(line)
            self?.refreshOverviewViewport()
        }
        refreshOverview()
    }

    /// Show/hide the overview strip; persists the preference. Returns the new state.
    @discardableResult
    func setOverviewVisible(_ visible: Bool) -> Bool {
        isOverviewVisible = visible
        AppPreferences.shared.overviewVisible = visible
        overview.isHidden = !visible
        overviewWidth?.constant = visible ? OverviewView.stripWidth : 0
        if visible { refreshOverview() }
        return visible
    }

    /// Recompute the overview from the engine (file height + match count).
    func refreshOverview() {
        overview.reload(totalLines: Int(engine.lineCount()),
                        matchCount: Int(engine.searchMatchCount()))
        refreshOverviewViewport()
    }

    /// Update the overview's "you are here" indicator from the main view's position.
    private func refreshOverviewViewport() {
        overview.viewportFirstLine = mainView.firstVisibleLine
        overview.viewportLineCount = mainView.visibleLineCount
    }

    // MARK: - Scrollbar markers (klogg scrollbar overview)

    /// Repaint the match/mark tick markers on both views' vertical scrollbars.
    ///
    /// The MAIN view's trough spans the whole file; we plot every search match (yellow)
    /// plus every mark (blue) by source line. The FILTERED view's trough spans its own
    /// rows; each row is a hit, so we plot a tick per row (red for a match, blue for a
    /// marked line). O(matches + marks).
    func refreshScrollbarMarkers() {
        let total = Int(engine.lineCount())
        let matchColor = NSColor.systemYellow
        let markColor  = NSColor.systemBlue

        // Main view: matches + marks over the full file height.
        var mainMarkers: [MarkerScroller.Marker] = []
        let n = Int(engine.searchMatchCount())
        mainMarkers.reserveCapacity(n + marksStore.marks.count)
        for i in 0 ..< n {
            let src = engine.searchMatchLine(at: UInt(i))
            if src != UInt.max { mainMarkers.append(.init(line: Int(src), color: matchColor)) }
        }
        for m in marksStore.marks {
            mainMarkers.append(.init(line: m, color: markColor))
        }
        mainView.setScrollbarMarkers(mainMarkers, total: total)

        // Filtered view: one tick per visible row, over the filtered row count.
        let rows = filteredView.lineCount
        var filteredMarkers: [MarkerScroller.Marker] = []
        filteredMarkers.reserveCapacity(rows)
        for r in 0 ..< rows {
            let src = filteredView.sourceLine(forRow: r)
            let isMark = marksStore.isMarked(src)
            filteredMarkers.append(.init(line: r, color: isMark ? markColor : NSColor.systemRed))
        }
        filteredView.setScrollbarMarkers(filteredMarkers, total: max(1, rows))
    }

    // MARK: - Search

    private func startSearch(pattern: String, caseInsensitive: Bool, isRegex: Bool,
                             inverse: Bool = false, boolean: Bool = false) {
        // Validate the expression first (klogg replaceCurrentSearch isValid() gate). On
        // an invalid pattern, surface the error in the label instead of running.
        if !engine.isValidSearchPattern(pattern, regex: isRegex, boolean: boolean) {
            searchBar.showProgress(false)
            searchBar.showSearchError()
            return
        }
        searchBar.showProgress(true)
        // Remember the active search so it can be re-applied as the main-view highlight
        // wash when the search finishes, and re-run on file growth (auto-refresh).
        lastSearch = (pattern, caseInsensitive, isRegex, inverse, boolean)
        // Apply the main-view highlight immediately so hits are visible while the
        // filtered index is still building. (Inverse hides nothing in the main view —
        // it only changes which lines populate the filtered pane — so we still wash the
        // literal matches there, matching klogg's logMainView_->setSearchPattern.)
        mainView.setSearchHighlight(pattern: pattern,
                                    caseInsensitive: caseInsensitive,
                                    isRegex: isRegex)
        engine.search(withPattern: pattern,
                      caseInsensitive: caseInsensitive,
                      regex: isRegex,
                      inverse: inverse,
                      boolean: boolean,
                      startLine: UInt(searchStartLine),
                      endLine: searchEndLine == Int.max ? UInt.max : UInt(searchEndLine))
    }

    /// The pattern/options of the most recent search, kept so preference changes
    /// (toggling highlightSearchInMain) can re-apply or clear the main-view wash, and
    /// auto-refresh can re-run the same search after the file grows.
    private var lastSearch: (pattern: String, caseInsensitive: Bool, isRegex: Bool,
                             inverse: Bool, boolean: Bool)?

    /// Auto-refresh state (klogg searchRefreshButton_ → searchState_.setAutorefresh).
    /// When ON, a file-growth re-index re-runs the last search.
    private var isSearchAutoRefresh = false

    // MARK: - Search range limits (klogg searchStartLine_ / searchEndLine_)

    /// First 0-based source line to search (inclusive). Default 0 = start of file.
    private(set) var searchStartLine = 0
    /// One past the last source line to search (exclusive). Int.max = end of file.
    private(set) var searchEndLine = Int.max

    /// Set the search start limit (klogg AbstractLogView::setSearchStart →
    /// CrawlerWidget::setSearchLimits). Re-runs the current search if there is one.
    func setSearchStart(line: Int) {
        searchStartLine = max(0, line)
        mainView.setSearchLimitLines(start: searchStartLine, end: searchEndLine)
        filteredView.setSearchLimitLines(start: searchStartLine, end: searchEndLine)
        rerunLastSearch()
    }

    /// Set the search end limit (klogg setSearchEnd: selected line + 1, exclusive).
    func setSearchEnd(line: Int) {
        searchEndLine = line + 1
        mainView.setSearchLimitLines(start: searchStartLine, end: searchEndLine)
        filteredView.setSearchLimitLines(start: searchStartLine, end: searchEndLine)
        rerunLastSearch()
    }

    /// Clear the search-range limits (klogg clearSearchLimits → whole file).
    func clearSearchLimits() {
        searchStartLine = 0
        searchEndLine = Int.max
        mainView.setSearchLimitLines(start: 0, end: Int.max)
        filteredView.setSearchLimitLines(start: 0, end: Int.max)
        rerunLastSearch()
    }

    /// Re-run the last search with the current range/options (used after a range change
    /// or a file-growth auto-refresh).
    private func rerunLastSearch() {
        guard let s = lastSearch else { return }
        startSearch(pattern: s.pattern, caseInsensitive: s.caseInsensitive,
                    isRegex: s.isRegex, inverse: s.inverse, boolean: s.boolean)
    }

    // MARK: - klogg pattern combination (crawlerwidget.cpp escapeSearchPattern/combinePatterns)

    /// klogg escapeSearchPattern: escape the term for regex when regex-mode is on but the
    /// term is meant literally, and quote it when boolean mode is on (so a multi-word
    /// term is a single boolean sub-expression).
    private func escapeSearchPattern(_ pattern: String) -> String {
        var escaped = searchBar.isRegexMode
            ? NSRegularExpression.escapedPattern(for: pattern)
            : pattern
        if searchBar.isBooleanMode {
            // klogg escapeSearchPattern: escapedPattern.replace('"', "\"").prepend('"').append('"')
            escaped = "\"" + escaped.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return escaped
    }

    /// klogg combinePatterns: join the existing pattern with a new one using " or "
    /// (boolean mode) or "|" (regex mode), else just concatenate.
    private func combinePatterns(_ current: String, _ newPattern: String) -> String {
        var result = current
        if !result.isEmpty {
            if searchBar.isBooleanMode {
                result += " or "
            } else if searchBar.isRegexMode {
                result += "|"
            }
        }
        result += newPattern
        return result
    }

    /// klogg setSearchPattern: load the combined pattern into the field and run it,
    /// honouring the live regex/boolean/case toggle states.
    private func runCombinedSearch(_ pattern: String) {
        searchBar.setSearchAndRun(pattern: pattern,
                                  isRegex: searchBar.isRegexMode,
                                  caseInsensitive: AppPreferences.shared.searchIgnoreCase)
    }

    // The three context-menu search combinators, mirroring crawlerwidget.cpp 1:1.

    /// klogg replaceSearch( s ): setSearchPattern( escapeSearchPattern( s ) ).
    func replaceSearch(_ text: String) {
        guard !text.isEmpty else { return }
        runCombinedSearch(escapeSearchPattern(text))
    }

    /// klogg addToSearch( s ): combinePatterns( currentText, escapeSearchPattern( s ) ).
    func addToSearch(_ text: String) {
        guard !text.isEmpty else { return }
        let combined = combinePatterns(searchBar.currentPattern, escapeSearchPattern(text))
        runCombinedSearch(combined)
    }

    /// klogg excludeFromSearch( s ): if not already boolean, quote the current pattern;
    /// switch ON boolean mode; append " and not(escaped)".
    func excludeFromSearch(_ text: String) {
        guard !text.isEmpty else { return }
        var current = searchBar.currentPattern
        let wasBoolean = searchBar.isBooleanMode
        if !wasBoolean && !current.isEmpty {
            // klogg: current.replace('"', "\"").prepend('"').append('"').
            current = "\"" + current.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        searchBar.setBooleanMode(true)
        let newPattern = escapeSearchPattern(text)
        if !current.isEmpty { current += " and " }
        current += "not(" + newPattern + ")"
        runCombinedSearch(current)
    }

    /// Headless: clear the search field + reset toggles, then run add/exclude/replace by
    /// term (drives the SAME named methods the context menu calls). Used by SelfTest to
    /// assert combined-search counts.
    func selfTestCombineSearch(reset: Bool, op: String, term: String) {
        if reset {
            searchBar.setBooleanMode(false)
            searchBar.setSearchAndRun(pattern: "", isRegex: false, caseInsensitive: false)
            searchBar.clearFieldForTest()
        }
        switch op {
        case "replace": replaceSearch(term)
        case "add":     addToSearch(term)
        case "exclude": excludeFromSearch(term)
        default: break
        }
    }

    /// The current search-field text (headless: assert the combined pattern klogg builds).
    var selfTestSearchFieldText: String { searchBar.currentPattern }

    // MARK: - Filtered-view visibility (klogg visibilityBox_)

    /// Recompute the lower pane's content for the current visibility mode and reload it.
    ///
    /// klogg's filtered view shows the union/subset of MATCH lines and MARK lines per
    /// LogFilteredData::VisibilityFlags. Matches come from the engine (by match index);
    /// marks live in our Swift MarksStore (by source line). For:
    ///   • Matches          → the original fast match-index path (filteredSourceLines = nil)
    ///   • Marks            → only marked source lines
    ///   • Marks and matches → the sorted union of match + mark source lines
    func recomputeFilteredVisibility() {
        let mode = searchBar.visibility
        switch mode {
        case .matches:
            // Fast path: rows ARE match indices; no explicit source list.
            filteredView.filteredSourceLines = nil
            filteredView.reloadFromEngine(lineCount: Int(engine.searchMatchCount()))
        case .marks:
            let marks = marksStore.marks.sorted()
            filteredView.filteredSourceLines = marks
            filteredView.reloadFromEngine(lineCount: marks.count)
        case .marksAndMatches:
            var set = marksStore.marks
            let n = Int(engine.searchMatchCount())
            for i in 0 ..< n {
                let src = engine.searchMatchLine(at: UInt(i))
                if src != UInt.max { set.insert(Int(src)) }
            }
            let union = set.sorted()
            filteredView.filteredSourceLines = union
            filteredView.reloadFromEngine(lineCount: union.count)
        }
        refreshOverview()
        refreshScrollbarMarkers()
    }

    /// Give keyboard focus to the search field.
    func focusSearchBar() {
        searchBar.focusSearchField()
    }

    /// Load a predefined filter into the search bar and run it (Wave 8). Drives the
    /// exact code path a picker selection takes.
    func applyPredefinedFilter(_ filter: PredefinedFilter) {
        searchBar.applyFilter(filter)
    }

    /// Set the filtered-view visibility mode (drives the same path as the combobox).
    func setFilteredVisibility(_ mode: FilteredVisibility) {
        searchBar.setVisibility(mode)
    }

    /// Number of rows the filtered (lower) view currently displays. In Matches mode
    /// this equals searchMatchCount; in Marks / Marks-and-matches it's the explicit
    /// source-line list length.
    var filteredRowCount: Int { filteredView.lineCount }

    /// The current "N matches found." label text (headless assertion on the bar).
    var matchLabelText: String { searchBar.selfTestMatchLabelText }

    /// Drive the match-count label exactly as the searchFinished delegate does, then
    /// return the rendered text. Lets the headless harness assert the label format
    /// without depending on the engine's async (offscreen-unreliable) search callback.
    func selfTestMatchLabel(forCount count: Int) -> String {
        searchBar.updateMatchCount(count, finished: true)
        return searchBar.selfTestMatchLabelText
    }

    /// Drive the FULL search-bar path with all toggles, exactly as a Return press would
    /// (sets the inverse/boolean toggles first, then runs `startSearch`). Used by the
    /// headless harness to verify the bar → engine wiring for every toggle.
    func selfTestRunSearchViaBar(pattern: String, caseInsensitive: Bool, isRegex: Bool,
                                 inverse: Bool, boolean: Bool) {
        searchBar.setInverse(inverse)
        searchBar.setBooleanMode(boolean)
        startSearch(pattern: pattern, caseInsensitive: caseInsensitive,
                    isRegex: isRegex, inverse: inverse, boolean: boolean)
    }

    /// Current search-bar toggle states (headless persistence/wiring assertions).
    var selfTestSearchToggles: (inverse: Bool, boolean: Bool, autoRefresh: Bool) {
        (searchBar.selfTestInverse, searchBar.selfTestBoolean, searchBar.selfTestAutoRefresh)
    }

    // MARK: - QuickFind (Wave 6)

    /// The line the current QuickFind match sits on (0-based). Next/Previous step
    /// relative to this; nil before the first match.
    private var quickFindCurrentLine: Int?

    private func wireQuickFind() {
        quickFindBar.onChange = { [weak self] needle, ci in
            self?.quickFindIncremental(needle: needle, caseInsensitive: ci)
        }
        quickFindBar.onNext = { [weak self] in
            self?.quickFindStep(direction: .forward)
        }
        quickFindBar.onPrevious = { [weak self] in
            self?.quickFindStep(direction: .backward)
        }
        quickFindBar.onClose = { [weak self] in
            self?.closeQuickFind()
        }
    }

    /// Show the QuickFind bar over the main view and focus its field (Cmd+F).
    func showQuickFind() {
        quickFindBar.isHidden = false
        quickFindHeight?.constant = 30
        // Seed the origin from the main view's current selection so the first find
        // starts where the user is looking.
        quickFindCurrentLine = mainView.currentLine
        quickFindBar.focusField()
        // If the field already has text (re-opening), re-run the incremental find.
        if !quickFindBar.needle.isEmpty {
            quickFindIncremental(needle: quickFindBar.needle,
                                 caseInsensitive: quickFindBar.isCaseInsensitive)
        }
    }

    /// Step the QuickFind to the next/previous match WITHOUT requiring the bar to be
    /// focused (driven by the Find Next / Find Previous menu items, Cmd+G / Cmd+Shift+G).
    /// If no needle is set yet, this is a no-op (klogg beeps; the caller handles that).
    /// Returns true if a needle was active and a step was attempted.
    @discardableResult
    func quickFindNext() -> Bool {
        guard quickFind.hasNeedle else { return false }
        quickFindStep(direction: .forward)
        return true
    }

    @discardableResult
    func quickFindPrevious() -> Bool {
        guard quickFind.hasNeedle else { return false }
        quickFindStep(direction: .backward)
        return true
    }

    /// Whether a QuickFind needle is currently active (for menu validation).
    var hasQuickFindNeedle: Bool { quickFind.hasNeedle }

    /// Headless QuickFind driver: seed the needle, set the origin to `from`, step
    /// next/prev (exclusive of the origin, like Return), and return the matched 0-based
    /// line or -1 (no match / empty needle). Exercises the real QuickFindController.
    func selfTestQuickFind(from: Int, needle: String, caseInsensitive: Bool,
                           isRegex: Bool, next: Bool) -> Int {
        guard quickFind.setNeedle(needle, caseInsensitive: caseInsensitive, isRegex: isRegex)
        else { return -1 }
        quickFindCurrentLine = from
        let dir: QuickFindController.Direction = next ? .forward : .backward
        guard let r = quickFind.find(direction: dir, from: from, inclusive: false) else { return -1 }
        quickFindCurrentLine = r.line
        return r.line
    }

    private func closeQuickFind() {
        quickFindHeight?.constant = 0
        quickFindBar.isHidden = true
        // Clear the QuickFind highlight wash but leave any search highlight intact.
        mainView.setQuickFindHighlight(pattern: nil, caseInsensitive: true, isRegex: false)
        // Return focus to the main log view.
        view.window?.makeFirstResponder(mainView)
    }

    /// Incremental find as the user types: search from the current origin INCLUSIVELY
    /// so a match already on/under the caret is found in place.
    private func quickFindIncremental(needle: String, caseInsensitive: Bool) {
        guard quickFind.setNeedle(needle, caseInsensitive: caseInsensitive) else {
            // Empty / invalid needle: clear highlight + status.
            mainView.setQuickFindHighlight(pattern: nil, caseInsensitive: true, isRegex: false)
            quickFindBar.setStatus("")
            return
        }
        mainView.setQuickFindHighlight(pattern: needle,
                                       caseInsensitive: caseInsensitive, isRegex: false)
        let origin = quickFindCurrentLine ?? mainView.currentLine ?? 0
        if let r = quickFind.find(direction: .forward, from: origin, inclusive: true) {
            applyQuickFindResult(r)
        } else {
            quickFindBar.setStatus("No match", kind: .nomatch)
        }
    }

    /// Return / Shift-Return (or arrow buttons): step to the next/previous match,
    /// EXCLUSIVE of the current line so repeated presses advance.
    private func quickFindStep(direction: QuickFindController.Direction) {
        guard quickFind.hasNeedle else { return }
        let origin = quickFindCurrentLine ?? mainView.currentLine ?? 0
        if let r = quickFind.find(direction: direction, from: origin, inclusive: false) {
            applyQuickFindResult(r)
        } else {
            quickFindBar.setStatus("No match", kind: .nomatch)
        }
    }

    private func applyQuickFindResult(_ r: QuickFindController.Result) {
        quickFindCurrentLine = r.line
        mainView.scrollToLine(r.line)
        if r.wrapped {
            quickFindBar.setStatus("Wrapped — line \(r.line + 1)")
        } else {
            quickFindBar.setStatus("Line \(r.line + 1)")
        }
    }

    // MARK: - Follow mode (tail -f)

    /// Turn follow on/off. When enabling, the engine starts watching the file and we
    /// immediately jump to the tail; subsequent growth scrolls to the tail as it loads.
    func setFollowing(_ on: Bool) {
        isFollowing = on
        engine.setFollowEnabled(on)
        if on { scrollMainToEnd() }
    }

    /// Scroll the main view to its last line (the tail).
    func scrollMainToEnd() {
        let n = mainView.lineCount
        guard n > 0 else { return }
        mainView.scrollToLine(n - 1)
    }

    // MARK: - KloggEngineDelegate

    func kloggEngine(_ engine: Any, loadingProgress percent: Int32) {
        onLoadingProgress?(self, Int(percent))
    }

    func kloggEngine(_ engine: Any, loadingFinished success: Bool) {
        mainView.reloadFromEngine()
        refreshOverview()
        refreshScrollbarMarkers()
        onLoadingFinished?(self, success)
        // When following, every re-index (file grew) ends here — jump to the new tail.
        if isFollowing { scrollMainToEnd() }
        // Auto-refresh (klogg searchState_.isAutorefreshAllowed): if the search should
        // track file growth and we have an active search, re-run it over the (now larger)
        // file so new matching tail lines appear in the filtered view. Only when the
        // search range is whole-file (an explicit end limit means the user pinned it).
        if isSearchAutoRefresh && lastSearch != nil && searchEndLine == Int.max {
            rerunLastSearch()
        }
    }

    /// The file on disk changed while watching. The engine re-indexes automatically and
    /// loadingFinished: follows (where we scroll). Nothing extra needed here, but keep
    /// the hook so live growth is observable and future UI (badge) can use it.
    func kloggEngine(_ engine: Any, fileChanged status: Int) {
        // No-op: loadingFinished: drives the view refresh + tail scroll.
    }

    func kloggEngine(_ engine: Any, searchProgressed matchCount: UInt, percent: Int32) {
        searchBar.updateMatchCount(Int(matchCount), finished: false)
    }

    func kloggEngine(_ engine: Any, searchFinished matchCount: UInt) {
        searchBar.showProgress(false)
        searchBar.updateMatchCount(Int(matchCount), finished: true)
        // Reload the filtered view honouring the current visibility mode (the search
        // result feeds Matches / Marks-and-matches; refreshOverview is called there).
        recomputeFilteredVisibility()
    }
}

// MARK: - TabController

/// Hosts all open CrawlerTabs inside an NSTabView.
final class TabController: NSViewController {

    // MARK: - Public properties

    weak var statusBar: StatusBarView?
    var onTabChanged: ((CrawlerTab?) -> Void)?

    /// Supplies the shared scratchpad window controller for the log-view context menu's
    /// "Send to scratchpad" / "Replace scratchpad" actions. Set by MainWindowController.
    var scratchpadProvider: (() -> ScratchpadWindowController?)?

    var currentTab: CrawlerTab? {
        guard let item = tabView.selectedTabViewItem else { return nil }
        let idx = tabView.indexOfTabViewItem(item)
        guard idx != NSNotFound, idx >= 0, idx < _tabs.count else { return nil }
        return _tabs[idx]
    }

    var currentFilePath: String? { currentTab?.displayPath }

    var currentLineCount: Int {
        guard let tab = currentTab else { return 0 }
        return Int(tab.engine.lineCount())
    }

    /// Focus the search bar in the active tab (wired from Edit > Find).
    func focusSearchBar() {
        currentTab?.focusSearchBar()
    }

    /// Open the QuickFind bar in the active tab (wired from Edit > Find, Cmd+F).
    func showQuickFind() {
        currentTab?.showQuickFind()
    }

    /// Jump the active tab's main view to a 0-based line (wired from Go to Line).
    func goToLine(_ line: Int) {
        currentTab?.mainView.scrollToLine(line)
    }

    /// Step the active tab's QuickFind to the next match (Find Next, Cmd+G). Returns
    /// false when there is no active QuickFind needle so the caller can beep.
    @discardableResult
    func quickFindNext() -> Bool { currentTab?.quickFindNext() ?? false }

    /// Step the active tab's QuickFind to the previous match (Find Previous, Cmd+Shift+G).
    @discardableResult
    func quickFindPrevious() -> Bool { currentTab?.quickFindPrevious() ?? false }

    /// Whether the active tab has an active QuickFind needle (for menu validation).
    var currentTabHasQuickFindNeedle: Bool { currentTab?.hasQuickFindNeedle ?? false }

    /// Headless QuickFind driver on the active tab (see CrawlerTab.selfTestQuickFind).
    func selfTestQuickFind(from: Int, needle: String, caseInsensitive: Bool,
                           isRegex: Bool, next: Bool) -> Int {
        currentTab?.selfTestQuickFind(from: from, needle: needle,
                                      caseInsensitive: caseInsensitive,
                                      isRegex: isRegex, next: next) ?? -1
    }

    /// Run a predefined filter in the active tab's search bar (Wave 8).
    func applyPredefinedFilter(_ filter: PredefinedFilter) {
        currentTab?.applyPredefinedFilter(filter)
    }

    /// Drive the active tab's full search-bar path with all toggles (headless).
    func selfTestRunSearchViaBar(pattern: String, caseInsensitive: Bool, isRegex: Bool,
                                 inverse: Bool, boolean: Bool) {
        currentTab?.selfTestRunSearchViaBar(pattern: pattern, caseInsensitive: caseInsensitive,
                                            isRegex: isRegex, inverse: inverse, boolean: boolean)
    }

    /// Active tab's search-bar toggle states (headless).
    var selfTestSearchToggles: (inverse: Bool, boolean: Bool, autoRefresh: Bool) {
        currentTab?.selfTestSearchToggles ?? (false, false, false)
    }

    /// Drive the active tab's context-menu combine (replace/add/exclude) by term.
    func selfTestCombineSearch(reset: Bool, op: String, term: String) {
        currentTab?.selfTestCombineSearch(reset: reset, op: op, term: term)
    }

    /// The active tab's current search-field text (headless: the combined klogg pattern).
    var selfTestSearchFieldText: String { currentTab?.selfTestSearchFieldText ?? "" }

    /// Set the active tab's filtered-view visibility mode (klogg visibilityBox_).
    func setFilteredVisibility(_ mode: FilteredVisibility) {
        currentTab?.setFilteredVisibility(mode)
    }

    /// Rows the active tab's filtered view shows (Matches/Marks/Marks-and-matches).
    var currentFilteredRowCount: Int { currentTab?.filteredRowCount ?? 0 }

    /// The active tab's "N matches found." label text.
    var currentMatchLabelText: String { currentTab?.matchLabelText ?? "" }

    /// Render the active tab's match label for `count` (headless, deterministic).
    func matchLabel(forCount count: Int) -> String {
        currentTab?.selfTestMatchLabel(forCount: count) ?? ""
    }

    /// Scrollbar marker counts on the active tab (main, filtered) — headless assertion.
    var currentScrollbarMarkerCounts: (main: Int, filtered: Int) {
        guard let tab = currentTab else { return (0, 0) }
        return (tab.mainView.scrollbarMarkerCount, tab.filteredView.scrollbarMarkerCount)
    }

    /// Whether the active tab's overview strip is visible (defaults to the persisted
    /// preference when no tab is open, so the menu checkmark is sensible).
    var currentOverviewVisible: Bool {
        currentTab?.isOverviewVisible ?? AppPreferences.shared.overviewVisible
    }

    /// Toggle the overview strip on every open tab; returns the new state.
    @discardableResult
    func toggleOverview() -> Bool {
        let newState = !AppPreferences.shared.overviewVisible
        for tab in _tabs { tab.setOverviewVisible(newState) }
        // Persist even when no tab is open so the next-opened tab honours it.
        AppPreferences.shared.overviewVisible = newState
        return newState
    }

    /// Number of match marks the active tab's overview will plot (== match count).
    var currentOverviewMatchCount: Int { Int(currentTab?.engine.searchMatchCount() ?? 0) }

    /// Sync the active tab's main view + overview from the engine and repaint. Used by
    /// the headless snapshot path so the PNG reflects the latest engine state even when
    /// the async loadingFinished/searchFinished callbacks haven't been pumped yet.
    func refreshCurrentTabViews() {
        guard let tab = currentTab else { return }
        tab.mainView.reloadFromEngine()
        // Honour the active visibility mode so the filtered pane reflects Marks /
        // Marks-and-matches, not just the raw match list (refreshes the overview too).
        tab.recomputeFilteredVisibility()
    }

    /// Line count of the active tab's main view (for Go to Line range validation).
    var currentMainLineCount: Int { currentTab?.mainView.lineCount ?? 0 }

    /// Assign the active tab's selected main-view line text to colour-label `slot`
    /// (1...9, or 0 to clear that token). Returns the labelled text, or nil if there
    /// is no selection. The store change notification drives the repaint.
    @discardableResult
    func applyColorLabel(slot: Int) -> String? {
        guard let text = currentTab?.mainView.currentSelectionText else { return nil }
        ColorLabelsStore.shared.assign(text: text, slot: slot)
        return text
    }

    // Exposed as `_tabs` so MainWindowController can build the Opened Files menu
    // without making the internal list fully public.
    var _tabs: [CrawlerTab] = []

    // MARK: - Private state

    private let tabView = NSTabView()
    private let tabStrip = TabStripView()

    // MARK: - Init

    override func loadView() {
        // Native top tabs draw no close buttons, so we hide them and render our own
        // strip (with × close controls) above the borderless tab content.
        tabView.tabViewType = .noTabsNoBorder
        tabView.allowsTruncatedLabels = true
        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.translatesAutoresizingMaskIntoConstraints = false

        tabStrip.onSelect = { [weak self] idx in self?.selectTab(at: idx) }
        tabStrip.onClose  = { [weak self] idx in self?.closeTab(at: idx) }

        let container = NSView(frame: .zero)
        container.addSubview(tabStrip)
        container.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: container.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.stripHeight),

            tabView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
        refreshStrip()
    }

    /// Rebuild the custom tab strip from the current tab list + selection.
    private func refreshStrip() {
        let titles = _tabs.map { ($0.displayPath as NSString).lastPathComponent }
        tabStrip.reload(titles: titles, selected: selectedIndex() ?? -1)
    }

    // MARK: - Public API

    /// Open `path` in a new tab. If already open, switch to that tab.
    func openFile(path: String) {
        // If the file is already open (by user-facing path), just switch to its tab.
        if let idx = _tabs.firstIndex(where: { $0.displayPath == path }) {
            tabView.selectTabViewItem(at: idx)
            return
        }

        // Transparently decompress single-stream archives (.gz/.bz2/.xz/.lzma) to a
        // temp file, mirroring klogg's MainWindow::extractAndLoadFile. The engine then
        // indexes the temp file while the tab keeps the original name. tar/zip/7z need
        // KArchive and are not supported (NSOpenPanel still allows selecting them, but
        // they fall through and the engine reports a load failure).
        var enginePath = path
        if KloggDecompressor.isDecompressiblePath(path) {
            do {
                let tmp = try KloggDecompressor.decompress(toTempFile: path)
                enginePath = tmp
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not open compressed file"
                alert.informativeText = "\((path as NSString).lastPathComponent): \(error.localizedDescription)"
                alert.runModal()
                return
            }
        }

        let tab = CrawlerTab(filePath: enginePath, displayPath: path)
        tab.scratchpadProvider = { [weak self] in self?.scratchpadProvider?() }
        tab.onLoadingProgress = { [weak self] t, pct in
            guard self?.currentTab === t else { return }
            self?.statusBar?.showProgress(pct)
        }
        tab.onLoadingFinished = { [weak self] t, success in
            self?.tabLoadingFinished(tab: t, success: success)
        }
        tab.onMainLineChanged = { [weak self] line in
            guard self?.currentTab === tab else { return }
            self?.statusBar?.updatePosition(line: line, column: nil)
        }

        _tabs.append(tab)

        let item = NSTabViewItem(viewController: tab)
        item.label = (path as NSString).lastPathComponent
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)

        // Kick off the engine load on the (possibly decompressed) path.
        tab.engine.openFile(atPath: enginePath)
        RecentFiles.shared.add(path: path)
        refreshStrip()
    }

    /// Select the tab at `index` (from a strip click).
    func selectTab(at index: Int) {
        guard index >= 0, index < _tabs.count else { return }
        tabView.selectTabViewItem(at: index)
        refreshStrip()
    }

    /// Close the tab at a specific index (from a strip × click).
    func closeTab(at index: Int) {
        removeTab(at: index)
    }

    /// Reload the active tab's file by re-attaching it through the engine. The
    /// existing engine is re-pointed at the same path; loading callbacks refresh
    /// the views and status bar when the re-index finishes.
    func reloadCurrentTab() {
        guard let tab = currentTab else { return }
        tab.engine.reload()
    }

    /// Whether the active tab is following (tail -f). False if no tab is open.
    var currentTabIsFollowing: Bool { currentTab?.isFollowing ?? false }

    /// Toggle follow mode on the active tab; returns the new state (false if no tab).
    @discardableResult
    func toggleFollowCurrentTab() -> Bool {
        guard let tab = currentTab else { return false }
        tab.setFollowing(!tab.isFollowing)
        return tab.isFollowing
    }

    /// Re-index the active tab's file forcing a QTextCodec MIB encoding (-1 = auto).
    func reloadCurrentTab(encodingMib mib: Int) {
        currentTab?.engine.reload(withEncodingMib: mib)
    }

    // MARK: - Session persistence

    /// Ordered list of open file paths (for session save).
    var openFilePaths: [String] { _tabs.map { $0.displayPath } }

    /// Index of the active tab (0 if none).
    var activeTabIndex: Int { selectedIndex() ?? 0 }

    /// Close the currently-active tab.
    func closeCurrentTab() {
        guard let idx = selectedIndex() else { return }
        removeTab(at: idx)
    }

    /// Close all tabs.
    func closeAllTabs() {
        while !_tabs.isEmpty { removeTab(at: 0) }
    }

    // MARK: - Private helpers

    private func selectedIndex() -> Int? {
        guard let item = tabView.selectedTabViewItem else { return nil }
        let idx = tabView.indexOfTabViewItem(item)
        return (idx == NSNotFound) ? nil : idx
    }

    private func removeTab(at index: Int) {
        guard index >= 0, index < _tabs.count else { return }
        let item = tabView.tabViewItem(at: index)
        tabView.removeTabViewItem(item)
        _tabs.remove(at: index)
        updateStatusBar()
        refreshStrip()
        onTabChanged?(currentTab)
    }

    private func tabLoadingFinished(tab: CrawlerTab, success: Bool) {
        if let idx = _tabs.firstIndex(where: { $0 === tab }) {
            tabView.tabViewItem(at: idx).label = (tab.displayPath as NSString).lastPathComponent
        }
        if currentTab === tab {
            updateStatusBar()
        }
        refreshStrip()
        onTabChanged?(currentTab)
    }

    func updateStatusBar() {
        guard let tab = currentTab else {
            statusBar?.update(filePath: nil, lineCount: nil, fileSize: nil, encoding: nil)
            return
        }
        let lc = Int(tab.engine.lineCount())
        // Size/mtime reflect the indexed content (decompressed temp for archives).
        let attrs = try? FileManager.default.attributesOfItem(atPath: tab.filePath)
        let sz = attrs?[.size] as? Int64
        let modified = attrs?[.modificationDate] as? Date
        statusBar?.update(
            filePath: tab.displayPath,
            lineCount: lc,
            fileSize: sz,
            encoding: "UTF-8",   // encoding detection is Phase 4
            modified: modified)
    }
}

// MARK: - NSTabViewDelegate

extension TabController: NSTabViewDelegate {

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        updateStatusBar()
        refreshStrip()
        onTabChanged?(currentTab)
    }
}
