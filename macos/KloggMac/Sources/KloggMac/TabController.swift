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

        let container = NSView(frame: .zero)
        container.addSubview(searchBar)
        container.addSubview(split)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: container.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.view = container

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
        engine.search(withPattern: pattern,
                      caseInsensitive: caseInsensitive,
                      regex: isRegex)
    }

    /// Give keyboard focus to the search field.
    func focusSearchBar() {
        searchBar.focusSearchField()
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
