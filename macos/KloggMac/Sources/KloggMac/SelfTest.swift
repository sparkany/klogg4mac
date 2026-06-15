//
//  SelfTest.swift — headless QA harness for klogg4mac.
//
//  Runs with `KloggMac --selftest [logfile]`. The app sets activation policy to
//  .prohibited and never orders a window on screen, so nothing is displayed. It
//  introspects the menu bar + toolbar exactly as AppKit's auto-enable does
//  (NSApp.target(forAction:) + validateMenuItem) and runs behavior assertions
//  (open file / close tab), printing a report to stdout. Used to find and verify
//  fixes for non-functional / disabled controls without popping UI.
//

import AppKit

enum SelfTest {

    static func run(windowController wc: MainWindowController) {
        var out = "===== KLOGG SELFTEST =====\n"
        out += auditMenu()
        out += "\n" + auditToolbar(wc)
        out += "\n" + snapshots(wc)
        out += "\n" + behaviorTests(wc)
        out += "===== END SELFTEST =====\n"
        FileHandle.standardError.write(out.data(using: .utf8)!)
    }

    // MARK: - Offscreen snapshots

    /// Render the loaded file (with line numbers on, then off) to PNGs under the
    /// directory given by KLOGG_SNAPSHOT_DIR (default: the system temp dir). Verifies
    /// the custom tab strip + log rendering survive headlessly.
    private static func snapshots(_ wc: MainWindowController) -> String {
        var s = "--- SNAPSHOTS ---\n"
        guard wc.selfTestTabCount > 0 else {
            s += "SKIP snapshots (no file opened)\n"
            return s
        }
        let dir = ProcessInfo.processInfo.environment["KLOGG_SNAPSHOT_DIR"]
            ?? NSTemporaryDirectory()
        let onPath  = (dir as NSString).appendingPathComponent("klogg-snapshot-linenumbers-on.png")
        let offPath = (dir as NSString).appendingPathComponent("klogg-snapshot-linenumbers-off.png")

        let saved = AppPreferences.shared.lineNumbersInMain
        AppPreferences.shared.lineNumbersInMain = true
        let okOn = wc.selfTestSnapshot(to: onPath)
        AppPreferences.shared.lineNumbersInMain = false
        let okOff = wc.selfTestSnapshot(to: offPath)
        AppPreferences.shared.lineNumbersInMain = saved   // restore

        s += okOn  ? "PASS wrote \(onPath)\n"  : "FAIL snapshot (line numbers on)\n"
        s += okOff ? "PASS wrote \(offPath)\n" : "FAIL snapshot (line numbers off)\n"
        return s
    }

    // MARK: - Menu audit

    private static func auditMenu() -> String {
        var s = "--- MENU AUDIT (action | targetFound | validate | staticEnabled) ---\n"
        guard let main = NSApp.mainMenu else { return s + "  <no main menu>\n" }
        for top in main.items {
            guard let sub = top.submenu else { continue }
            s += "[\(top.title)] autoenables=\(sub.autoenablesItems)\n"
            s += auditMenu(sub, indent: "  ")
        }
        return s
    }

    private static func auditMenu(_ menu: NSMenu, indent: String) -> String {
        var s = ""
        for item in menu.items {
            if item.isSeparatorItem { continue }
            if let sub = item.submenu {
                s += "\(indent)[\(item.title)]\n"
                s += auditMenu(sub, indent: indent + "  ")
                continue
            }
            let actionStr = item.action.map { NSStringFromSelector($0) } ?? "<none>"
            var targetFound = "-"
            var validate = "-"
            if let action = item.action {
                let target = NSApp.target(forAction: action, to: item.target, from: item)
                targetFound = target != nil ? "YES" : "NO"
                if let v = target as? NSMenuItemValidation {
                    validate = v.validateMenuItem(item) ? "ok" : "FALSE"
                } else if target != nil {
                    validate = "ok"
                }
            }
            // Flag only items the user actually sees greyed-out. (targetFound is
            // unreliable in headless mode because no window is key, so the responder
            // chain is empty — we don't flag on it.)
            let broken = (item.action == nil) || !item.isEnabled
            let mark = broken ? "  ⚠️" : ""
            s += "\(indent)\(item.title.isEmpty ? "<untitled>" : item.title)"
            s += "  | \(actionStr) | tgt=\(targetFound) | val=\(validate) | en=\(item.isEnabled)\(mark)\n"
        }
        return s
    }

    // MARK: - Toolbar audit

    private static func auditToolbar(_ wc: MainWindowController) -> String {
        var s = "--- TOOLBAR AUDIT (isEnabled | action | targetFound) ---\n"
        guard let tb = wc.selfTestToolbar else { return s + "  <no toolbar>\n" }
        if tb.items.isEmpty { s += "  <toolbar has no items yet (window not shown)>\n" }
        for item in tb.items {
            let actionStr = item.action.map { NSStringFromSelector($0) } ?? "<none>"
            var targetFound = "-"
            if let action = item.action {
                targetFound = NSApp.target(forAction: action, to: item.target, from: item) != nil ? "YES" : "NO"
            }
            let broken = !item.isEnabled || (item.action == nil && item.view == nil)
            s += "  \(item.label.isEmpty ? item.itemIdentifier.rawValue : item.label)"
            s += "  | en=\(item.isEnabled) | \(actionStr) | tgt=\(targetFound)\(broken ? "  ⚠️" : "")\n"
        }
        return s
    }

    // MARK: - Behavior tests

    private static func behaviorTests(_ wc: MainWindowController) -> String {
        var s = "--- BEHAVIOR TESTS ---\n"
        let startCount = wc.selfTestTabCount
        s += "tabs at start: \(startCount)\n"

        guard startCount > 0 else {
            s += "SKIP behavior tests (no file opened; pass a log path as the last arg)\n"
            return s
        }
        let openedPath = wc.selfTestCurrentFilePath ?? "<unknown>"

        // 1) Favorites round-trip: toggle on, assert stored; toggle off, assert gone.
        let wasFavorite = wc.selfTestCurrentIsFavorite
        wc.selfTestToggleFavorite()
        let afterAdd = wc.selfTestCurrentIsFavorite
        wc.selfTestToggleFavorite()
        let afterRemove = wc.selfTestCurrentIsFavorite
        s += (afterAdd && !afterRemove)
            ? "PASS favorites toggle round-trip (add=\(afterAdd), remove=\(afterRemove))\n"
            : "FAIL favorites toggle round-trip (was=\(wasFavorite) add=\(afterAdd) remove=\(afterRemove))\n"

        // 2) Line-number pref round-trip: flip main, assert persisted value flips back.
        let lnBefore = AppPreferences.shared.lineNumbersInMain
        AppPreferences.shared.lineNumbersInMain.toggle()
        let lnAfter = AppPreferences.shared.lineNumbersInMain
        AppPreferences.shared.lineNumbersInMain = lnBefore   // restore
        s += (lnAfter == !lnBefore)
            ? "PASS lineNumbersInMain toggle: \(lnBefore) -> \(lnAfter)\n"
            : "FAIL lineNumbersInMain toggle: \(lnBefore) -> \(lnAfter)\n"

        // 3) Reload preserves the line count (re-attaches the same path).
        let lcBefore = wc.selfTestCurrentLineCount
        wc.reloadFile(nil)
        let lcAfter = wc.selfTestCurrentLineCount
        s += (lcAfter == lcBefore && lcBefore >= 0)
            ? "PASS reload preserves lineCount: \(lcBefore) -> \(lcAfter)\n"
            : "FAIL reload lineCount: \(lcBefore) -> \(lcAfter)\n"

        // 4) Close a SPECIFIC tab: open a second file, close tab index 0, assert the
        //    surviving tab is the second one (not just "count dropped").
        let secondPath = "\(openedPath).klogg-selftest-second"
        FileManager.default.createFile(atPath: secondPath, contents: Data("x\ny\n".utf8))
        wc.selfTestOpen(secondPath)
        let twoCount = wc.selfTestTabCount
        wc.selfTestCloseTab(at: 0)              // close the first (original) tab
        let afterCloseSpecific = wc.selfTestTabCount
        let survivor = wc.selfTestCurrentFilePath
        s += (twoCount == startCount + 1
              && afterCloseSpecific == twoCount - 1
              && survivor == secondPath)
            ? "PASS close-specific-tab: closed index 0, survivor=\(survivor.map { ($0 as NSString).lastPathComponent } ?? "nil")\n"
            : "FAIL close-specific-tab: two=\(twoCount) after=\(afterCloseSpecific) survivor=\(survivor ?? "nil")\n"
        try? FileManager.default.removeItem(atPath: secondPath)

        // 5) Close remaining tab(s) — original close-current behavior still works.
        let preClose = wc.selfTestTabCount
        wc.closeCurrentTab(nil)
        let afterClose = wc.selfTestTabCount
        s += afterClose == preClose - 1
            ? "PASS close current tab: \(preClose) -> \(afterClose)\n"
            : "FAIL close current tab: \(preClose) -> \(afterClose) (expected \(preClose - 1))\n"
        return s
    }
}
