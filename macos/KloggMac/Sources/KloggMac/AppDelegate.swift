//
//  AppDelegate.swift — application lifecycle + menu bar.
//
//  The menu/toolbar here are a starting skeleton owned by the `shell` role; the
//  1:1 menu structure from klogg's `menu.cpp` is filled in during Phase 2.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write("[verify] didFinishLaunching args=\(CommandLine.arguments)\n".data(using: .utf8)!)
        installMainMenu()
        let wc = MainWindowController()
        wc.showWindow(nil)
        windowController = wc
        NSApp.activate(ignoringOtherApps: true)

        // Open a file passed on the command line: `KloggMac <path>`.
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
           FileManager.default.fileExists(atPath: path) {
            wc.openFile(path: path)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu (skeleton)

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About klogg", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit klogg",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // File menu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(MainWindowController.openDocument(_:)),
                         keyEquivalent: "o")
        fileItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }
}
