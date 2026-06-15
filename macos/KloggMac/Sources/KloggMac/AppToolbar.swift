//
//  AppToolbar.swift — NSToolbar matching klogg's toolbar layout.
//
//  klogg toolbar (from mainwindow.cpp createToolBars):
//    Open | Reload | Follow | ★ Favorites | [path / info line] | Stop | ⋮ | Scratchpad
//
//  Non-functional items (Follow, Reload, Stop, Scratchpad, Favorites) are present
//  and laid out correctly; they are disabled with a TODO comment until the
//  corresponding engine feature (file watch, scratchpad) is wired in a later wave.
//
//  The path/info status view (StatusBarView) stretches in the middle, mirroring
//  klogg's infoLine + sizeField + dateField + encodingField + lineNbField.
//

import AppKit

// MARK: - Identifier constants

extension NSToolbarItem.Identifier {
    static let kloggOpen       = NSToolbarItem.Identifier("klogg.open")
    static let kloggReload     = NSToolbarItem.Identifier("klogg.reload")
    static let kloggFollow     = NSToolbarItem.Identifier("klogg.follow")
    static let kloggFavorite   = NSToolbarItem.Identifier("klogg.favorite")
    static let kloggInfo       = NSToolbarItem.Identifier("klogg.info")      // StatusBarView
    static let kloggStop       = NSToolbarItem.Identifier("klogg.stop")
    static let kloggScratchpad = NSToolbarItem.Identifier("klogg.scratchpad")
}

// MARK: - AppToolbar

final class AppToolbar: NSObject, NSToolbarDelegate {

    /// The hosted status bar view — exposed so TabController can update it.
    let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 22))

    // Action target for Open (wired by the window controller).
    weak var openTarget: AnyObject?
    @objc var openAction: Selector = #selector(AppMenuActions.openDocument(_:))

    func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "klogg.toolbar")
        tb.delegate = self
        tb.allowsUserCustomization = false
        tb.autosavesConfiguration = false
        tb.displayMode = .iconOnly
        return tb
    }

    // MARK: - NSToolbarDelegate

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {

        switch itemIdentifier {

        case .kloggOpen:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open"
            item.paletteLabel = "Open File"
            item.toolTip = "Open a log file (⌘O)"
            if let img = NSImage(systemSymbolName: "folder.badge.plus",
                                 accessibilityDescription: "Open") {
                item.image = img
            }
            item.action = #selector(AppMenuActions.openDocument(_:))
            item.target = nil   // first responder chain
            return item

        case .kloggReload:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reload"
            item.paletteLabel = "Reload File"
            item.toolTip = "Reload the current file (⌘R)"
            if let img = NSImage(systemSymbolName: "arrow.clockwise",
                                 accessibilityDescription: "Reload") {
                item.image = img
            }
            item.action = #selector(AppMenuActions.reloadFile(_:))
            item.target = nil   // first responder chain (validated by MainWindowController)
            return item

        case .kloggFollow:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Follow"
            item.paletteLabel = "Follow File"
            item.toolTip = "Follow the file for new content (tail -f)"
            if let img = NSImage(systemSymbolName: "arrow.down.to.line",
                                 accessibilityDescription: "Follow") {
                item.image = img
            }
            item.action = #selector(AppMenuActions.toggleFollow(_:))
            item.target = nil   // first responder chain (validated by MainWindowController)
            return item

        case .kloggFavorite:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Favorite"
            item.paletteLabel = "Add to Favorites"
            item.toolTip = "Toggle current file in favorites"
            if let img = NSImage(systemSymbolName: "star",
                                 accessibilityDescription: "Favorite") {
                item.image = img
            }
            item.action = #selector(AppMenuActions.toggleFavorite(_:))
            item.target = nil   // first responder chain (validated by MainWindowController)
            return item

        case .kloggInfo:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "File Info"
            item.view = statusBar
            // Let the view's intrinsic content size / constraints govern sizing.
            // (minSize/maxSize deprecated in macOS 12; constraints on the view are preferred.)
            statusBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            return item

        case .kloggStop:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Stop"
            item.paletteLabel = "Stop Loading"
            item.toolTip = "Stop loading the current file (Esc)"
            if let img = NSImage(systemSymbolName: "stop.circle",
                                 accessibilityDescription: "Stop") {
                item.image = img
            }
            item.action = #selector(AppMenuActions.stopLoading(_:))
            item.target = nil
            return item

        case .kloggScratchpad:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Scratchpad"
            item.paletteLabel = "Open Scratchpad"
            item.toolTip = "Open scratchpad"
            if let img = NSImage(systemSymbolName: "note.text",
                                 accessibilityDescription: "Scratchpad") {
                item.image = img
            }
            item.action = #selector(AppMenuActions.showScratchpad(_:))
            item.target = nil   // first responder chain
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .kloggOpen,
            .kloggReload,
            .kloggFollow,
            .kloggFavorite,
            .kloggInfo,
            .kloggStop,
            .flexibleSpace,
            .kloggScratchpad,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .kloggOpen, .kloggReload, .kloggFollow, .kloggFavorite,
            .kloggInfo, .kloggStop, .kloggScratchpad,
            .flexibleSpace, .space,
        ]
    }
}

// MARK: - AppMenuActions (action-name namespace for toolbar targets)

/// Formal action names for toolbar items that route through the responder chain.
/// MainWindowController adopts these so the toolbar buttons connect properly.
@objc protocol AppMenuActions {
    @objc optional func openDocument(_ sender: Any?)
    @objc optional func stopLoading(_ sender: Any?)
    @objc optional func reloadFile(_ sender: Any?)
    @objc optional func toggleFollow(_ sender: Any?)
    @objc optional func toggleFavorite(_ sender: Any?)
    @objc optional func showScratchpad(_ sender: Any?)
}
