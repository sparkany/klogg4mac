//
//  AppDelegate.swift — application lifecycle.
//
//  Installs the full klogg menu bar (via AppMenu.install()) and creates the
//  main window. Handles command-line file arguments and macOS open-file events.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: MainWindowController?
    private var isSelfTest = false
    /// Set once a Finder/Dock open-file event has been handled, so
    /// `applicationDidFinishLaunching` does not also restore the previous session
    /// (which would steal focus from the file the user explicitly asked to open).
    private var didOpenFromEvent = false

    // MARK: - Launch

    // Window + menu are built in *willFinish* (not *didFinish*) so the window
    // controller already exists when AppKit delivers a cold-launch open-file event.
    // Finder "Open With" / drag-onto-icon dispatch `application(_:openFile:)` AFTER
    // applicationWillFinishLaunching and BEFORE applicationDidFinishLaunching — if the
    // controller were created in didFinish, that first file would be dropped on the
    // floor (the symptom: double-clicking a log only launched the app empty).
    func applicationWillFinishLaunching(_ notification: Notification) {
        isSelfTest = CommandLine.arguments.contains("--selftest")
        if isSelfTest {
            NSApp.setActivationPolicy(.prohibited)
            // Route every persisted store (prefs, favorites, highlighters, filters,
            // session, color-labels, scratchpad) at a throwaway suite so the harness
            // never corrupts the user's real "KloggMac" preferences. MUST happen
            // before any `.shared` store is first touched (AppMenu/MainWindowController
            // below read store state in their initialisers).
            AppDefaults.useIsolatedSuite()
        }

        // QA aid: force Light/Dark for headless appearance snapshots.
        switch ProcessInfo.processInfo.environment["KLOGG_FORCE_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        // Install the full klogg menu bar (Wave 2).
        AppMenu.install()

        windowController = MainWindowController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let wc = windowController else { return }

        if !isSelfTest {
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Open a file passed on the command line: `KloggMac <path>`.
        // Prefer the first non-flag argument that points to an existing file.
        let cliPath = CommandLine.arguments.dropFirst()
            .first(where: { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) })
        if let path = cliPath {
            wc.openFile(path: path)
        } else if !isSelfTest && !didOpenFromEvent && AppPreferences.shared.loadLastSession {
            // No file on the command line and none opened via a launch event: restore
            // the previous session if enabled.
            wc.restoreSession()
        }

        if isSelfTest {
            // Let the tab/engine settle one runloop tick, then audit and exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                SelfTest.run(windowController: wc)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Final snapshot of the open-files set (also kept current on every tab change).
        windowController?.saveSession()
    }

    // MARK: - NSApplicationDelegate: open-file events (Finder double-click, etc.)

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openIncomingFile(filename)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for path in filenames { openIncomingFile(path) }
        sender.reply(toOpenOrPrint: .success)
    }

    /// Funnel for every Finder/Dock open-file event. Creates the window controller on
    /// demand (defensive — it normally already exists from willFinishLaunching), brings
    /// the app forward, and opens the file. Marks `didOpenFromEvent` so the launch path
    /// skips session restore.
    private func openIncomingFile(_ path: String) {
        didOpenFromEvent = true
        let wc: MainWindowController
        if let existing = windowController {
            wc = existing
        } else {
            wc = MainWindowController()
            windowController = wc
        }
        if !isSelfTest {
            wc.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        wc.openFile(path: path)
    }
}
