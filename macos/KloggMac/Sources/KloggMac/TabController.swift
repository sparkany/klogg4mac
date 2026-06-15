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

    // QuickFind (Wave 6): an incremental in-place find bar over the main view.
    private let quickFindBar = QuickFindBar()
    private lazy var quickFind = QuickFindController(engine: engine)
    /// Top constraint of the QuickFind bar; toggled to slide it in/out.
    private var quickFindHeight: NSLayoutConstraint?

    // Callbacks fired on the main thread.
    var onLoadingFinished: ((CrawlerTab, Bool) -> Void)?
    var onLoadingProgress: ((CrawlerTab, Int) -> Void)?

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
        // Font change (relayout) + view prefs (line numbers / ANSI) + repaint.
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

        // QuickFind bar sits between the search bar and the split; it is collapsed
        // to zero height (hidden) until Cmd+F. Its own intrinsic 30pt height anchor
        // is suppressed when collapsed via the height constraint below.
        let qfHeight = quickFindBar.heightAnchor.constraint(equalToConstant: 0)
        quickFindHeight = qfHeight
        quickFindBar.isHidden = true

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
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.view = container

        wireQuickFind()

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

        // Clicking a filtered-view row jumps the main view to the matching source line.
        filteredView.onLineSelected = { [weak self] matchIndex in
            guard let self = self else { return }
            let sourceLine = self.engine.searchMatchLine(at: UInt(matchIndex))
            // NSNotFound bridges to UInt.max on 64-bit; skip invalid results.
            guard sourceLine != UInt.max else { return }
            self.mainView.scrollToLine(Int(sourceLine))
        }
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

    // MARK: - KloggEngineDelegate

    func kloggEngine(_ engine: Any, loadingProgress percent: Int32) {
        onLoadingProgress?(self, Int(percent))
    }

    func kloggEngine(_ engine: Any, loadingFinished success: Bool) {
        mainView.reloadFromEngine()
        onLoadingFinished?(self, success)
    }

    func kloggEngine(_ engine: Any, searchProgressed matchCount: UInt, percent: Int32) {
        searchBar.updateMatchCount(Int(matchCount), finished: false)
    }

    func kloggEngine(_ engine: Any, searchFinished matchCount: UInt) {
        searchBar.showProgress(false)
        searchBar.updateMatchCount(Int(matchCount), finished: true)
        filteredView.reloadFromEngine(lineCount: Int(matchCount))
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

    /// Line count of the active tab's main view (for Go to Line range validation).
    var currentMainLineCount: Int { currentTab?.mainView.lineCount ?? 0 }

    // Exposed as `_tabs` so MainWindowController can build the Opened Files menu
    // without making the internal list fully public.
    var _tabs: [CrawlerTab] = []

    // MARK: - Private state

    private let tabView = NSTabView()

    // MARK: - Init

    override func loadView() {
        tabView.tabViewType = .topTabsBezelBorder
        tabView.allowsTruncatedLabels = true
        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false
        self.view = tabView
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
    }

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
        onTabChanged?(currentTab)
    }

    private func tabLoadingFinished(tab: CrawlerTab, success: Bool) {
        if let idx = _tabs.firstIndex(where: { $0 === tab }) {
            tabView.tabViewItem(at: idx).label = (tab.filePath as NSString).lastPathComponent
        }
        if currentTab === tab {
            updateStatusBar()
        }
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
        onTabChanged?(currentTab)
    }
}
