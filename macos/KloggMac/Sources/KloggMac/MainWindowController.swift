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
        // The log-view context menu's "Send to scratchpad" reaches the shared window.
        tabController.scratchpadProvider = { [weak self] in
            guard let self = self else { return nil }
            self.scratchpadWC.showIfNeeded()
            return self.scratchpadWC
        }
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
            self.refreshFavoriteIcon()
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

    /// Find Next (Cmd+G): step the active tab's QuickFind forward. If no needle is set
    /// yet, open the QuickFind bar so the user can type one (klogg opens QuickFind on
    /// the find-next shortcut when nothing is active).
    @objc func findNext(_ sender: Any?) {
        guard tabController.currentFilePath != nil else { NSSound.beep(); return }
        if !tabController.quickFindNext() {
            tabController.showQuickFind()
        }
    }

    /// Find Previous (Cmd+Shift+G): step the active tab's QuickFind backward.
    @objc func findPrevious(_ sender: Any?) {
        guard tabController.currentFilePath != nil else { NSSound.beep(); return }
        if !tabController.quickFindPrevious() {
            tabController.showQuickFind()
        }
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
        tabController.toggleOverview()
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
        // Flip the persisted preference; .preferencesDidChange drives each tab's
        // applyViewPreferences() → applyTextWrapPreference() to reflow + repaint.
        AppPreferences.shared.useTextWrap.toggle()
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

    // MARK: - Font zoom (klogg Ctrl+wheel / changeFontSize)

    @objc func increaseFontSize(_ sender: Any?) {
        AppPreferences.shared.changeFontSize(increase: true)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        AppPreferences.shared.changeFontSize(increase: false)
    }

    @objc func resetFontSize(_ sender: Any?) {
        AppPreferences.shared.fontSize = 12
    }

    // MARK: - Tools menu actions

    @objc func editPredefinedFilters(_ sender: Any?) {
        predefinedFiltersWC.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showScratchpad(_ sender: Any?) {
        scratchpadWC.toggle()
    }

    // MARK: - Color labels (Wave 8)

    /// Assign the selected line's text to the colour slot carried in the menu item's
    /// tag (1–9). Beeps if nothing is selected.
    @objc func assignColorLabel(_ sender: NSMenuItem) {
        if tabController.applyColorLabel(slot: sender.tag) == nil { NSSound.beep() }
    }

    @objc func clearColorLabels(_ sender: Any?) {
        ColorLabelsStore.shared.clearAll()
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
        refreshFavoriteIcon()
    }

    @objc func removeFromFavorites(_ sender: Any?) {
        guard let path = tabController.currentFilePath else { return }
        FavoritesStore.shared.remove(path: path)
        FavoritesMenu.shared.rebuild()
        refreshFavoriteIcon()
    }

    /// Toolbar ★: add the current file to favorites, or remove it if already there.
    @objc func toggleFavorite(_ sender: Any?) {
        guard let path = tabController.currentFilePath else { return }
        _ = FavoritesStore.shared.toggle(path: path)
        FavoritesMenu.shared.rebuild()
        refreshFavoriteIcon()
    }

    /// Sync the ★ toolbar icon (filled/empty) with the current file's favorite state.
    func refreshFavoriteIcon() {
        let fav = tabController.currentFilePath.map { FavoritesStore.shared.isFavorite($0) } ?? false
        toolbar.updateFavorite(isFavorite: fav)
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
             #selector(findNext(_:)),
             #selector(findPrevious(_:)),
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
        case #selector(toggleOverview(_:)):
            menuItem.state = tabController.currentOverviewVisible ? .on : .off
            return true
        case #selector(toggleTextWrap(_:)):
            menuItem.state = AppPreferences.shared.useTextWrap ? .on : .off
            return true
        case #selector(clearRecentFiles(_:)):
            return !RecentFiles.shared.paths.isEmpty
        case #selector(assignColorLabel(_:)):
            // Enabled only when a main-view line is selected to label.
            return tabController.currentTab?.mainView.currentSelectionText != nil
        case #selector(clearColorLabels(_:)):
            return !ColorLabelsStore.shared.labels.isEmpty
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

    // --- Text wrap (headless) ---

    /// Toggle text wrap (flips the preference; tabs reflow via preferencesDidChange).
    /// The live reflow path is async; apply it synchronously to the active tab's views
    /// so headless assertions/snapshots see the new state immediately.
    func selfTestToggleTextWrap() {
        toggleTextWrap(nil)
        tabController.currentTab?.mainView.applyTextWrapPreference()
        tabController.currentTab?.filteredView.applyTextWrapPreference()
    }

    /// Whether text wrap is on (preference value).
    var selfTestTextWrapEnabled: Bool { AppPreferences.shared.useTextWrap }

    /// Whether the active tab's main view currently has wrap enabled (the view-side
    /// flag, proving the preference reached the view).
    var selfTestMainViewWrapEnabled: Bool {
        tabController.currentTab?.mainView.isWrapEnabled ?? false
    }

    /// Visual-row count for main-view logical line `line` at the current wrap width.
    func selfTestMainVisualRows(forLine line: Int) -> Int {
        tabController.currentTab?.mainView.visualRowCount(forLine: line) ?? 0
    }

    // --- Overview minimap (headless) ---

    /// Toggle the overview strip on all tabs; returns the new visibility.
    @discardableResult
    func selfTestToggleOverview() -> Bool { tabController.toggleOverview() }

    /// Whether the active tab's overview strip is visible.
    var selfTestOverviewVisible: Bool { tabController.currentOverviewVisible }

    /// Number of match marks the overview will plot (== current search match count).
    var selfTestOverviewMatchCount: Int { tabController.currentOverviewMatchCount }

    /// Run a search on the active tab (so the overview has matches to plot), driving
    /// the same engine path as the search bar.
    func selfTestRunSearch(pattern: String, caseInsensitive: Bool, isRegex: Bool) {
        tabController.currentTab?.engine.search(withPattern: pattern,
                                                caseInsensitive: caseInsensitive,
                                                regex: isRegex)
    }

    // --- Predefined filters in search bar (headless) ---

    /// Run a predefined filter in the active tab's search bar (drives the same code
    /// path as a picker selection). The resulting search runs on the engine; tests
    /// pump the runloop then assert on the match count.
    func selfTestApplyPredefinedFilter(_ filter: PredefinedFilter) {
        tabController.applyPredefinedFilter(filter)
    }

    /// Match count of the active tab's last search (filtered view line count).
    var selfTestSearchMatchCount: Int {
        Int(tabController.currentTab?.engine.searchMatchCount() ?? 0)
    }

    /// Full engine search with inverse/boolean/range — drives the new bridge method
    /// directly (deterministic, independent of the async UI path). `endLine == Int.max`
    /// means "to end of file".
    func selfTestRunSearchFull(pattern: String, caseInsensitive: Bool, isRegex: Bool,
                               inverse: Bool, boolean: Bool, startLine: Int, endLine: Int) {
        tabController.currentTab?.engine.search(
            withPattern: pattern, caseInsensitive: caseInsensitive, regex: isRegex,
            inverse: inverse, boolean: boolean,
            startLine: UInt(max(0, startLine)),
            endLine: endLine == Int.max ? UInt.max : UInt(endLine))
    }

    /// Whether `pattern` is a valid search expression for the active engine (mirrors
    /// klogg's isValid() gate; exercised for both regex and boolean modes).
    func selfTestIsValidSearch(pattern: String, isRegex: Bool, boolean: Bool) -> Bool {
        tabController.currentTab?.engine.isValidSearchPattern(
            pattern, regex: isRegex, boolean: boolean) ?? false
    }

    /// Drive the FULL search-bar path with all toggles (klogg replaceCurrentSearch).
    /// Sets the inverse/boolean toggles, then runs `pattern` exactly as a Return press.
    func selfTestRunSearchViaBar(pattern: String, caseInsensitive: Bool, isRegex: Bool,
                                 inverse: Bool, boolean: Bool) {
        tabController.selfTestRunSearchViaBar(pattern: pattern, caseInsensitive: caseInsensitive,
                                              isRegex: isRegex, inverse: inverse, boolean: boolean)
    }

    /// Set / clear the active tab's search-range limits via the context-menu code path.
    func selfTestSetSearchStart(line: Int) { tabController.currentTab?.setSearchStart(line: line) }
    func selfTestSetSearchEnd(line: Int)   { tabController.currentTab?.setSearchEnd(line: line) }
    func selfTestClearSearchLimits()       { tabController.currentTab?.clearSearchLimits() }

    /// The active tab's current search-range limits (start inclusive, end exclusive).
    var selfTestSearchRange: (start: Int, end: Int) {
        guard let t = tabController.currentTab else { return (0, Int.max) }
        return (t.searchStartLine, t.searchEndLine)
    }

    /// Search-bar toggle states (headless assertions on persistence + wiring).
    var selfTestSearchToggles: (inverse: Bool, boolean: Bool, autoRefresh: Bool) {
        tabController.selfTestSearchToggles
    }

    /// Drive the context-menu combine (replace/add/exclude) by term — klogg crawlerwidget
    /// replaceSearch/addToSearch/excludeFromSearch. `reset` clears the field + boolean
    /// toggle first.
    func selfTestCombineSearch(reset: Bool, op: String, term: String) {
        tabController.selfTestCombineSearch(reset: reset, op: op, term: term)
    }

    /// Current search-field text — the combined pattern klogg builds (headless).
    var selfTestSearchFieldText: String { tabController.selfTestSearchFieldText }

    // --- Filtered-view visibility modes (klogg visibilityBox_) ---

    /// Set the active tab's filtered-view visibility (Matches/Marks/Marks-and-matches).
    func selfTestSetFilteredVisibility(_ mode: FilteredVisibility) {
        tabController.setFilteredVisibility(mode)
    }

    /// Rows the active tab's filtered (lower) pane currently shows.
    var selfTestFilteredRowCount: Int { tabController.currentFilteredRowCount }

    /// The active tab's "N matches found." label text.
    var selfTestMatchLabelText: String { tabController.currentMatchLabelText }

    /// Render the active tab's match-count label for `count` (deterministic headless).
    func selfTestMatchLabel(forCount count: Int) -> String {
        tabController.matchLabel(forCount: count)
    }

    /// (main, filtered) scrollbar marker counts on the active tab (headless assertion).
    var selfTestScrollbarMarkerCounts: (main: Int, filtered: Int) {
        tabController.currentScrollbarMarkerCounts
    }

    // --- Color labels (headless) ---

    /// Select main-view line `line` (0-based), assign it to colour `slot`, and return
    /// the labelled text (nil if no selection). The highlighter rebuild happens via the
    /// colorLabelsDidChange notification; tests pump the runloop then assert.
    @discardableResult
    func selfTestLabelLine(_ line: Int, slot: Int) -> String? {
        tabController.currentTab?.mainView.selectLine(line)
        return tabController.applyColorLabel(slot: slot)
    }

    /// Number of colour labels currently stored.
    var selfTestColorLabelCount: Int { ColorLabelsStore.shared.labels.count }

    /// Whether a freshly-built LogHighlighter produces at least one coloured span for
    /// `text` — i.e. draw() would colour the labelled token. Proves the label reaches
    /// the render path through the same machinery the view uses.
    func selfTestHighlighterColorsLabel(text: String) -> Bool {
        let hl = LogHighlighter()       // rebuilds from the live stores in init
        return !hl.highlight(line: text).isEmpty
    }

    func selfTestClearColorLabels() { ColorLabelsStore.shared.clearAll() }

    /// Assign a literal token directly to a slot (for a snapshot showing a repeated
    /// token coloured across many lines), bypassing the line-selection path.
    func selfTestAssignLabelToken(_ token: String, slot: Int) {
        ColorLabelsStore.shared.assign(text: token, slot: slot)
    }

    /// Clear the active tab's main-view selection so a snapshot shows label colouring
    /// unobscured by the selection background.
    func selfTestClearMainSelection() { tabController.currentTab?.mainView.clearSelection() }

    /// Force the active tab's log views to rebuild compiled highlighter+label rules
    /// (the live path runs async via colorLabelsDidChange; tests need it synchronous
    /// before a snapshot).
    func selfTestRebuildHighlighters() {
        tabController.currentTab?.mainView.applyHighlighters()
        tabController.currentTab?.filteredView.applyHighlighters()
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

    // --- Dialog editor controllers (headless) ---

    /// The Highlighters editor controller (lazily created; window never shown).
    var selfTestHighlightersEditor: HighlightersWindowController { highlightersWC }
    /// The Predefined-filters editor controller.
    var selfTestPredefinedFiltersEditor: PredefinedFiltersWindowController { predefinedFiltersWC }

    // --- Preferences live-apply (headless) ---

    /// The active tab's main-view row height (changes when the font size changes), or 0.
    var selfTestMainRowHeight: CGFloat { tabController.currentTab?.mainView.rowHeight ?? 0 }

    /// The active tab's main-view font point size (tracks the font-size preference), or 0.
    var selfTestMainFontPointSize: CGFloat { tabController.currentTab?.mainView.fontPointSize ?? 0 }

    /// Headless "Save to file": write the active tab's main view to `url`. False if no tab.
    func selfTestSaveAllToFile(to url: URL) -> Bool {
        tabController.currentTab?.mainView.saveAllToFileForTest(to: url) ?? false
    }

    /// Whether the active tab's main-view gutter is currently drawn (line numbers on).
    var selfTestMainGutterWidth: CGFloat { tabController.currentTab?.mainView.gutterWidth ?? 0 }

    /// Apply preference changes to the active tab synchronously (the live path posts
    /// .preferencesDidChange async; the harness needs it applied before asserting).
    func selfTestApplyPreferencesToCurrentTab() {
        tabController.currentTab?.mainView.applyFontPreference()
        tabController.currentTab?.mainView.applyViewPreferences()
        tabController.currentTab?.filteredView.applyFontPreference()
        tabController.currentTab?.filteredView.applyViewPreferences()
    }

    // --- Line marks / context menu (headless) ---

    /// Toggle a mark on a source line in the active tab; returns whether it's marked after.
    func selfTestToggleMark(line: Int) -> Bool {
        guard let store = tabController.currentTab?.marksStore else { return false }
        store.toggle(lines: [line])
        return store.isMarked(line)
    }

    /// Whether `line` is currently marked in the active tab.
    func selfTestIsMarked(line: Int) -> Bool {
        tabController.currentTab?.marksStore.isMarked(line) ?? false
    }

    /// Number of marks in the active tab.
    var selfTestMarkCount: Int { tabController.currentTab?.marksStore.marks.count ?? 0 }

    /// Next-mark navigation (wraps), or -1 if no marks.
    func selfTestNextMark(after line: Int) -> Int {
        tabController.currentTab?.marksStore.nextMark(after: line) ?? -1
    }

    /// Clear all marks in the active tab.
    func selfTestClearMarks() { tabController.currentTab?.marksStore.clearAll() }

    /// Drive the main view's ']' / '[' mark navigation; returns the landed line or -1.
    func selfTestJumpToMark(next: Bool) -> Int {
        tabController.currentTab?.mainView.jumpToMarkForTest(next: next) ?? -1
    }

    /// Build the main view's context menu (selecting `line` first) and return the
    /// titles of its (non-separator) items, so the harness can assert klogg parity.
    func selfTestContextMenuTitles(selectingLine line: Int) -> [String] {
        guard let view = tabController.currentTab?.mainView else { return [] }
        view.selectLine(line)
        return view.contextMenuItemTitles()
    }

    /// Select a line then copy-with-line-numbers; return the pasteboard string.
    func selfTestCopyWithLineNumbers(line: Int) -> String? {
        guard let view = tabController.currentTab?.mainView else { return nil }
        view.selectLine(line)
        NSPasteboard.general.clearContents()
        view.copyWithLineNumbersForTest()
        return NSPasteboard.general.string(forType: .string)
    }

    // --- Status bar / info-line format (headless) ---

    /// Render klogg's line-position field for given inputs (Ln:N/Total ...).
    func selfTestStatusLineField(line: Int, total: Int, column: Int?, selSymbols: Int, selLines: Int) -> String {
        let sb = StatusBarView(frame: .zero)
        sb.update(filePath: "/x", lineCount: total, fileSize: 0, encoding: "UTF-8")
        sb.updatePosition(line: line, column: column, selSymbols: selSymbols, selLines: selLines)
        return sb.selfTestLineFieldText
    }

    // --- Search / QuickFind correctness (headless) ---

    /// Count matches for `pattern` by scanning the engine line-by-line with the same
    /// compile rules the views use. Independent of the async engine search so tests can
    /// assert deterministic counts (cross-checked against grep in the harness).
    func selfTestCountMatches(pattern: String, caseInsensitive: Bool, isRegex: Bool) -> Int {
        guard let engine = tabController.currentTab?.engine,
              let regex = LogDocumentView.compile(pattern: pattern,
                                                  caseInsensitive: caseInsensitive,
                                                  isRegex: isRegex) else { return -1 }
        let n = Int(engine.lineCount())
        var count = 0
        for i in 0..<n {
            guard let text = engine.lineString(at: UInt(i)) else { continue }
            let r = NSRange(location: 0, length: (text as NSString).length)
            if regex.firstMatch(in: text, options: [], range: r) != nil { count += 1 }
        }
        return count
    }

    /// Drive a QuickFind step directly (next/prev) and return the resulting current line
    /// (0-based) or -1. Seeds the needle first so the test controls the origin.
    func selfTestQuickFindFrom(line: Int, needle: String, caseInsensitive: Bool,
                               isRegex: Bool, next: Bool) -> Int {
        return tabController.selfTestQuickFind(from: line, needle: needle,
                                               caseInsensitive: caseInsensitive,
                                               isRegex: isRegex, next: next)
    }

    /// Go-to-line clamp behaviour: scroll to `oneBased` (1-based) and return the main
    /// view's first-visible line (0-based), or -1 if out of range / no file.
    func selfTestGoToLineResult(oneBased: Int) -> Int {
        // Mirror the goToLine(_:) bounds check, but read the ENGINE line count so the
        // assertion isn't gated on the view having been laid out in a real viewport
        // (headless mode has no scroll geometry). 1-based, inclusive.
        let lineCount = tabController.currentLineCount
        guard lineCount > 0, oneBased >= 1, oneBased <= lineCount else { return -1 }
        tabController.currentTab?.mainView.reloadFromEngine()
        tabController.goToLine(oneBased - 1)
        // A valid jump selects the target line; report the selected line (0-based) so
        // callers can confirm acceptance even without a live viewport.
        return tabController.currentTab?.mainView.currentLine ?? 0
    }

    /// Render the window's content view OFFSCREEN (never ordered on screen) to a PNG.
    /// Used to verify the tab strip + log rendering visually in headless QA.
    @discardableResult
    func selfTestSnapshot(to path: String, size: NSSize = NSSize(width: 900, height: 500)) -> Bool {
        guard let content = window?.contentView else { return false }
        content.frame = NSRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        // Force the log views + overview to fetch + lay out from the latest engine
        // state (async callbacks may not have been pumped yet), then lay out again so
        // the overview picks up its now-nonzero height.
        tabController.refreshCurrentTabViews()
        content.layoutSubtreeIfNeeded()
        tabController.updateStatusBar()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return false
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

