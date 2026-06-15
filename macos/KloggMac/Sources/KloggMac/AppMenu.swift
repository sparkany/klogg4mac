//
//  AppMenu.swift — Full NSMenuBar matching klogg's menu structure.
//
//  Menu mapping from mainwindow.cpp (createMenus / createActions):
//
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │ IMPLEMENTED (functional)                                            │
//  │  File > Open…                    ⌘O                                │
//  │  File > Open from Clipboard      ⌘V    (TODO Phase 3 - disabled)   │
//  │  File > Open from URL…                 (TODO Phase 3 - disabled)   │
//  │  File > Open Recent              submenu + Clear Recent             │
//  │  File > Close                    ⌘W                                │
//  │  File > Close All                                                   │
//  │  File > Quit klogg               ⌘Q                                │
//  │                                                                     │
//  │  Edit > Copy                     ⌘C    (routed to first-responder) │
//  │  Edit > Select All               ⌘A    (routed to first-responder) │
//  │  Edit > Find…                    ⌘F    (TODO Phase 3 - disabled)   │
//  │  Edit > Go to Line…              ⌘G    (TODO Phase 3 - disabled)   │
//  │  Edit > Copy Path to Clipboard         (shows path of open file)   │
//  │  Edit > Open Containing Folder         (Finder reveal)             │
//  │  Edit > Open in Editor                 (TODO - disabled)           │
//  │  Edit > Clear Log                ⌘X    (TODO Phase 3 - disabled)   │
//  │                                                                     │
//  │  View > Opened Files             submenu (active tabs)             │
//  │  View > Overview Visible               (TODO Phase 3 - disabled)   │
//  │  View > Line Numbers (Main)            (checked state stub)        │
//  │  View > Line Numbers (Filtered)        (checked state stub)        │
//  │  View > Text Wrap                W     (TODO - disabled)           │
//  │  View > Follow File              F/F10 (TODO Phase 3 - disabled)   │
//  │  View > Reload                   ⌘R    (TODO - disabled)           │
//  │                                                                     │
//  │  Tools > Predefined Filters…           (TODO Phase 4 - disabled)   │
//  │  Tools > Scratchpad                    (TODO Phase 4 - disabled)   │
//  │                                                                     │
//  │  Highlighters > (submenu)              (TODO Phase 4 - disabled)   │
//  │                                                                     │
//  │  Encoding > (submenu)                  (TODO Phase 4 - disabled)   │
//  │                                                                     │
//  │  Favorites > (submenu)                 (TODO Phase 4 - disabled)   │
//  │                                                                     │
//  │  Help > Documentation                  opens browser               │
//  │  Help > Report Issue                   opens browser               │
//  │  Help > Join Discord                   opens browser               │
//  │  Help > Join Telegram                  opens browser               │
//  │  Help > About klogg                                                │
//  └─────────────────────────────────────────────────────────────────────┘
//
//  Stub items (no-op or disabled) are clearly marked TODO.
//  The app menu (About, Preferences, Quit) follows macOS conventions.
//

import AppKit

final class AppMenu {

    // Called once from AppDelegate.applicationDidFinishLaunching.
    static func install() {
        NSApp.mainMenu = buildMainMenu()
    }

    // MARK: - Root menu

    private static func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem())
        main.addItem(fileMenuItem())
        main.addItem(editMenuItem())
        main.addItem(viewMenuItem())
        main.addItem(toolsMenuItem())
        main.addItem(highlightersMenuItem())
        main.addItem(encodingMenuItem())
        main.addItem(favoritesMenuItem())
        main.addItem(helpMenuItem())
        return main
    }

    // MARK: - App menu (klogg)

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()

        menu.addItem(withTitle: "About klogg",
                     action: #selector(MainWindowController.showAbout(_:)),
                     keyEquivalent: "")
            .target = nil   // first-responder chain

        menu.addItem(.separator())

        // Preferences
        let prefs = menu.addItem(
            withTitle: "Preferences…",
            action: #selector(MainWindowController.showPreferences(_:)),
            keyEquivalent: ",")
        prefs.target = nil

        menu.addItem(.separator())

        menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
            .submenu = NSMenu(title: "Services")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide klogg",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit klogg",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: - File menu

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        // New Window — visible only when multi-window is enabled (Phase 4).
        let newWin = menu.addItem(
            withTitle: "New Window",
            action: #selector(MainWindowController.newWindow(_:)),
            keyEquivalent: "n")
        newWin.keyEquivalentModifierMask = [.command]
        newWin.target = nil
        newWin.isHidden = true   // TODO: show when multi-window is wired

        menu.addItem(withTitle: "Open…",
                     action: #selector(MainWindowController.openDocument(_:)),
                     keyEquivalent: "o")
            .target = nil

        // Open from Clipboard — validated via validateMenuItem (needs pasteboard text).
        let clip = menu.addItem(
            withTitle: "Open from Clipboard",
            action: #selector(MainWindowController.openFromClipboard(_:)),
            keyEquivalent: "v")
        clip.keyEquivalentModifierMask = [.command]
        clip.target = nil

        // Open from URL — download then open.
        let url = menu.addItem(
            withTitle: "Open from URL…",
            action: #selector(MainWindowController.openFromURL(_:)),
            keyEquivalent: "")
        url.target = nil

        // Open Recent submenu
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = RecentFilesMenu.shared.menu
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Close",
                     action: #selector(MainWindowController.closeCurrentTab(_:)),
                     keyEquivalent: "w")
            .target = nil

        menu.addItem(withTitle: "Close All",
                     action: #selector(MainWindowController.closeAllTabs(_:)),
                     keyEquivalent: "")
            .target = nil

        menu.addItem(.separator())

        // Preferences in File menu — macOS convention puts it in App menu but
        // klogg also has optionsAction in File menu; we leave it in App menu only
        // (NSMenuItem with .preferences menu role auto-moves on macOS).

        menu.addItem(.separator())

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")

        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")

        menu.addItem(.separator())

        // Find — QuickFind incremental find bar (Wave 6).
        let find = menu.addItem(
            withTitle: "Find…",
            action: #selector(MainWindowController.openQuickFind(_:)),
            keyEquivalent: "f")
        find.target = nil   // resolved via the responder chain to MainWindowController

        menu.addItem(.separator())

        // Go to Line — modal sheet (Wave 6).
        let goToLine = menu.addItem(
            withTitle: "Go to Line…",
            action: #selector(MainWindowController.goToLine(_:)),
            keyEquivalent: "g")
        goToLine.keyEquivalentModifierMask = [.command]
        goToLine.target = nil

        menu.addItem(.separator())

        menu.addItem(withTitle: "Copy Path to Clipboard",
                     action: #selector(MainWindowController.copyPathToClipboard(_:)),
                     keyEquivalent: "")
            .target = nil

        menu.addItem(withTitle: "Open Containing Folder",
                     action: #selector(MainWindowController.openContainingFolder(_:)),
                     keyEquivalent: "")
            .target = nil

        menu.addItem(.separator())

        // Open in Editor — opens the file in the default editor app.
        let editor = menu.addItem(
            withTitle: "Open in Editor",
            action: #selector(MainWindowController.openInEditor(_:)),
            keyEquivalent: "")
        editor.target = nil   // validated via validateMenuItem (needs an open file)

        // Clear Log — only valid for temp-backed docs; gated in validateMenuItem.
        let clear = menu.addItem(
            withTitle: "Clear Log",
            action: #selector(MainWindowController.clearLog(_:)),
            keyEquivalent: "x")
        clear.keyEquivalentModifierMask = [.command]
        clear.target = nil

        item.submenu = menu
        return item
    }

    // MARK: - View menu

    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        // Opened Files submenu — dynamically populated by TabController.
        let openedItem = NSMenuItem(title: "Opened Files", action: nil, keyEquivalent: "")
        openedItem.submenu = NSMenu(title: "Opened Files")
        openedItem.tag = MenuTag.openedFiles.rawValue
        menu.addItem(openedItem)

        menu.addItem(.separator())

        // Overview Visible — TODO Phase 3
        let overview = menu.addItem(
            withTitle: "Overview Visible",
            action: #selector(MainWindowController.toggleOverview(_:)),
            keyEquivalent: "")
        overview.target = nil
        overview.isEnabled = false   // TODO(Phase 3)

        menu.addItem(.separator())

        // Line numbers in main view
        let lnMain = menu.addItem(
            withTitle: "Line Numbers in Main View",
            action: #selector(MainWindowController.toggleMainLineNumbers(_:)),
            keyEquivalent: "")
        lnMain.target = nil
        lnMain.state = .on   // on by default
        lnMain.tag = MenuTag.lineNumbersMain.rawValue

        // Line numbers in filtered view
        let lnFiltered = menu.addItem(
            withTitle: "Line Numbers in Filtered View",
            action: #selector(MainWindowController.toggleFilteredLineNumbers(_:)),
            keyEquivalent: "")
        lnFiltered.target = nil
        lnFiltered.state = .on
        lnFiltered.tag = MenuTag.lineNumbersFiltered.rawValue

        menu.addItem(.separator())

        // Text Wrap — TODO
        let wrap = menu.addItem(
            withTitle: "Text Wrap",
            action: #selector(MainWindowController.toggleTextWrap(_:)),
            keyEquivalent: "w")
        wrap.keyEquivalentModifierMask = []   // bare 'w', no modifier (klogg default)
        wrap.target = nil
        wrap.isEnabled = false   // TODO(Phase 3)

        menu.addItem(.separator())

        // Follow File — tail -f; checkmark reflects per-tab state (validateMenuItem).
        let follow = menu.addItem(
            withTitle: "Follow File",
            action: #selector(MainWindowController.toggleFollow(_:)),
            keyEquivalent: "f")
        follow.keyEquivalentModifierMask = []   // bare 'f' (klogg default)
        follow.target = nil

        menu.addItem(.separator())

        // Reload — re-attach the current file; gated to an open file in validateMenuItem.
        let reload = menu.addItem(
            withTitle: "Reload",
            action: #selector(MainWindowController.reloadFile(_:)),
            keyEquivalent: "r")
        reload.keyEquivalentModifierMask = [.command]
        reload.target = nil

        item.submenu = menu
        return item
    }

    // MARK: - Tools menu

    private static func toolsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Tools")

        // Predefined Filters
        menu.addItem(
            withTitle: "Predefined Filters…",
            action: #selector(MainWindowController.editPredefinedFilters(_:)),
            keyEquivalent: "")
            .target = nil

        menu.addItem(.separator())

        // Colour Labels submenu — quick-assign a colour to the selected line's text
        // (⌘1–⌘9), plus a clear-all item. Mirrors klogg's ColorLabelsManager.
        let labelsItem = NSMenuItem(title: "Color Labels", action: nil, keyEquivalent: "")
        let labelsMenu = NSMenu(title: "Color Labels")
        for slot in 1...ColorLabelsStore.slotCount {
            let it = labelsMenu.addItem(
                withTitle: "Label Selection — Color \(slot)",
                action: #selector(MainWindowController.assignColorLabel(_:)),
                keyEquivalent: "\(slot)")
            it.keyEquivalentModifierMask = [.command]
            it.tag = slot
            it.target = nil
        }
        labelsMenu.addItem(.separator())
        let clearLabels = labelsMenu.addItem(
            withTitle: "Clear All Color Labels",
            action: #selector(MainWindowController.clearColorLabels(_:)),
            keyEquivalent: "")
        clearLabels.target = nil
        labelsItem.submenu = labelsMenu
        menu.addItem(labelsItem)

        menu.addItem(.separator())

        // Scratchpad (toggle show/hide)
        menu.addItem(
            withTitle: "Scratchpad",
            action: #selector(MainWindowController.showScratchpad(_:)),
            keyEquivalent: "")
            .target = nil

        item.submenu = menu
        return item
    }

    // MARK: - Highlighters menu

    private static func highlightersMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Highlighters")

        menu.addItem(
            withTitle: "Edit Highlighters…",
            action: #selector(MainWindowController.editHighlighters(_:)),
            keyEquivalent: "")
            .target = nil

        item.submenu = menu
        return item
    }

    // MARK: - Encoding menu
    //
    // Mirrors klogg's EncodingMenu::generate() (src/ui/include/encodings.h).
    // Groups and MIB numbers are taken verbatim from supportedEncodings().
    // Each item carries its MIB as tag (or -1 for Auto Detect) so
    // MainWindowController.changeEncoding(_:) can read and persist it.
    //
    // MIB → codec name mapping (IANA / QTextCodec reference):
    //   106=UTF-8, 1013=UTF-16LE, 1014=UTF-16BE, 1018=UTF-32LE, 1019=UTF-32BE
    //   82=ISO-8859-6(Arabic), 2256=Windows-1256
    //   7=ISO-8859-4(Baltic), 109=ISO-8859-13, 2257=Windows-1257
    //   110=ISO-8859-14(Celtic)
    //   8=ISO-8859-5(Cyrillic), 2084=KOI8-R, 2088=KOI8-U, 2027=macintosh-cyrillic,
    //   2086=CP866, 2251=Windows-1251
    //   2250=Windows-1250(Central European)
    //   2026=Big5(Chinese Trad.), 2025=GBK/GB2312(Chinese Simp.)
    //   5=ISO-8859-2(Eastern European)
    //   10=ISO-8859-7(Greek), 2253=Windows-1253
    //   85=ISO-8859-8(Hebrew), 2255=Windows-1255
    //   17=Shift-JIS, 18=EUC-JP, 39=ISO-2022-JP
    //   -949=EUC-KR(pseudo, Apple), 38=EUC-KR
    //   2259=TIS-620(Thai)
    //   6=ISO-8859-3(Turkish), 12=ISO-8859-9, 2254=Windows-1254
    //   3=US-ASCII, 4=ISO-8859-1, 111=ISO-8859-15, 2009=CP850, 2252=Windows-1252
    //   2258=Windows-1258(Vietnamese)

    private static let encodingGroups: [(String, [(Int, String)])] = [
        ("Unicode",           [(106, "UTF-8"), (1013, "UTF-16 LE"), (1014, "UTF-16 BE"),
                               (1018, "UTF-32 LE"), (1019, "UTF-32 BE")]),
        ("Arabic",            [(82, "ISO-8859-6"), (2256, "Windows-1256")]),
        ("Baltic",            [(7, "ISO-8859-4"), (109, "ISO-8859-13"), (2257, "Windows-1257")]),
        ("Celtic",            [(110, "ISO-8859-14")]),
        ("Cyrillic",          [(8, "ISO-8859-5"), (2084, "KOI8-R"), (2088, "KOI8-U"),
                               (2086, "CP866"), (2251, "Windows-1251")]),
        ("Central European",  [(2250, "Windows-1250")]),
        ("Chinese",           [(2026, "Big5"), (2025, "GBK / GB2312")]),
        ("Eastern European",  [(5, "ISO-8859-2")]),
        ("Greek",             [(10, "ISO-8859-7"), (2253, "Windows-1253")]),
        ("Hebrew",            [(85, "ISO-8859-8"), (2255, "Windows-1255")]),
        ("Japanese",          [(17, "Shift-JIS"), (18, "EUC-JP"), (39, "ISO-2022-JP")]),
        ("Korean",            [(38, "EUC-KR")]),
        ("Thai",              [(2259, "TIS-620")]),
        ("Turkish",           [(6, "ISO-8859-3"), (12, "ISO-8859-9"), (2254, "Windows-1254")]),
        ("Western European",  [(4, "ISO-8859-1"), (111, "ISO-8859-15"),
                               (2252, "Windows-1252"), (2009, "CP850")]),
        ("Vietnamese",        [(2258, "Windows-1258")]),
    ]

    private static func encodingMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Encoding")

        // Auto Detect (MIB = -1, tag = -1)
        let auto = menu.addItem(
            withTitle: "Auto Detect",
            action: #selector(MainWindowController.changeEncoding(_:)),
            keyEquivalent: "")
        auto.target = nil
        auto.tag    = -1
        auto.state  = (AppPreferences.shared.defaultEncodingMib < 0) ? .on : .off

        menu.addItem(.separator())

        // System encoding shortcut (shows system locale encoding as a convenience item)
        let sysItem = menu.addItem(
            withTitle: "System Default",
            action: #selector(MainWindowController.changeEncoding(_:)),
            keyEquivalent: "")
        sysItem.target = nil
        sysItem.tag    = 0   // tag=0 → "system default" sentinel

        menu.addItem(.separator())

        // Grouped encoding submenus
        let mib = AppPreferences.shared.defaultEncodingMib
        for (groupName, encodings) in encodingGroups {
            let subItem = NSMenuItem(title: groupName, action: nil, keyEquivalent: "")
            let subMenu = NSMenu(title: groupName)
            for (mibNum, encName) in encodings {
                let it = subMenu.addItem(
                    withTitle: encName,
                    action: #selector(MainWindowController.changeEncoding(_:)),
                    keyEquivalent: "")
                it.target = nil
                it.tag    = mibNum
                it.state  = (mib == mibNum) ? .on : .off
            }
            subItem.submenu = subMenu
            menu.addItem(subItem)
        }

        item.submenu = menu
        return item
    }

    // MARK: - Favorites menu

    private static func favoritesMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = FavoritesMenu.shared.menu
        return item
    }

    // MARK: - Help menu

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")

        menu.addItem(withTitle: "klogg Documentation",
                     action: #selector(MainWindowController.showDocumentation(_:)),
                     keyEquivalent: "")
            .target = nil

        menu.addItem(.separator())

        menu.addItem(withTitle: "Report Issue",
                     action: #selector(MainWindowController.reportIssue(_:)),
                     keyEquivalent: "")
            .target = nil

        menu.addItem(withTitle: "Join Discord",
                     action: #selector(MainWindowController.joinDiscord(_:)),
                     keyEquivalent: "")
            .target = nil

        menu.addItem(withTitle: "Join Telegram",
                     action: #selector(MainWindowController.joinTelegram(_:)),
                     keyEquivalent: "")
            .target = nil

        menu.addItem(.separator())

        menu.addItem(withTitle: "Generate Debug Report",
                     action: #selector(MainWindowController.generateDump(_:)),
                     keyEquivalent: "")
            .target = nil

        menu.addItem(.separator())

        menu.addItem(withTitle: "About klogg",
                     action: #selector(MainWindowController.showAbout(_:)),
                     keyEquivalent: "")
            .target = nil

        item.submenu = menu
        return item
    }
}

// MARK: - Menu tags

enum MenuTag: Int {
    case openedFiles = 1001
    case lineNumbersMain = 1002
    case lineNumbersFiltered = 1003
}

// MARK: - RecentFilesMenu

/// Manages the "Open Recent" submenu, kept in sync with RecentFiles.shared.
final class RecentFilesMenu: NSObject {

    static let shared = RecentFilesMenu()

    let menu = NSMenu(title: "Open Recent")

    private override init() {
        super.init()
        rebuild()
        RecentFiles.shared.onChange = { [weak self] _ in self?.rebuild() }
    }

    func rebuild() {
        menu.removeAllItems()
        let paths = RecentFiles.shared.paths
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let it = NSMenuItem(
                title: name,
                action: #selector(MainWindowController.openRecentFile(_:)),
                keyEquivalent: "")
            it.toolTip = path
            it.representedObject = path
            it.target = nil   // first-responder chain → MainWindowController
            menu.addItem(it)
        }
        if !paths.isEmpty { menu.addItem(.separator()) }
        // Use addItem(withTitle:) — NOT addItem(_:) after building a separate item —
        // to avoid "item already in another menu" when the separator was just added.
        let clear = menu.addItem(
            withTitle: "Clear Recents",
            action: #selector(MainWindowController.clearRecentFiles(_:)),
            keyEquivalent: "")
        clear.target = nil
    }
}

// MARK: - FavoritesMenu

/// Manages the "Favorites" menu: an Add/Remove pair (validated via the responder
/// chain) followed by one item per favorited file. Kept in sync with
/// FavoritesStore.shared.
final class FavoritesMenu: NSObject {

    static let shared = FavoritesMenu()

    let menu = NSMenu(title: "Favorites")

    private override init() {
        super.init()
        rebuild()
        FavoritesStore.shared.onChange = { [weak self] _ in self?.rebuild() }
    }

    func rebuild() {
        menu.removeAllItems()

        let add = menu.addItem(
            withTitle: "Add to Favorites",
            action: #selector(MainWindowController.addToFavorites(_:)),
            keyEquivalent: "")
        add.target = nil   // validated in MainWindowController.validateMenuItem

        let remove = menu.addItem(
            withTitle: "Remove from Favorites",
            action: #selector(MainWindowController.removeFromFavorites(_:)),
            keyEquivalent: "")
        remove.target = nil

        let paths = FavoritesStore.shared.paths
        if !paths.isEmpty {
            menu.addItem(.separator())
            for path in paths {
                let name = (path as NSString).lastPathComponent
                let it = NSMenuItem(
                    title: name,
                    action: #selector(MainWindowController.openFavorite(_:)),
                    keyEquivalent: "")
                it.toolTip = path
                it.representedObject = path
                it.target = nil
                menu.addItem(it)
            }
        }
    }
}
