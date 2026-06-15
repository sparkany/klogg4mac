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

/// One tab: an engine + split-view hosting main log view + filtered view.
final class CrawlerTab: NSViewController, KloggEngineDelegate {

    let engine: KloggEngine
    let filePath: String
    let mainView: LogScrollView
    let filteredView: LogScrollView

    // Callbacks fired on the main thread.
    var onLoadingFinished: ((CrawlerTab, Bool) -> Void)?
    var onLoadingProgress: ((CrawlerTab, Int) -> Void)?

    init(filePath: String) {
        self.filePath = filePath
        self.engine = KloggEngine()
        self.mainView = LogScrollView(engine: engine)
        self.filteredView = LogScrollView(engine: engine)
        super.init(nibName: nil, bundle: nil)
        engine.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let split = NSSplitView(frame: .zero)
        split.isVertical = false      // stacked: main above, filtered below
        split.dividerStyle = .thin
        split.addArrangedSubview(mainView)
        split.addArrangedSubview(filteredView)
        self.view = split

        // Defer the divider position until the view has a real size.
        DispatchQueue.main.async { [weak split] in
            guard let split = split, split.bounds.height > 0 else { return }
            split.setPosition(split.bounds.height * 0.7, ofDividerAt: 0)
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
