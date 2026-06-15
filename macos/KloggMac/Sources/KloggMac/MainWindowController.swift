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
        }
    }

    // MARK: - File open

    /// Open a file by path — called from menus, command-line args, drag-drop, and recent files.
    func openFile(path: String) {
        tabController.openFile(path: path)
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
        // TODO(Phase 3): open text from clipboard as a virtual file
    }

    @objc func openFromURL(_ sender: Any?) {
        // TODO(Phase 3): download/open from URL
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
        // TODO(Phase 3): clear file / truncate
    }

    @objc func openQuickFind(_ sender: Any?) {
        tabController.focusSearchBar()
    }

    @objc func goToLine(_ sender: Any?) {
        // TODO(Phase 3): show go-to-line dialog
    }

    // MARK: - View menu actions

    @objc func toggleOverview(_ sender: Any?) {
        // TODO(Phase 3): show/hide overview minimap
    }

    @objc func toggleMainLineNumbers(_ sender: NSMenuItem) {
        // TODO(Phase 3): wire to LogScrollView's gutter visibility
        sender.state = (sender.state == .on) ? .off : .on
    }

    @objc func toggleFilteredLineNumbers(_ sender: NSMenuItem) {
        // TODO(Phase 3): wire to filtered view's gutter visibility
        sender.state = (sender.state == .on) ? .off : .on
    }

    @objc func toggleTextWrap(_ sender: Any?) {
        // TODO(Phase 3): toggle text wrap in log views
    }

    @objc func toggleFollow(_ sender: Any?) {
        // TODO(Phase 3): toggle file-watch / follow mode
    }

    @objc func reloadFile(_ sender: Any?) {
        // TODO(Phase 3): re-attach file in current tab
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
        fputs("[scratchpad] toggled; window visible=\(scratchpadWC.window?.isVisible == true)\n", stderr)
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

        // Persist the chosen MIB and log for runtime verification.
        AppPreferences.shared.defaultEncodingMib = mib
        fputs("[encoding] changeEncoding: mib=\(mib) title='\(sender.title)'\n", stderr)

        // Update the status bar encoding field.
        tabController.statusBar?.updateEncoding(mib == -1 ? "Auto" : sender.title)

        // TODO(Phase 5): re-index the current file with the chosen encoding via engine.
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
        // TODO(Phase 4): favorite files
    }

    @objc func removeFromFavorites(_ sender: Any?) {
        // TODO(Phase 4): favorite files
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
        fputs("[prefs] showPreferences called; window visible=\(preferencesWC.window?.isVisible == true)\n", stderr)
    }

    // MARK: - NSMenuItemValidation

    // NSMenuItemValidation -- NSWindowController inherits this via NSResponder.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasFile = tabController.currentFilePath != nil
        switch menuItem.action {
        case #selector(closeCurrentTab(_:)),
             #selector(closeAllTabs(_:)):
            return hasFile
        case #selector(copyPathToClipboard(_:)),
             #selector(openContainingFolder(_:)):
            return hasFile
        case #selector(openQuickFind(_:)),
             #selector(stopLoading(_:)):
            return hasFile
        case #selector(clearRecentFiles(_:)):
            return !RecentFiles.shared.paths.isEmpty
        default:
            return true
        }
    }
}

