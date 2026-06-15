//
//  MainWindowController.swift — main window + shell host (Wave 2).
//
//  Hosts TabController (multi-tab, each tab = CrawlerTab with its own engine +
//  main/filtered split view), AppToolbar (NSToolbar), and StatusBarView.
//  Drag-and-drop a file onto the window to open it; drag-over shows the standard
//  highlighted border.
//
//  Action methods are declared here so the AppKit responder chain resolves them
//  from menu items regardless of which view is focused.
//

import AppKit
import KloggBridge

final class MainWindowController: NSWindowController, NSDraggingDestination {

    // MARK: - Owned components

    private let tabController = TabController()
    private let toolbar = AppToolbar()

    // Wave 4 dialog controllers — created lazily on first use.
    private lazy var highlightersWC       = HighlightersWindowController()
    private lazy var predefinedFiltersWC  = PredefinedFiltersWindowController()
    private lazy var scratchpadWC         = ScratchpadWindowController()
    private lazy var preferencesWC        = PreferencesWindowController()

    // MARK: - Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = KloggEngine.isStub ? "klogg (stub engine)" : "klogg"
        window.center()
        super.init(window: window)

        buildContent()
        wireToolbar()
        wireTabController()

        // Drag-and-drop
        window.registerForDraggedTypes([.fileURL])
        window.contentView?.registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Window content

    private func buildContent() {
        guard let window = window else { return }

        // Load the tab controller's view, then embed it manually so the window
        // keeps its explicitly-set frame (contentViewController resizes the window
        // to fit the VC's minimum size, which collapses NSTabView to ~1x84).
        tabController.loadViewIfNeeded()
        let tabView = tabController.view
        tabView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(tabView)
        if let cv = window.contentView {
            NSLayoutConstraint.activate([
                tabView.topAnchor.constraint(equalTo: cv.topAnchor),
                tabView.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
                tabView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                tabView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            ])
        }
        window.minSize = NSSize(width: 600, height: 400)
    }

    private func wireToolbar() {
        guard let window = window else { return }
        let tb = toolbar.makeToolbar()
        window.toolbar = tb

        // Connect StatusBarView to TabController.
        tabController.statusBar = toolbar.statusBar
    }

    private func wireTabController() {
        tabController.onTabChanged = { [weak self] tab in
            guard let self = self else { return }
            let title: String
            if let path = tab?.filePath {
                title = (path as NSString).lastPathComponent
            } else {
                title = KloggEngine.isStub ? "klogg (stub engine)" : "klogg"
            }
            self.window?.title = title
            self.updateOpenedFilesMenu()
            self.refreshFollowUI()
            // Persist the open-files set whenever tabs change so the last session is
            // always current (covers open, close, and tab switches).
            self.saveSession()
        }
    }

    // MARK: - File open

    /// Open a file by path — called from menus, command-line args, drag-drop, and recent files.
    func openFile(path: String) {
        tabController.openFile(path: path)
    }

    // MARK: - Session restore

    /// Write the current open-files set + active tab to the last-session store.
    func saveSession() {
        AppPreferences.shared.saveSession(
            openFiles: tabController.openFilePaths,
            activeIndex: tabController.activeTabIndex)
    }

    /// Reopen the files from the last session (active tab last so it ends up selected).
    /// Only paths that still exist on disk are restored. Returns the number reopened.
    @discardableResult
    func restoreSession() -> Int {
        let paths = AppPreferences.shared.sessionOpenFiles
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return 0 }
        for p in paths { tabController.openFile(path: p) }
        // Select the previously-active tab (clamped to the restored set).
        let idx = min(max(AppPreferences.shared.sessionActiveIndex, 0), paths.count - 1)
        tabController.selectTab(at: idx)
        return paths.count
    }

    // MARK: - NSDraggingDestination

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        guard board.canReadObject(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = board.readObjects(forClasses: [NSURL.self], options: opts)
                as? [URL] else { return false }
        for url in urls where url.isFileURL {
            openFile(path: url.path)
        }
        return true
    }

    // MARK: - Opened-files submenu (View > Opened Files)

    private func updateOpenedFilesMenu() {
        guard let menu = NSApp.mainMenu?
                .item(withTitle: "View")?
                .submenu?
                .item(withTag: MenuTag.openedFiles.rawValue)?
                .submenu else { return }
        menu.removeAllItems()
        // Build one item per open tab.
        for (idx, tab) in tabController._tabs.enumerated() {
            let name = (tab.filePath as NSString).lastPathComponent
            let it = NSMenuItem(
                title: name,
                action: #selector(switchToTab(_:)),
                keyEquivalent: idx < 9 ? "\(idx + 1)" : "")
            it.keyEquivalentModifierMask = [.command]
            it.tag = idx
            it.representedObject = tab.filePath
            it.target = self
            it.state = (tabController.currentTab === tab) ? .on : .off
            menu.addItem(it)
        }
    }

    @objc private func switchToTab(_ sender: NSMenuItem) {
        let path = sender.representedObject as? String ?? ""
        tabController.openFile(path: path)   // already open → just switches to it
    }

    // MARK: - File menu actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.openFile(path: url.path)
            }
        }
    }

    @objc func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openFile(path: path)
    }

    @objc func clearRecentFiles(_ sender: Any?) {
        RecentFiles.shared.clear()
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        tabController.closeCurrentTab()
    }

    @objc func closeAllTabs(_ sender: Any?) {
        tabController.closeAllTabs()
    }

    // --- TODOs (stubs for later waves) ---

    @objc func newWindow(_ sender: Any?) {
        // TODO(Phase 4): multi-window support
        let alert = NSAlert()
        alert.messageText = "Not yet implemented"
        alert.informativeText = "New Window is planned for Phase 4."
        alert.runModal()
    }

    @objc func openFromClipboard(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else {
            NSSound.beep()
            return
        }
        guard let path = writeTempLog(text, prefix: "clipboard") else {
            NSSound.beep()
            return
        }
        openFile(path: path)
    }

    @objc func openFromURL(_ sender: Any?) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Open from URL"
        alert.informativeText = "Enter a URL to download and open:"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com/app.log"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: raw), url.scheme != nil else {
                NSSound.beep()
                return
            }
            self?.downloadAndOpen(url: url)
        }
    }

    /// Download `url` to a temp file off the main thread, then open it.
    private func downloadAndOpen(url: URL) {
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tmpURL, _, error in
            guard let tmpURL = tmpURL, error == nil else {
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            // Move the downloaded file to a stable temp path with the URL's name.
            let name = url.lastPathComponent.isEmpty ? "download.log" : url.lastPathComponent
            let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("klogg-url-\(UUID().uuidString)-\(name)")
            do {
                try FileManager.default.moveItem(at: tmpURL, to: dest)
            } catch {
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            DispatchQueue.main.async { self?.openFile(path: dest.path) }
        }
        task.resume()
    }

    /// Write `text` to a uniquely-named temp .log file; returns its path (nil on failure).
    private func writeTempLog(_ text: String, prefix: String) -> String? {
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("klogg-\(prefix)-\(UUID().uuidString).log")
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
            return dest.path
        } catch {
            return nil
        }
    }

    // MARK: - Edit menu actions

    @objc func copyPathToClipboard(_ sender: Any?) {
        guard let path = tabController.currentFilePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc func openContainingFolder(_ sender: Any?) {
        guard let path = tabController.currentFilePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    @objc func openInEditor(_ sender: Any?) {
        // TODO(Phase 4): open in $EDITOR / default text editor
        guard let path = tabController.currentFilePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func clearLog(_ sender: Any?) {
        // In klogg, "Clear Log" truncates the backing file and is only offered for
        // temporary documents (clipboard/scratch logs that klogg itself owns) — it
        // must NOT destroy a user's real log. We don't yet tag temp-backed tabs, so
        // this remains disabled (see validateMenuItem) rather than risk data loss.
    }

    @objc func openQuickFind(_ sender: Any?) {
        tabController.showQuickFind()
    }

    @objc func goToLine(_ sender: Any?) {
        guard let window = window else { return }
        let lineCount = tabController.currentMainLineCount
        guard lineCount > 0 else { NSSound.beep(); return }

        // Build a compact accessory: a label + a numeric text field.
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number (1–\(lineCount)):"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.alignment = .left
        field.placeholderString = "Line number"
        // Accept only digits.
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.allowsFloats = false
        fmt.minimum = 1
        fmt.maximum = NSNumber(value: lineCount)
        field.formatter = fmt
        alert.accessoryView = field
        // Make the field first responder when the sheet appears.
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let oneBased = Int(raw), oneBased >= 1, oneBased <= lineCount else {
                NSSound.beep()
                return
            }
            // 1-based input → 0-based engine line.
            self?.tabController.goToLine(oneBased - 1)
        }
    }

    // MARK: - View menu actions

    @objc func toggleOverview(_ sender: Any?) {
        // TODO(Phase 3): show/hide overview minimap
    }

    @objc func toggleMainLineNumbers(_ sender: NSMenuItem) {
        // Flip the persisted preference; the .preferencesDidChange notification
        // (posted by the setter) drives each tab's applyViewPreferences(), which
        // shows/hides the inline gutter. Checkmark is refreshed in validateMenuItem.
        AppPreferences.shared.lineNumbersInMain.toggle()
    }

    @objc func toggleFilteredLineNumbers(_ sender: NSMenuItem) {
        AppPreferences.shared.lineNumbersInFiltered.toggle()
    }

    @objc func toggleTextWrap(_ sender: Any?) {
        // TODO(Phase 3): toggle text wrap in log views
    }

    @objc func toggleFollow(_ sender: Any?) {
        guard tabController.currentFilePath != nil else { NSSound.beep(); return }
        tabController.toggleFollowCurrentTab()
        // Reflect the new state in the toolbar button highlight and menu checkmark.
        refreshFollowUI()
    }

    /// Sync the Follow toolbar item's highlight + the View>Follow File menu checkmark
    /// to the active tab's follow state.
    func refreshFollowUI() {
        let on = tabController.currentTabIsFollowing
        // Toolbar: bordered items show a pressed/tinted state via `isBordered` + tint.
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == .kloggFollow }) {
            if #available(macOS 11.0, *) {
                item.isBordered = true
                item.image = NSImage(systemSymbolName: "arrow.down.to.line",
                                     accessibilityDescription: "Follow")?
                    .withSymbolConfiguration(
                        .init(paletteColors: [on ? .controlAccentColor : .labelColor]))
            }
        }
    }

    @objc func reloadFile(_ sender: Any?) {
        tabController.reloadCurrentTab()
    }

    @objc func stopLoading(_ sender: Any?) {
        tabController.currentTab?.engine.cancel()
    }

    // MARK: - Tools menu actions

    @objc func editPredefinedFilters(_ sender: Any?) {
        predefinedFiltersWC.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showScratchpad(_ sender: Any?) {
        scratchpadWC.toggle()
    }

    // MARK: - Highlighters

    @objc func editHighlighters(_ sender: Any?) {
        highlightersWC.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Encoding

    @objc func changeEncoding(_ sender: NSMenuItem) {
        let mib = sender.tag   // -1 = auto, 0 = system default, >0 = MIB number

        // Update check marks: clear the top-level Encoding menu items,
        // then walk into any submenus to uncheck those too.
        if let topMenu = NSApp.mainMenu?.item(withTitle: "Encoding")?.submenu {
            uncheckAll(in: topMenu)
        }
        sender.state = .on

        // Persist the chosen MIB.
        AppPreferences.shared.defaultEncodingMib = mib

        // Update the status bar encoding field.
        tabController.statusBar?.updateEncoding(mib == -1 ? "Auto" : sender.title)

        // Re-index the current file with the chosen encoding. The MIB is passed
        // straight through to LogData::reload(QTextCodec*); -1 clears the override and
        // auto-detects. loadingFinished refreshes the view + line count.
        if tabController.currentFilePath != nil {
            tabController.reloadCurrentTab(encodingMib: mib)
        }
    }

    /// Recursively clear .on state from all items in a menu (including submenus).
    private func uncheckAll(in menu: NSMenu) {
        for item in menu.items {
            item.state = .off
            if let sub = item.submenu { uncheckAll(in: sub) }
        }
    }

    // MARK: - Favorites

    @objc func addToFavorites(_ sender: Any?) {
        guard let path = tabController.currentFilePath else { return }
        FavoritesStore.shared.add(path: path)
        FavoritesMenu.shared.rebuild()
    }

    @objc func removeFromFavorites(_ sender: Any?) {
        guard let path = tabController.currentFilePath else { return }
        FavoritesStore.shared.remove(path: path)
        FavoritesMenu.shared.rebuild()
    }

    /// Toolbar ★: add the current file to favorites, or remove it if already there.
    @objc func toggleFavorite(_ sender: Any?) {
        guard let path = tabController.currentFilePath else { return }
        FavoritesStore.shared.toggle(path: path)
        FavoritesMenu.shared.rebuild()
    }

    /// Open a favorite from the Favorites menu.
    @objc func openFavorite(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openFile(path: path)
    }

    // MARK: - Help menu actions

    @objc func showDocumentation(_ sender: Any?) {
        let url = URL(string: "https://github.com/variar/klogg/blob/master/README.md")!
        NSWorkspace.shared.open(url)
    }

    @objc func reportIssue(_ sender: Any?) {
        let url = URL(string: "https://github.com/variar/klogg/issues/new")!
        NSWorkspace.shared.open(url)
    }

    @objc func joinDiscord(_ sender: Any?) {
        let url = URL(string: "https://discord.gg/DruNyQftzB")!
        NSWorkspace.shared.open(url)
    }

    @objc func joinTelegram(_ sender: Any?) {
        let url = URL(string: "https://t.me/joinchat/JeIBxstIfp4xZTk6")!
        NSWorkspace.shared.open(url)
    }

    @objc func generateDump(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Not yet implemented"
        alert.informativeText = "Debug report generation is planned for a later phase."
        alert.runModal()
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func showPreferences(_ sender: Any?) {
        preferencesWC.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSMenuItemValidation

    // NSMenuItemValidation -- NSWindowController inherits this via NSResponder.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasFile = tabController.currentFilePath != nil
        let path = tabController.currentFilePath
        switch menuItem.action {
        case #selector(closeCurrentTab(_:)),
             #selector(closeAllTabs(_:)):
            return hasFile
        case #selector(copyPathToClipboard(_:)),
             #selector(openContainingFolder(_:)),
             #selector(openInEditor(_:)),
             #selector(reloadFile(_:)):
            return hasFile
        case #selector(openQuickFind(_:)),
             #selector(goToLine(_:)),
             #selector(stopLoading(_:)):
            return hasFile
        case #selector(openFromClipboard(_:)):
            // Enabled only when the pasteboard actually holds text.
            return NSPasteboard.general.string(forType: .string)?.isEmpty == false
        case #selector(openFromURL(_:)):
            return true
        case #selector(clearLog(_:)):
            // Only valid for temp-backed docs, which we don't yet distinguish.
            return false
        case #selector(addToFavorites(_:)):
            return hasFile && !(path.map { FavoritesStore.shared.isFavorite($0) } ?? false)
        case #selector(removeFromFavorites(_:)):
            return path.map { FavoritesStore.shared.isFavorite($0) } ?? false
        case #selector(toggleFollow(_:)):
            menuItem.state = tabController.currentTabIsFollowing ? .on : .off
            return hasFile
        case #selector(toggleMainLineNumbers(_:)):
            menuItem.state = AppPreferences.shared.lineNumbersInMain ? .on : .off
            return true
        case #selector(toggleFilteredLineNumbers(_:)):
            menuItem.state = AppPreferences.shared.lineNumbersInFiltered ? .on : .off
            return true
        case #selector(clearRecentFiles(_:)):
            return !RecentFiles.shared.paths.isEmpty
        default:
            return true
        }
    }

    /// Toolbar items route through the responder chain; validate them here so the
    /// ★ favorite and Reload buttons grey out when no file is open.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(reloadFile(_:)), #selector(toggleFavorite(_:)),
             #selector(toggleFollow(_:)):
            return tabController.currentFilePath != nil
        case #selector(stopLoading(_:)):
            return tabController.currentFilePath != nil
        default:
            return true
        }
    }

    // MARK: - Self-test hooks (headless QA; see SelfTest.swift / `--selftest`)

    /// Number of open tabs — used by the headless behavior tests.
    var selfTestTabCount: Int { tabController._tabs.count }

    /// The window's toolbar (for headless toolbar-state auditing).
    var selfTestToolbar: NSToolbar? { window?.toolbar }

    /// Open a path then return the new tab count (headless behavior tests).
    func selfTestOpen(_ path: String) { openFile(path: path) }

    /// The active tab's file path (headless assertions).
    var selfTestCurrentFilePath: String? { tabController.currentFilePath }

    /// The active tab's engine line count (headless reload assertion).
    var selfTestCurrentLineCount: Int { tabController.currentLineCount }

    /// Close a specific tab by index (headless close-specific-tab assertion).
    func selfTestCloseTab(at index: Int) { tabController.closeTab(at: index) }

    /// The current file's favorite state (headless favorites round-trip assertion).
    var selfTestCurrentIsFavorite: Bool {
        tabController.currentFilePath.map { FavoritesStore.shared.isFavorite($0) } ?? false
    }

    /// Invoke a favorites/line-number action by name for headless behavior tests.
    func selfTestToggleFavorite() { toggleFavorite(nil) }

    // --- Follow mode (headless) ---

    /// Toggle follow on the active tab (drives toggleFollow:).
    func selfTestToggleFollow() { toggleFollow(nil) }

    /// Whether the active tab is following.
    var selfTestIsFollowing: Bool { tabController.currentTabIsFollowing }

    /// The active tab's main-view anchor line (0-based), or -1 if none. After a tail
    /// scroll this equals lineCount-1, proving the view jumped to the new tail.
    var selfTestMainAnchorLine: Int { tabController.currentTab?.mainView.currentLine ?? -1 }

    /// Force a refresh of the active tab's main view from the engine + jump to the
    /// tail if following (mirrors what loadingFinished: does, for deterministic tests
    /// after the engine has finished re-indexing).
    func selfTestRefreshFollowTail() {
        guard let tab = tabController.currentTab else { return }
        tab.mainView.reloadFromEngine()
        if tab.isFollowing { tab.scrollMainToEnd() }
    }

    // --- Encoding (headless) ---

    /// Re-index the active tab forcing a QTextCodec MIB encoding (-1 = auto).
    func selfTestChangeEncoding(mib: Int) { tabController.reloadCurrentTab(encodingMib: mib) }

    // --- Session restore (headless) ---

    /// Open file paths in the active session (for the persistence round-trip).
    var selfTestOpenFilePaths: [String] { tabController.openFilePaths }

    /// Persist the current session (open files + active tab).
    func selfTestSaveSession() { saveSession() }

    /// Restore the last session; returns the number of files reopened.
    @discardableResult
    func selfTestRestoreSession() -> Int { restoreSession() }

    /// Render the window's content view OFFSCREEN (never ordered on screen) to a PNG.
    /// Used to verify the tab strip + log rendering visually in headless QA.
    @discardableResult
    func selfTestSnapshot(to path: String, size: NSSize = NSSize(width: 900, height: 500)) -> Bool {
        guard let content = window?.contentView else { return false }
        content.frame = NSRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        // Force the log views to fetch + lay out their visible rows.
        tabController.updateStatusBar()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return false
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

