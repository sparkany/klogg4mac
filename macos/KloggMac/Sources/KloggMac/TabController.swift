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
    let filePath: String
    let mainView: LogScrollView
    let filteredView: LogScrollView
    private let searchBar = SearchBarView()

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

    /// Follow (tail -f) mode. When ON the engine watches the file for growth and we
    /// auto-scroll the main view to the tail whenever a re-index finishes.
    private(set) var isFollowing = false

    init(filePath: String) {
        self.filePath = filePath
        self.engine = KloggEngine()
        self.mainView     = LogScrollView(engine: engine, mode: .main)
        self.filteredView = LogScrollView(engine: engine, mode: .filtered)
        super.init(nibName: nil, bundle: nil)
        engine.delegate = self

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

    @objc private func preferencesChanged() {
        // Font change (relayout) + view prefs (line numbers / ANSI / text wrap) + repaint.
        mainView.applyFontPreference()
        filteredView.applyFontPreference()
        mainView.applyViewPreferences()
        filteredView.applyViewPreferences()
        // Re-apply (or clear) the main-view search wash now that the
        // highlightSearchInMain preference may have changed.
        if let s = lastSearch {
            mainView.setSearchHighlight(pattern: s.pattern,
                                        caseInsensitive: s.caseInsensitive,
                                        isRegex: s.isRegex)
        }
    }

    override func loadView() {
        // Outer stack: search bar on top, then the log split below.
        let split = NSSplitView(frame: .zero)
        split.isVertical = false      // stacked: main above, filtered below
        split.dividerStyle = .thin
        split.addArrangedSubview(mainView)
        split.addArrangedSubview(filteredView)

        searchBar.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        quickFindBar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: .zero)
        container.addSubview(searchBar)
        container.addSubview(quickFindBar)
        container.addSubview(split)
        container.addSubview(overview)

        // QuickFind bar sits between the search bar and the split; it is collapsed
        // to zero height (hidden) until Cmd+F. Its own intrinsic 30pt height anchor
        // is suppressed when collapsed via the height constraint below.
        let qfHeight = quickFindBar.heightAnchor.constraint(equalToConstant: 0)
        quickFindHeight = qfHeight
        quickFindBar.isHidden = true

        // Overview strip: pinned to the trailing edge, spanning the split's height.
        // Its width toggles between 0 (hidden) and stripWidth; the split's trailing
        // edge follows the overview's leading edge, so the log view shrinks to make
        // room without overlapping. The strip is a sibling of the split — NEVER inside
        // the scroll view's clip view (which would suppress text rendering).
        let ovWidth = overview.widthAnchor.constraint(
            equalToConstant: isOverviewVisible ? OverviewView.stripWidth : 0)
        overviewWidth = ovWidth
        overview.isHidden = !isOverviewVisible

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: container.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            quickFindBar.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            quickFindBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            quickFindBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            qfHeight,

            split.topAnchor.constraint(equalTo: quickFindBar.bottomAnchor),
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
        searchBar.onSearch = { [weak self] pattern, caseInsensitive, isRegex in
            self?.startSearch(pattern: pattern,
                              caseInsensitive: caseInsensitive,
                              isRegex: isRegex)
        }
        searchBar.onCancel = { [weak self] in
            self?.engine.cancel()
        }

        // Scrolling the main view repositions the overview's viewport indicator.
        mainView.onScroll = { [weak self] in self?.refreshOverviewViewport() }

        // Clicking a filtered-view row jumps the main view to the matching source line.
        filteredView.onLineSelected = { [weak self] matchIndex in
            guard let self = self else { return }
            let sourceLine = self.engine.searchMatchLine(at: UInt(matchIndex))
            // NSNotFound bridges to UInt.max on 64-bit; skip invalid results.
            guard sourceLine != UInt.max else { return }
            self.mainView.scrollToLine(Int(sourceLine))
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

    // MARK: - Search

    private func startSearch(pattern: String, caseInsensitive: Bool, isRegex: Bool) {
        searchBar.showProgress(true)
        // Remember the active search so it can be re-applied as the main-view
        // highlight wash when the search finishes (honours highlightSearchInMain).
        lastSearch = (pattern, caseInsensitive, isRegex)
        // Apply the main-view highlight immediately so hits are visible while the
        // filtered index is still building.
        mainView.setSearchHighlight(pattern: pattern,
                                    caseInsensitive: caseInsensitive,
                                    isRegex: isRegex)
        engine.search(withPattern: pattern,
                      caseInsensitive: caseInsensitive,
                      regex: isRegex)
    }

    /// The pattern/options of the most recent search, kept so preference changes
    /// (toggling highlightSearchInMain) can re-apply or clear the main-view wash.
    private var lastSearch: (pattern: String, caseInsensitive: Bool, isRegex: Bool)?

    /// Give keyboard focus to the search field.
    func focusSearchBar() {
        searchBar.focusSearchField()
    }

    /// Load a predefined filter into the search bar and run it (Wave 8). Drives the
    /// exact code path a picker selection takes.
    func applyPredefinedFilter(_ filter: PredefinedFilter) {
        searchBar.applyFilter(filter)
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
        onLoadingFinished?(self, success)
        // When following, every re-index (file grew) ends here — jump to the new tail.
        if isFollowing { scrollMainToEnd() }
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
        filteredView.reloadFromEngine(lineCount: Int(matchCount))
        refreshOverview()   // plot the new match positions on the strip
    }
}

// MARK: - TabController

/// Hosts all open CrawlerTabs inside an NSTabView.
final class TabController: NSViewController {

    // MARK: - Public properties

    weak var statusBar: StatusBarView?
    var onTabChanged: ((CrawlerTab?) -> Void)?

    var currentTab: CrawlerTab? {
        guard let item = tabView.selectedTabViewItem else { return nil }
        let idx = tabView.indexOfTabViewItem(item)
        guard idx != NSNotFound, idx >= 0, idx < _tabs.count else { return nil }
        return _tabs[idx]
    }

    var currentFilePath: String? { currentTab?.filePath }

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

    /// Run a predefined filter in the active tab's search bar (Wave 8).
    func applyPredefinedFilter(_ filter: PredefinedFilter) {
        currentTab?.applyPredefinedFilter(filter)
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
        tab.filteredView.reloadFromEngine(lineCount: Int(tab.engine.searchMatchCount()))
        tab.refreshOverview()
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
        let titles = _tabs.map { ($0.filePath as NSString).lastPathComponent }
        tabStrip.reload(titles: titles, selected: selectedIndex() ?? -1)
    }

    // MARK: - Public API

    /// Open `path` in a new tab. If already open, switch to that tab.
    func openFile(path: String) {
        // If the file is already open, just switch to its tab.
        if let idx = _tabs.firstIndex(where: { $0.filePath == path }) {
            tabView.selectTabViewItem(at: idx)
            return
        }

        let tab = CrawlerTab(filePath: path)
        tab.onLoadingProgress = { [weak self] t, pct in
            guard self?.currentTab === t else { return }
            self?.statusBar?.showProgress(pct)
        }
        tab.onLoadingFinished = { [weak self] t, success in
            self?.tabLoadingFinished(tab: t, success: success)
        }

        _tabs.append(tab)

        let item = NSTabViewItem(viewController: tab)
        item.label = (path as NSString).lastPathComponent
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)

        // Kick off the engine load.
        tab.engine.openFile(atPath: path)
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
    var openFilePaths: [String] { _tabs.map { $0.filePath } }

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
            tabView.tabViewItem(at: idx).label = (tab.filePath as NSString).lastPathComponent
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
        let sz = fileSizeBytes(for: tab.filePath)
        statusBar?.update(
            filePath: tab.filePath,
            lineCount: lc,
            fileSize: sz,
            encoding: "UTF-8")   // encoding detection is Phase 4
    }

    private func fileSizeBytes(for path: String) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.size] as? Int64
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
