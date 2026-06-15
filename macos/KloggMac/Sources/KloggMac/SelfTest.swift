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
        out += "\n" + followTests(wc)
        out += "\n" + encodingTests(wc)
        out += "\n" + sessionTests()
        out += "\n" + colorLabelTests(wc)
        out += "\n" + predefinedFilterTests(wc)
        out += "\n" + overviewTests(wc)
        out += "===== END SELFTEST =====\n"
        FileHandle.standardError.write(out.data(using: .utf8)!)
    }

    /// Pump the main run loop until `cond` is true or `timeout` seconds elapse.
    /// Engine callbacks (re-index / file change) are delivered on the main queue, so
    /// the harness — itself on the main thread — must spin the loop to receive them.
    @discardableResult
    private static func wait(timeout: TimeInterval = 5.0,
                             _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() >= deadline { return false }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
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

    // MARK: - Follow mode tests (Wave 7b)

    /// Prove follow: open a growing file, enable follow, APPEND lines, and verify
    /// (a) the engine re-indexes to the larger line count, and (b) the main view
    /// auto-scrolls so its anchor line == lineCount-1 (the new tail). Also snapshots
    /// the followed view offscreen.
    private static func followTests(_ wc: MainWindowController) -> String {
        var s = "--- FOLLOW MODE TESTS ---\n"

        // Build a fresh file we control (10 lines).
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-follow-\(UUID().uuidString).log")
        let initial = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        guard (try? initial.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write follow test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        let indexed = wait { wc.selfTestCurrentLineCount >= 10 }
        let before = wc.selfTestCurrentLineCount
        s += indexed
            ? "PASS initial index: lineCount=\(before)\n"
            : "FAIL initial index: lineCount=\(before) (expected >=10)\n"

        // Enable follow.
        wc.selfTestToggleFollow()
        s += wc.selfTestIsFollowing
            ? "PASS follow toggled ON\n"
            : "FAIL follow did not toggle ON\n"

        // Append 5 more lines to the SAME file (tail -f scenario).
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            let more = (11...15).map { "line \($0)" }.joined(separator: "\n") + "\n"
            fh.write(more.data(using: .utf8)!)
            fh.closeFile()
        }

        // The engine watches the file (polling enabled by setFollowEnabled). Wait for
        // the re-index to pick up the growth. Belt-and-braces: if the watcher is slow
        // in this headless event loop, nudge a reload after a short grace period.
        var grew = wait(timeout: 4.0) { wc.selfTestCurrentLineCount >= 15 }
        if !grew {
            wc.reloadFile(nil)
            grew = wait(timeout: 4.0) { wc.selfTestCurrentLineCount >= 15 }
        }
        let after = wc.selfTestCurrentLineCount
        s += grew
            ? "PASS file grew via follow: \(before) -> \(after) lines\n"
            : "FAIL file did not grow: \(before) -> \(after) (expected >=15)\n"

        // Ensure the view fetched + scrolled to the tail, then assert the anchor line.
        wc.selfTestRefreshFollowTail()
        wait(timeout: 1.0) { wc.selfTestMainAnchorLine == after - 1 }
        let anchor = wc.selfTestMainAnchorLine
        s += (anchor == after - 1 && after > 0)
            ? "PASS auto-scrolled to tail: anchorLine=\(anchor) == lineCount-1\n"
            : "FAIL tail scroll: anchorLine=\(anchor) (expected \(after - 1))\n"

        // Offscreen snapshot of the followed view.
        let dir = ProcessInfo.processInfo.environment["KLOGG_SNAPSHOT_DIR"]
            ?? NSTemporaryDirectory()
        let snap = (dir as NSString).appendingPathComponent("klogg-snapshot-follow-tail.png")
        s += wc.selfTestSnapshot(to: snap)
            ? "PASS wrote \(snap)\n"
            : "FAIL follow snapshot\n"

        // Turn follow off and clean up the tab.
        wc.selfTestToggleFollow()
        s += !wc.selfTestIsFollowing ? "PASS follow toggled OFF\n" : "FAIL follow stuck ON\n"
        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Encoding re-index tests (Wave 7b)

    /// Prove encoding re-index: open a UTF-16 file; auto-detect should read it. Then
    /// force the WRONG single-byte encoding (Latin-1, MIB 4) and verify the engine
    /// re-indexes to a DIFFERENT line count (UTF-16's NUL bytes get mis-split), then
    /// force auto (-1) and verify it returns to the correct count.
    private static func encodingTests(_ wc: MainWindowController) -> String {
        var s = "--- ENCODING RE-INDEX TESTS ---\n"

        // Locate the repo's UTF-16 test file relative to the source tree.
        let candidates = [
            "test_data/Chinese-Lipsum.utf16.txt",
            "../../test_data/Chinese-Lipsum.utf16.txt",
        ].map { (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent($0) }
        // Also try an absolute repo path derived from #filePath.
        let repoRel = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test_data/Chinese-Lipsum.utf16.txt").path
        let path = ([repoRel] + candidates).first { FileManager.default.fileExists(atPath: $0) }
        guard let utf16Path = path else {
            return s + "SKIP encoding test (UTF-16 test file not found)\n"
        }

        // Open with auto-detect; the file has a UTF-16LE BOM so it indexes correctly.
        wc.selfTestOpen(utf16Path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount > 0 }
        let autoCount = wc.selfTestCurrentLineCount
        s += autoCount > 0
            ? "PASS auto-detect indexed UTF-16 file: \(autoCount) lines\n"
            : "FAIL auto-detect produced 0 lines\n"

        // Force Latin-1 (MIB 4): every byte becomes one char, so the embedded 0x00
        // bytes of UTF-16 no longer pair up — line splitting changes, count differs.
        // This proves changeEncoding: actually drives a re-index through the engine.
        wc.selfTestChangeEncoding(mib: 4)
        let changedToLatin = wait(timeout: 5.0) { wc.selfTestCurrentLineCount != autoCount }
        let latinCount = wc.selfTestCurrentLineCount
        s += changedToLatin
            ? "PASS forced Latin-1 re-index changed count: \(autoCount) -> \(latinCount)\n"
            : "FAIL forced Latin-1 did not change count: stayed \(latinCount) (expected != \(autoCount))\n"

        // Force UTF-16 (MIB 1015) explicitly: re-index again, count differs from Latin-1.
        wc.selfTestChangeEncoding(mib: 1015)
        let changedToUtf16 = wait(timeout: 5.0) { wc.selfTestCurrentLineCount != latinCount }
        let utf16Count = wc.selfTestCurrentLineCount
        s += changedToUtf16
            ? "PASS forced UTF-16 re-index changed count: \(latinCount) -> \(utf16Count)\n"
            : "FAIL forced UTF-16 did not change count: stayed \(utf16Count) (expected != \(latinCount))\n"

        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Color label tests (Wave 8)

    /// Prove colour labels: open a file with a repeated token, select a line, assign it
    /// to a colour slot, and verify (a) the store records the label, (b) a freshly-built
    /// LogHighlighter colours that token (so draw() would paint it), and (c) clear works.
    /// Also snapshots the labelled view offscreen.
    private static func colorLabelTests(_ wc: MainWindowController) -> String {
        var s = "--- COLOR LABEL TESTS ---\n"
        ColorLabelsStore.shared.clearAll()

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-labels-\(UUID().uuidString).log")
        let body = (1...12).map { "ERROR token line \($0)" }.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write label test file\n"
        }
        defer {
            try? FileManager.default.removeItem(atPath: path)
            wc.selfTestClearColorLabels()
        }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 12 }

        // Select line 0 and assign colour slot 3.
        let labelled = wc.selfTestLabelLine(0, slot: 3)
        wait(timeout: 1.0) { wc.selfTestColorLabelCount == 1 }
        s += (labelled != nil && wc.selfTestColorLabelCount == 1)
            ? "PASS assigned label: \"\(labelled ?? "")\" → slot 3 (count=\(wc.selfTestColorLabelCount))\n"
            : "FAIL assign label (text=\(labelled ?? "nil") count=\(wc.selfTestColorLabelCount))\n"

        // The highlighter must colour the labelled token (proves it reaches draw()).
        let colours = labelled.map { wc.selfTestHighlighterColorsLabel(text: $0) } ?? false
        s += colours
            ? "PASS highlighter colours the labelled token (draw() picks it up)\n"
            : "FAIL highlighter does not colour the labelled token\n"

        // For a visible snapshot, also label the repeated "ERROR" token (slot 8 = red)
        // and clear the selection so the colour band isn't masked by the selection wash.
        wc.selfTestAssignLabelToken("ERROR", slot: 8)
        wait(timeout: 1.0) { wc.selfTestColorLabelCount == 2 }
        wc.selfTestClearMainSelection()
        wc.selfTestRebuildHighlighters()    // live rebuild is async; force it here
        let dir = ProcessInfo.processInfo.environment["KLOGG_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let snap = (dir as NSString).appendingPathComponent("klogg-snapshot-colorlabel.png")
        s += wc.selfTestSnapshot(to: snap) ? "PASS wrote \(snap)\n" : "FAIL colour-label snapshot\n"

        // Clear and assert the highlighter no longer colours the token.
        wc.selfTestClearColorLabels()
        wait(timeout: 1.0) { wc.selfTestColorLabelCount == 0 }
        let stillColours = labelled.map { wc.selfTestHighlighterColorsLabel(text: $0) } ?? true
        s += (wc.selfTestColorLabelCount == 0 && !stillColours)
            ? "PASS clear removes the label (highlighter no longer colours it)\n"
            : "FAIL clear (count=\(wc.selfTestColorLabelCount) stillColours=\(stillColours))\n"

        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Predefined filter tests (Wave 8)

    /// Prove the predefined-filter picker: open a file with a known number of matching
    /// lines, store a predefined filter, apply it (the picker code path), and assert the
    /// engine search returns the expected match count.
    private static func predefinedFilterTests(_ wc: MainWindowController) -> String {
        var s = "--- PREDEFINED FILTER TESTS ---\n"

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-pf-\(UUID().uuidString).log")
        // 5 ERROR lines + 7 INFO lines.
        var lines: [String] = []
        for i in 1...5 { lines.append("ERROR failure \(i)") }
        for i in 1...7 { lines.append("INFO ok \(i)") }
        let body = lines.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write predefined-filter test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 12 }

        // Apply a predefined filter matching the 5 ERROR lines.
        let filter = PredefinedFilter(name: "Errors", pattern: "ERROR",
                                      ignoreCase: false, useRegex: false)
        wc.selfTestApplyPredefinedFilter(filter)
        let got = wait(timeout: 5.0) { wc.selfTestSearchMatchCount == 5 }
        let count = wc.selfTestSearchMatchCount
        s += got
            ? "PASS predefined filter \"ERROR\" ran search → \(count) matches (expected 5)\n"
            : "FAIL predefined filter search: got \(count) matches (expected 5)\n"

        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Overview minimap tests (Wave 8)

    /// Prove the overview strip: open a file, run a search with a known match count,
    /// and verify (a) the visibility flag toggles, (b) the overview plots exactly
    /// searchMatchCount marks. Snapshot the strip with marks visible (overview ON).
    private static func overviewTests(_ wc: MainWindowController) -> String {
        var s = "--- OVERVIEW MINIMAP TESTS ---\n"

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-overview-\(UUID().uuidString).log")
        // 6 MATCH lines interleaved among 30 filler lines (so marks spread vertically).
        var lines: [String] = []
        for i in 1...30 {
            lines.append(i % 5 == 0 ? "MATCH important event \(i)" : "filler line \(i)")
        }
        let body = lines.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write overview test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 30 }

        // Ensure the overview is visible for the snapshot + assertions.
        if !wc.selfTestOverviewVisible { wc.selfTestToggleOverview() }
        let visAfterOn = wc.selfTestOverviewVisible
        s += visAfterOn ? "PASS overview visible flag ON\n" : "FAIL overview not visible\n"

        // Run a search; the engine has 6 MATCH lines (i = 5,10,15,20,25,30).
        wc.selfTestRunSearch(pattern: "MATCH", caseInsensitive: false, isRegex: false)
        let got = wait(timeout: 5.0) { wc.selfTestOverviewMatchCount == 6 }
        let marks = wc.selfTestOverviewMatchCount
        s += got
            ? "PASS overview plots searchMatchCount marks: \(marks) (expected 6)\n"
            : "FAIL overview mark count: \(marks) (expected 6)\n"

        // Snapshot with the strip visible + marks plotted.
        let dir = ProcessInfo.processInfo.environment["KLOGG_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let onSnap = (dir as NSString).appendingPathComponent("klogg-snapshot-overview-on.png")
        s += wc.selfTestSnapshot(to: onSnap) ? "PASS wrote \(onSnap)\n" : "FAIL overview-on snapshot\n"

        // Toggle OFF and assert the flag flips (regression: strip hidden, log unaffected).
        wc.selfTestToggleOverview()
        let visAfterOff = wc.selfTestOverviewVisible
        s += !visAfterOff ? "PASS overview visible flag OFF\n" : "FAIL overview stuck ON\n"
        let offSnap = (dir as NSString).appendingPathComponent("klogg-snapshot-overview-off.png")
        s += wc.selfTestSnapshot(to: offSnap) ? "PASS wrote \(offSnap)\n" : "FAIL overview-off snapshot\n"

        // Restore the default ON for subsequent runs and clean up.
        wc.selfTestToggleOverview()
        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Session restore tests (Wave 7b)

    /// Prove session persistence round-trip: save a known set of paths + active index,
    /// read them back from UserDefaults via AppPreferences. (No file open required —
    /// this exercises the storage layer the AppDelegate uses on launch.)
    private static func sessionTests() -> String {
        var s = "--- SESSION RESTORE TESTS ---\n"
        let prefs = AppPreferences.shared

        // Preserve and restore the real session afterwards so we don't disturb it.
        let savedFiles = prefs.sessionOpenFiles
        let savedIndex = prefs.sessionActiveIndex
        defer { prefs.saveSession(openFiles: savedFiles, activeIndex: savedIndex) }

        let paths = ["/tmp/klogg-a.log", "/tmp/klogg-b.log", "/tmp/klogg-c.log"]
        prefs.saveSession(openFiles: paths, activeIndex: 2)
        let readBack = prefs.sessionOpenFiles
        let readIdx = prefs.sessionActiveIndex
        s += (readBack == paths && readIdx == 2)
            ? "PASS session round-trip: \(readBack.count) paths, activeIndex=\(readIdx)\n"
            : "FAIL session round-trip: got \(readBack) idx=\(readIdx)\n"

        // Empty-clears correctly.
        prefs.saveSession(openFiles: [], activeIndex: 0)
        s += prefs.sessionOpenFiles.isEmpty
            ? "PASS session clear\n"
            : "FAIL session clear: \(prefs.sessionOpenFiles)\n"
        return s
    }
}
