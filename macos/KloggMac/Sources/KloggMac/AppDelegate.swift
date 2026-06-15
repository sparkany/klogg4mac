//
//  AppDelegate.swift — application lifecycle.
//
//  Installs the full klogg menu bar (via AppMenu.install()) and creates the
//  main window. Handles command-line file arguments and macOS open-file events.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install the full klogg menu bar (Wave 2).
        AppMenu.install()

        let wc = MainWindowController()
        wc.showWindow(nil)
        windowController = wc
        NSApp.activate(ignoringOtherApps: true)

        // Open a file passed on the command line: `KloggMac <path>`.
        // Prefer the first non-flag argument that points to an existing file.
        if let path = CommandLine.arguments.dropFirst()
                .first(where: { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }) {
            wc.openFile(path: path)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - NSApplicationDelegate: open-file events (Finder double-click, etc.)

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        windowController?.openFile(path: filename)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames { windowController?.openFile(path: path) }
    }
}
