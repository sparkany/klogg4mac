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
        out += "\n" + behaviorTests(wc)
        out += "===== END SELFTEST =====\n"
        FileHandle.standardError.write(out.data(using: .utf8)!)
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

        // Close-tab test (only meaningful if a file was opened via the arg).
        if startCount > 0 {
            wc.closeCurrentTab(nil)
            let afterClose = wc.selfTestTabCount
            s += afterClose == startCount - 1
                ? "PASS close current tab: \(startCount) -> \(afterClose)\n"
                : "FAIL close current tab: \(startCount) -> \(afterClose) (expected \(startCount - 1))\n"
        } else {
            s += "SKIP close-tab (no file opened; pass a log path as the last arg)\n"
        }
        return s
    }
}
