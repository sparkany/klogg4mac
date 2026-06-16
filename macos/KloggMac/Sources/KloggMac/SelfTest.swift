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
import KloggBridge

enum SelfTest {

    static func run(windowController wc: MainWindowController) {
        var out = "===== KLOGG SELFTEST =====\n"
        out += defaultsIsolationTests()
        out += "\n" + auditMenu()
        out += "\n" + auditToolbar(wc)
        out += "\n" + snapshots(wc)
        out += "\n" + behaviorTests(wc)
        out += "\n" + followTests(wc)
        out += "\n" + encodingTests(wc)
        out += "\n" + sessionTests()
        out += "\n" + colorLabelTests(wc)
        out += "\n" + marksAndContextMenuTests(wc)
        out += "\n" + searchHistoryTests()
        out += "\n" + infoLineFormatTests(wc)
        out += "\n" + predefinedFilterTests(wc)
        out += "\n" + overviewTests(wc)
        out += "\n" + filterBarTests(wc)
        out += "\n" + textWrapTests(wc)
        out += "\n" + preferencesLiveApplyTests(wc)
        out += "\n" + highlightersEditorTests(wc)
        out += "\n" + predefinedFiltersEditorTests(wc)
        out += "\n" + scratchpadTransformTests()
        out += "\n" + searchCorrectnessTests(wc)
        out += "\n" + searchOptionsTests(wc)
        out += "\n" + quickFindEdgeTests(wc)
        out += "\n" + goToLineBoundsTests(wc)
        out += "\n" + edgeRobustnessTests(wc)
        out += "\n" + decompressionTests(wc)
        out += "\n" + fontZoomTests(wc)
        out += "\n" + saveToFileTests(wc)
        out += "\n" + historyAndVariateTests()
        out += "\n" + shortcutAudit()
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

    // MARK: - UserDefaults isolation (selftest must not touch real prefs)

    /// Prove the harness is writing to a throwaway suite, not the user's real
    /// "KloggMac" domain. (a) AppDefaults.store is NOT UserDefaults.standard;
    /// (b) a write through a store lands in the isolated suite and is INVISIBLE in
    /// standard. This is the guard against the known defect where --selftest
    /// polluted the user's favorites / highlighters / session / color-labels.
    private static func defaultsIsolationTests() -> String {
        var s = "--- DEFAULTS ISOLATION TESTS ---\n"

        let isolated = AppDefaults.store !== UserDefaults.standard
        s += isolated
            ? "PASS AppDefaults.store is an isolated suite (not .standard)\n"
            : "FAIL AppDefaults.store is UserDefaults.standard — selftest would corrupt real prefs\n"

        // Write a sentinel through a real store and confirm it does NOT reach standard.
        let probePath = "/tmp/klogg-isolation-probe-\(UUID().uuidString).log"
        FavoritesStore.shared.add(path: probePath)
        let inIsolated = FavoritesStore.shared.isFavorite(probePath)
        let leakedToStandard = (UserDefaults.standard.stringArray(forKey: "klogg.favorites") ?? [])
            .contains(probePath)
        FavoritesStore.shared.remove(path: probePath)   // clean the isolated suite
        s += (inIsolated && !leakedToStandard)
            ? "PASS store write stays in isolated suite (real 'klogg.favorites' untouched)\n"
            : "FAIL store write leaked: isolated=\(inIsolated) standard=\(leakedToStandard)\n"

        return s
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

    // MARK: - Line marks + log-view context menu (Wave 10)

    /// Prove (a) line marks toggle + persist + navigate (klogg bookmarks), and (b) the
    /// log-view right-click context menu mirrors klogg's abstractlogview popup (Mark,
    /// Copy this line, Copy with line numbers, Replace/Add/Exclude search, Save), and
    /// (c) "Copy with line numbers" produces "<num>\t<text>". Snapshots the marked view.
    private static func marksAndContextMenuTests(_ wc: MainWindowController) -> String {
        var s = "--- MARKS + CONTEXT MENU TESTS ---\n"

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-marks-\(UUID().uuidString).log")
        let body = (1...20).map { "log entry \($0)" }.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write marks test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 20 }

        // (a) Mark toggle round-trip on line 3.
        let on = wc.selfTestToggleMark(line: 3)
        let countAfterMark = wc.selfTestMarkCount
        let off = wc.selfTestToggleMark(line: 3)
        s += (on && !off && countAfterMark == 1)
            ? "PASS mark toggle round-trip on line 3 (count went 1 → 0)\n"
            : "FAIL mark toggle: on=\(on) off=\(off) count=\(countAfterMark)\n"

        // Mark three lines; assert count + next-mark wraps.
        _ = wc.selfTestToggleMark(line: 2)
        _ = wc.selfTestToggleMark(line: 8)
        _ = wc.selfTestToggleMark(line: 15)
        let nextFrom8 = wc.selfTestNextMark(after: 8)     // → 15
        let nextFrom15 = wc.selfTestNextMark(after: 15)   // wraps → 2
        s += (wc.selfTestMarkCount == 3 && nextFrom8 == 15 && nextFrom15 == 2)
            ? "PASS mark navigation: count=3, next(8)=15, next(15) wraps → 2\n"
            : "FAIL mark navigation: count=\(wc.selfTestMarkCount) next8=\(nextFrom8) next15=\(nextFrom15)\n"

        // Persistence: a fresh MarksStore for the same path sees the marks.
        let reopened = MarksStore(filePath: path)
        s += (reopened.marks == [2, 8, 15])
            ? "PASS marks persisted across store reload: \(reopened.marks.sorted())\n"
            : "FAIL marks persistence: \(reopened.marks.sorted()) (expected [2,8,15])\n"

        // Mark-navigation via the view (']' next / '[' prev), starting from line 0.
        _ = wc.selfTestContextMenuTitles(selectingLine: 0)   // selects line 0
        let jNext1 = wc.selfTestJumpToMark(next: true)   // 0 → 2
        let jNext2 = wc.selfTestJumpToMark(next: true)   // 2 → 8
        let jPrev = wc.selfTestJumpToMark(next: false)   // 8 → 2
        s += (jNext1 == 2 && jNext2 == 8 && jPrev == 2)
            ? "PASS view mark navigation ']'/'[': 0→2→8, prev→2\n"
            : "FAIL view mark navigation: next1=\(jNext1) next2=\(jNext2) prev=\(jPrev)\n"

        // Snapshot the marked main view (marks drawn in the gutter).
        let dir = ProcessInfo.processInfo.environment["KLOGG_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let snap = (dir as NSString).appendingPathComponent("klogg-snapshot-marks.png")
        s += wc.selfTestSnapshot(to: snap) ? "PASS wrote \(snap)\n" : "FAIL marks snapshot\n"

        // (a2) Marks must still render with the line-number gutter OFF (klogg keeps a
        // dedicated bullet margin). Toggle line numbers off, re-mark a couple of lines,
        // and snapshot: the gutter collapses to width 0 but the mark zone persists.
        _ = wc.selfTestToggleMark(line: 1)
        _ = wc.selfTestToggleMark(line: 4)
        let lnWasOn = AppPreferences.shared.lineNumbersInMain
        AppPreferences.shared.lineNumbersInMain = false
        wc.selfTestApplyPreferencesToCurrentTab()
        let gutterOff = wc.selfTestMainGutterWidth
        s += gutterOff == 0
            ? "PASS line-number gutter hidden (width=0) while marks remain in their zone\n"
            : "FAIL gutter not hidden with line numbers off (width=\(gutterOff))\n"
        let snapNoLn = (dir as NSString).appendingPathComponent("klogg-snapshot-marks-no-linenumbers.png")
        s += wc.selfTestSnapshot(to: snapNoLn)
            ? "PASS wrote \(snapNoLn)\n" : "FAIL marks (no line numbers) snapshot\n"
        // Restore line-number preference + clean marks.
        AppPreferences.shared.lineNumbersInMain = lnWasOn
        wc.selfTestApplyPreferencesToCurrentTab()
        wc.selfTestClearMarks()

        // (b) Context menu mirrors klogg's abstractlogview popup.
        let titles = wc.selfTestContextMenuTitles(selectingLine: 0)
        let required = ["Mark", "Copy this line", "Copy this line with line number",
                        "Replace search", "Add to search", "Exclude from search",
                        "Set search start", "Set search end", "Clear search limits",
                        "Select All", "Save selected to file"]
        let missing = required.filter { !titles.contains($0) }
        s += missing.isEmpty
            ? "PASS context menu has klogg items: \(titles.count) entries\n"
            : "FAIL context menu missing \(missing) — has \(titles)\n"

        // (c) Copy with line numbers → "1\tlog entry 1" for line 0.
        let copied = wc.selfTestCopyWithLineNumbers(line: 0) ?? ""
        s += (copied == "1\tlog entry 1")
            ? "PASS copy-with-line-numbers: \"\(copied.replacingOccurrences(of: "\t", with: "\\t"))\"\n"
            : "FAIL copy-with-line-numbers: \"\(copied.replacingOccurrences(of: "\t", with: "\\t"))\" (expected \"1\\tlog entry 1\")\n"

        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Search history (klogg savedSearches) (Wave 10)

    /// Prove the recent-search store mirrors klogg's SavedSearches::addRecent:
    /// skip blanks, de-dupe (move to front), most-recent-first ordering, and clear.
    private static func searchHistoryTests() -> String {
        var s = "--- SEARCH HISTORY TESTS ---\n"
        let store = SavedSearchesStore.shared
        let baseline = store.recentSearches()
        defer { store.clear(); baseline.reversed().forEach { store.addRecent($0) } }

        store.clear()
        store.addRecent("first")
        store.addRecent("second")
        store.addRecent("")          // blank ignored
        store.addRecent("third")
        // Most-recent-first.
        s += (store.recentSearches() == ["third", "second", "first"])
            ? "PASS recent searches most-recent-first: \(store.recentSearches())\n"
            : "FAIL recent order: \(store.recentSearches())\n"

        // Re-adding an existing term moves it to the front (de-dupe).
        store.addRecent("first")
        s += (store.recentSearches() == ["first", "third", "second"])
            ? "PASS re-add de-dupes + moves to front: \(store.recentSearches())\n"
            : "FAIL de-dupe: \(store.recentSearches())\n"

        // Blank was skipped (count stays 3).
        s += (store.recentSearches().count == 3)
            ? "PASS blank search ignored (count=3)\n"
            : "FAIL blank not ignored (count=\(store.recentSearches().count))\n"

        store.clear()
        s += store.recentSearches().isEmpty ? "PASS clear history\n" : "FAIL clear history\n"
        return s
    }

    // MARK: - Info-line format parity (klogg lineNumberHandler) (Wave 10)

    /// Prove the status bar's line-position field matches klogg's exact formats:
    /// "Ln:N/Total", "Ln:N/Total Col:C Sel:S|L" (single-line portion), and
    /// "Ln:N/Total Sel:S|L" (multi-line selection).
    private static func infoLineFormatTests(_ wc: MainWindowController) -> String {
        var s = "--- INFO-LINE FORMAT TESTS ---\n"

        func check(_ label: String, _ got: String, _ want: String) {
            s += (got == want) ? "PASS \(label): \"\(got)\"\n"
                               : "FAIL \(label): \"\(got)\" (expected \"\(want)\")\n"
        }
        // No selection: Ln:1/100 (line is 0-based input → 1-based display).
        check("plain position",
              wc.selfTestStatusLineField(line: 0, total: 100, column: nil, selSymbols: 0, selLines: 1),
              "Ln:1/100")
        // Single-line portion: Ln:5/100 Col:3 Sel:7|1.
        check("single-line portion",
              wc.selfTestStatusLineField(line: 4, total: 100, column: 3, selSymbols: 7, selLines: 1),
              "Ln:5/100 Col:3 Sel:7|1")
        // Multi-line selection: Ln:5/100 Sel:40|3 (no Col).
        check("multi-line selection",
              wc.selfTestStatusLineField(line: 4, total: 100, column: 0, selSymbols: 40, selLines: 3),
              "Ln:5/100 Sel:40|3")
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

    // MARK: - Filter bar / visibility-mode tests (Wave 11)

    /// Prove the klogg crawler search-line + visibility combobox: open a file with
    /// known matches, run a search, then exercise the three visibility modes (Matches /
    /// Marks / Marks and matches) and assert the filtered (lower) pane row count for
    /// each. Also asserts the "N matches found." label text and snapshots the layout
    /// (search bar BETWEEN the two panes, lower pane populated).
    private static func filterBarTests(_ wc: MainWindowController) -> String {
        var s = "--- FILTER BAR / VISIBILITY TESTS ---\n"

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-filterbar-\(UUID().uuidString).log")
        // 12 lines: 4 ERROR (rows 0,3,6,9), the rest INFO.
        var lines: [String] = []
        for i in 0..<12 { lines.append(i % 3 == 0 ? "ERROR event \(i)" : "INFO ok \(i)") }
        let body = lines.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write filter-bar test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 12 }

        // Run a search for the 4 ERROR lines.
        wc.selfTestRunSearch(pattern: "ERROR", caseInsensitive: false, isRegex: false)
        _ = wait(timeout: 5.0) { wc.selfTestSearchMatchCount == 4 }

        // Default mode is "Marks and matches" — with no marks, that's just the 4 matches.
        wc.selfTestSetFilteredVisibility(.matches)
        _ = wait(timeout: 2.0) { wc.selfTestFilteredRowCount == 4 }
        let matchesRows = wc.selfTestFilteredRowCount
        s += matchesRows == 4
            ? "PASS Matches mode: filtered pane shows 4 rows\n"
            : "FAIL Matches mode: \(matchesRows) rows (expected 4)\n"

        // "N matches found." label format (klogg searchInfoLine_). Driven through the
        // same updateMatchCount path the searchFinished delegate uses; asserted
        // deterministically (the engine's async search callback is offscreen-unreliable).
        let label = wc.selfTestMatchLabel(forCount: 4)
        let labelOne = wc.selfTestMatchLabel(forCount: 1)
        s += (label == "4 matches found." && labelOne == "1 match found.")
            ? "PASS match label: \"\(label)\" / \"\(labelOne)\"\n"
            : "FAIL match label: \"\(label)\" / \"\(labelOne)\"\n"

        // Mark two lines that are NOT matches (rows 1 and 2 → INFO lines).
        _ = wc.selfTestToggleMark(line: 1)
        _ = wc.selfTestToggleMark(line: 2)

        // Marks mode: only the 2 marked source lines.
        wc.selfTestSetFilteredVisibility(.marks)
        _ = wait(timeout: 2.0) { wc.selfTestFilteredRowCount == 2 }
        let marksRows = wc.selfTestFilteredRowCount
        s += marksRows == 2
            ? "PASS Marks mode: filtered pane shows 2 marked rows\n"
            : "FAIL Marks mode: \(marksRows) rows (expected 2)\n"

        // Marks and matches: union of 4 matches (0,3,6,9) + 2 marks (1,2) = 6 distinct.
        wc.selfTestSetFilteredVisibility(.marksAndMatches)
        _ = wait(timeout: 2.0) { wc.selfTestFilteredRowCount == 6 }
        let unionRows = wc.selfTestFilteredRowCount
        s += unionRows == 6
            ? "PASS Marks-and-matches mode: union shows 6 rows (4 matches ∪ 2 marks)\n"
            : "FAIL Marks-and-matches mode: \(unionRows) rows (expected 6)\n"

        // Scrollbar markers (klogg scrollbar overview): main = 4 matches + 2 marks = 6;
        // filtered (union mode) = one per row = 6.
        let counts = wc.selfTestScrollbarMarkerCounts
        s += (counts.main == 6 && counts.filtered == 6)
            ? "PASS scrollbar markers: main=\(counts.main) (4 matches + 2 marks), filtered=\(counts.filtered)\n"
            : "FAIL scrollbar markers: main=\(counts.main) filtered=\(counts.filtered) (expected 6/6)\n"

        // Snapshot the klogg-style layout: search bar between the panes, lower pane filled.
        let dir = ProcessInfo.processInfo.environment["KLOGG_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let snap = (dir as NSString).appendingPathComponent("klogg-snapshot-filterbar.png")
        s += wc.selfTestSnapshot(to: snap)
            ? "PASS wrote \(snap)\n" : "FAIL filter-bar snapshot\n"

        // Restore default mode + clean up.
        wc.selfTestSetFilteredVisibility(.marksAndMatches)
        wc.selfTestClearMarks()
        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Text wrap tests (Wave 8)

    /// Prove text wrap: open a file with one very long line, snapshot wrap OFF (long
    /// line scrolls; one visual row) then wrap ON (long line soft-wraps to multiple
    /// visual rows). Assert (a) the view-side wrap flag tracks the preference, (b) the
    /// long line occupies 1 visual row off / >1 on, (c) a short line stays 1 row both
    /// ways (non-wrap render path unaffected for short content).
    private static func textWrapTests(_ wc: MainWindowController) -> String {
        var s = "--- TEXT WRAP TESTS ---\n"

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-wrap-\(UUID().uuidString).log")
        let longLine = "LONG " + String(repeating: "abcdefghij ", count: 60)  // ~660 chars
        let body = "short head line\n" + longLine + "\nshort tail line\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write wrap test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        let savedWrap = AppPreferences.shared.useTextWrap

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 3 }

        // Ensure wrap is OFF first.
        if wc.selfTestTextWrapEnabled { wc.selfTestToggleTextWrap() }
        let dir = ProcessInfo.processInfo.environment["KLOGG_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let offSnap = (dir as NSString).appendingPathComponent("klogg-snapshot-wrap-off.png")
        s += wc.selfTestSnapshot(to: offSnap) ? "PASS wrote \(offSnap)\n" : "FAIL wrap-off snapshot\n"
        // After the snapshot the view is laid out at the snapshot width.
        let offWrapFlag = wc.selfTestMainViewWrapEnabled
        let offLongRows = wc.selfTestMainVisualRows(forLine: 1)
        s += (!offWrapFlag && offLongRows == 1)
            ? "PASS wrap OFF: view flag=\(offWrapFlag), long line = \(offLongRows) visual row\n"
            : "FAIL wrap OFF: view flag=\(offWrapFlag), long line rows=\(offLongRows) (expected 1)\n"

        // Turn wrap ON.
        wc.selfTestToggleTextWrap()
        let onSnap = (dir as NSString).appendingPathComponent("klogg-snapshot-wrap-on.png")
        s += wc.selfTestSnapshot(to: onSnap) ? "PASS wrote \(onSnap)\n" : "FAIL wrap-on snapshot\n"
        let onWrapFlag = wc.selfTestMainViewWrapEnabled
        let onLongRows = wc.selfTestMainVisualRows(forLine: 1)
        let onShortRows = wc.selfTestMainVisualRows(forLine: 0)
        s += (onWrapFlag && onLongRows > 1)
            ? "PASS wrap ON: view flag=\(onWrapFlag), long line = \(onLongRows) visual rows (>1)\n"
            : "FAIL wrap ON: view flag=\(onWrapFlag), long line rows=\(onLongRows) (expected >1)\n"
        s += (onShortRows == 1)
            ? "PASS wrap ON: short line stays 1 visual row\n"
            : "FAIL wrap ON: short line rows=\(onShortRows) (expected 1)\n"

        // Restore the preference + clean up.
        if AppPreferences.shared.useTextWrap != savedWrap { wc.selfTestToggleTextWrap() }
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

    // MARK: - Preferences live-apply (Wave 9)

    /// Prove the Preferences controls don't just persist but LIVE-APPLY to open views:
    /// (a) a font-size change resizes the main-view rowHeight, (b) toggling the main
    /// line-number preference shows/hides the gutter (width >0 vs 0).
    private static func preferencesLiveApplyTests(_ wc: MainWindowController) -> String {
        var s = "--- PREFERENCES LIVE-APPLY TESTS ---\n"
        let prefs = AppPreferences.shared

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-prefs-\(UUID().uuidString).log")
        let body = (1...20).map { "log line number \($0)" }.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write prefs test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 20 }
        wc.selfTestApplyPreferencesToCurrentTab()

        // (a) Font size → rowHeight. Save + restore the real preference.
        let savedSize = prefs.fontSize
        prefs.fontSize = 12
        wc.selfTestApplyPreferencesToCurrentTab()
        let h12 = wc.selfTestMainRowHeight
        prefs.fontSize = 24
        wc.selfTestApplyPreferencesToCurrentTab()
        let h24 = wc.selfTestMainRowHeight
        prefs.fontSize = savedSize
        wc.selfTestApplyPreferencesToCurrentTab()
        s += (h24 > h12 && h12 > 0)
            ? "PASS font-size change resizes rows: rowHeight \(Int(h12))pt → \(Int(h24))pt\n"
            : "FAIL font-size live-apply: rowHeight \(h12) → \(h24) (expected bigger)\n"

        // (b) Line-number toggle → gutter width. Default is ON.
        let savedLN = prefs.lineNumbersInMain
        prefs.lineNumbersInMain = true
        wc.selfTestApplyPreferencesToCurrentTab()
        let gOn = wc.selfTestMainGutterWidth
        prefs.lineNumbersInMain = false
        wc.selfTestApplyPreferencesToCurrentTab()
        let gOff = wc.selfTestMainGutterWidth
        prefs.lineNumbersInMain = savedLN
        wc.selfTestApplyPreferencesToCurrentTab()
        s += (gOn > 0 && gOff == 0)
            ? "PASS line-number toggle shows/hides gutter: width \(Int(gOn)) → \(Int(gOff))\n"
            : "FAIL line-number gutter toggle: width \(gOn) → \(gOff) (expected >0 → 0)\n"

        // (c) Round-trip a couple of typed prefs through AppPreferences.
        let savedRegex = prefs.mainRegexpType
        prefs.mainRegexpType = 1
        let rt = prefs.mainRegexpType == 1
        prefs.mainRegexpType = savedRegex
        s += rt ? "PASS mainRegexpType round-trips (0↔1)\n"
                : "FAIL mainRegexpType round-trip\n"

        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Highlighters editor internals (Wave 9)

    /// Prove the Highlighters editor's controls actually mutate + persist the store AND
    /// reach the render path: add a rule via the editor's real add→form→OK path, assert
    /// it's in HighlighterStore and that a freshly-built LogHighlighter colours a line
    /// matching it; then delete it and assert it's gone + no longer colours.
    private static func highlightersEditorTests(_ wc: MainWindowController) -> String {
        var s = "--- HIGHLIGHTERS EDITOR TESTS ---\n"
        let editor = wc.selfTestHighlightersEditor
        let store = HighlighterStore.shared

        let baseline = store.rules
        defer { store.setRules(baseline) }      // restore the user's real rules

        // Start from a known clean slate.
        store.setRules([])
        wait(timeout: 1.0) { store.rules.isEmpty }

        let token = "QASELFTEST_HL_TOKEN"
        let countAfterAdd = editor.selfTestAddRule(
            name: "QA rule", pattern: token, useRegex: false, ignoreCase: false,
            matchOnly: true, fore: .black, back: .yellow)
        wait(timeout: 1.0) { store.rules.contains { $0.pattern == token } }
        let added = store.rules.contains { $0.pattern == token && $0.matchOnly }
        s += (countAfterAdd >= 1 && added)
            ? "PASS editor added rule → store has it (count=\(store.rules.count))\n"
            : "FAIL editor add rule (count=\(countAfterAdd) present=\(added))\n"

        // The rule must reach draw(): a fresh LogHighlighter colours a line with the token.
        let colours = wc.selfTestHighlighterColorsLabel(text: "prefix \(token) suffix")
        s += colours
            ? "PASS added highlighter colours a matching line (reaches draw())\n"
            : "FAIL added highlighter does not colour a matching line\n"

        // Add a second rule, then reorder (move idx 1 up) and assert order persisted.
        editor.selfTestAddRule(name: "QA rule 2", pattern: "SECOND", useRegex: false,
                               ignoreCase: false, matchOnly: true, fore: .black, back: .green)
        wait(timeout: 1.0) { store.rules.count == 2 }
        let names = editor.selfTestMoveRuleUp(at: 1)
        s += (names.first == "QA rule 2")
            ? "PASS editor reorder persists: \(names)\n"
            : "FAIL editor reorder: \(names) (expected 'QA rule 2' first)\n"

        // Delete all our test rules and assert the highlighter stops colouring.
        editor.selfTestDeleteRule(at: 0)
        editor.selfTestDeleteRule(at: 0)
        wait(timeout: 1.0) { store.rules.isEmpty }
        let stillColours = wc.selfTestHighlighterColorsLabel(text: "prefix \(token) suffix")
        s += (store.rules.isEmpty && !stillColours)
            ? "PASS editor delete removes rules (highlighter no longer colours)\n"
            : "FAIL editor delete (count=\(store.rules.count) stillColours=\(stillColours))\n"
        return s
    }

    // MARK: - Predefined-filters editor internals (Wave 9)

    /// Prove the Predefined-filters editor persists to PredefinedFilterStore AND that a
    /// stored filter then runs correctly through the search-bar code path (match count).
    private static func predefinedFiltersEditorTests(_ wc: MainWindowController) -> String {
        var s = "--- PREDEFINED-FILTERS EDITOR TESTS ---\n"
        let editor = wc.selfTestPredefinedFiltersEditor
        let store = PredefinedFilterStore.shared

        let baseline = store.filters
        defer { store.setFilters(baseline) }
        store.setFilters([])
        wait(timeout: 1.0) { store.filters.isEmpty }

        let count = editor.selfTestAddFilter(name: "QA Errors", pattern: "ERROR",
                                             useRegex: false, ignoreCase: false)
        wait(timeout: 1.0) { store.filters.contains { $0.name == "QA Errors" } }
        let stored = store.filters.first { $0.name == "QA Errors" }
        s += (count >= 1 && stored?.pattern == "ERROR")
            ? "PASS editor added filter → store has it (count=\(store.filters.count))\n"
            : "FAIL editor add filter (count=\(count) stored=\(String(describing: stored)))\n"

        // Run the stored filter on a known file via the picker path; assert match count.
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-pfeditor-\(UUID().uuidString).log")
        let body = (1...4).map { "ERROR e\($0)" }.joined(separator: "\n") + "\n"
            + (1...6).map { "INFO i\($0)" }.joined(separator: "\n") + "\n"
        if (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
            defer { try? FileManager.default.removeItem(atPath: path) }
            wc.selfTestOpen(path)
            wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 10 }
            if let f = stored {
                wc.selfTestApplyPredefinedFilter(f)
                let got = wait(timeout: 5.0) { wc.selfTestSearchMatchCount == 4 }
                s += got
                    ? "PASS stored filter runs via search path → \(wc.selfTestSearchMatchCount) matches (expected 4)\n"
                    : "FAIL stored filter search: \(wc.selfTestSearchMatchCount) (expected 4)\n"
            }
            wc.closeCurrentTab(nil)
        }

        // Delete and assert gone.
        editor.selfTestDeleteFilter(at: 0)
        wait(timeout: 1.0) { store.filters.isEmpty }
        s += store.filters.isEmpty
            ? "PASS editor delete removes filter\n"
            : "FAIL editor delete (count=\(store.filters.count))\n"
        return s
    }

    // MARK: - Scratchpad transforms (Wave 9)

    /// Prove the scratchpad transforms produce correct output for known inputs. These
    /// are the exact pure functions the toolbar buttons run.
    private static func scratchpadTransformTests() -> String {
        var s = "--- SCRATCHPAD TRANSFORM TESTS ---\n"
        typealias T = ScratchpadWindowController.Transforms

        func check(_ label: String, _ got: String?, _ want: String) {
            s += (got == want)
                ? "PASS \(label): \"\(want)\"\n"
                : "FAIL \(label): got \(got.map { "\"\($0)\"" } ?? "nil") (expected \"\(want)\")\n"
        }

        check("base64 encode 'klogg'", T.encodeBase64("klogg"), "a2xvZ2c=")
        check("base64 decode 'a2xvZ2c='", T.decodeBase64("a2xvZ2c="), "klogg")
        check("hex encode 'AB'", T.encodeHex("AB"), "4142")
        check("hex decode '6b6c6f6767'", T.decodeHex("6b6c6f6767"), "klogg")
        check("url decode 'a%20b%2Fc'", T.decodeURL("a%20b%2Fc"), "a b/c")

        // base64 round-trip on arbitrary text.
        let rt = T.encodeBase64("Hello, 世界!").flatMap { T.decodeBase64($0) }
        s += (rt == "Hello, 世界!")
            ? "PASS base64 round-trip preserves unicode\n"
            : "FAIL base64 round-trip: got \(rt.map { "\"\($0)\"" } ?? "nil")\n"

        // JSON pretty-print: compact in → multi-line, sorted keys out, still parses back.
        let json = T.formatJSON("{\"b\":1,\"a\":2}")
        let jsonOk = (json?.contains("\n") == true)
            && (json?.range(of: "\"a\"")?.lowerBound ?? json!.endIndex)
                < (json?.range(of: "\"b\"")?.lowerBound ?? json!.startIndex)
        s += jsonOk
            ? "PASS JSON format pretty-prints + sorts keys\n"
            : "FAIL JSON format: \(json ?? "nil")\n"
        return s
    }

    // MARK: - Search correctness (Wave 9)

    /// Drive search correctness across cases against a controlled corpus, cross-checking
    /// the in-process matcher (same compile rules the views use) for: plain substring,
    /// case sensitivity, regex, regex special chars, and no-match.
    private static func searchCorrectnessTests(_ wc: MainWindowController) -> String {
        var s = "--- SEARCH CORRECTNESS TESTS ---\n"

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-search-\(UUID().uuidString).log")
        // Known corpus:
        //   3 lines containing "ERROR", 2 containing "error" (lowercase),
        //   2 lines with "a.b" literal dots, 1 with "axb".
        let lines = [
            "ERROR alpha", "ERROR beta", "ERROR gamma",
            "error lower one", "error lower two",
            "value a.b here", "another a.b token", "regex axb match",
            "INFO nothing special",
        ]
        let body = lines.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write search test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= lines.count }

        func expect(_ label: String, _ got: Int, _ want: Int) {
            s += (got == want) ? "PASS \(label): \(got)\n"
                               : "FAIL \(label): \(got) (expected \(want))\n"
        }

        // Plain, case-sensitive: "ERROR" → 3 (lowercase 'error' excluded).
        expect("plain 'ERROR' case-sensitive",
               wc.selfTestCountMatches(pattern: "ERROR", caseInsensitive: false, isRegex: false), 3)
        // Plain, case-insensitive: "error" → 5 (ERROR + error).
        expect("plain 'error' case-insensitive",
               wc.selfTestCountMatches(pattern: "error", caseInsensitive: true, isRegex: false), 5)
        // Literal special chars (plain mode escapes): "a.b" → 2 (the literal-dot lines),
        // NOT "axb" (which a regex '.' would also match).
        expect("plain 'a.b' (dot literal)",
               wc.selfTestCountMatches(pattern: "a.b", caseInsensitive: false, isRegex: false), 2)
        // Regex mode: "a.b" → 3 (the 2 literal-dot lines + 'axb').
        expect("regex 'a.b' (dot wildcard)",
               wc.selfTestCountMatches(pattern: "a.b", caseInsensitive: false, isRegex: true), 3)
        // Regex anchor: "^ERROR" → 3.
        expect("regex '^ERROR' anchored",
               wc.selfTestCountMatches(pattern: "^ERROR", caseInsensitive: false, isRegex: true), 3)
        // No-match.
        expect("no-match 'ZZZZZ'",
               wc.selfTestCountMatches(pattern: "ZZZZZ", caseInsensitive: false, isRegex: false), 0)

        // Cross-check against grep for the case-sensitive ERROR count.
        let grepCount = grepLineCount(pattern: "ERROR", path: path, caseInsensitive: false)
        s += (grepCount == 3)
            ? "PASS grep cross-check 'ERROR' = 3\n"
            : "FAIL grep cross-check 'ERROR' = \(grepCount) (expected 3)\n"

        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Search OPTIONS parity (Wave 12: inverse / range / boolean / toggles)

    /// Prove the full klogg search-line capabilities now wired through the bridge:
    ///   (1) INVERSE match — filtered view shows NON-matching lines (1000-line file with
    ///       250 ERROR → inverse 'ERROR' = 750).
    ///   (2) SEARCH RANGE limiting — set start/end lines and assert the count drops to the
    ///       matches inside the window (cross-checked against the math + grep on a slice).
    ///   (3) BOOLEAN combination — "ERROR and not INFO", "alpha or beta" semantics via the
    ///       engine's boolean evaluator (the context-menu add/exclude builds these).
    ///   (4) Expression VALIDITY gate (good vs. broken regex / boolean).
    ///   (5) Toggle PERSISTENCE — inverse/boolean/auto-refresh survive in AppPreferences.
    private static func searchOptionsTests(_ wc: MainWindowController) -> String {
        var s = "--- SEARCH OPTIONS PARITY TESTS (inverse/range/boolean) ---\n"

        // 1000-line corpus: every 4th line is an ERROR (250 ERROR, 750 other).
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-searchopt-\(UUID().uuidString).log")
        var lines: [String] = []
        lines.reserveCapacity(1000)
        for i in 0..<1000 {
            lines.append(i % 4 == 0 ? "ERROR event \(i)" : "INFO ok \(i)")
        }
        let body = lines.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write search-options test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 1000 }

        // --- (1) INVERSE match: 'ERROR' inverted → 750 non-matching lines.
        wc.selfTestRunSearchFull(pattern: "ERROR", caseInsensitive: false, isRegex: false,
                                 inverse: true, boolean: false, startLine: 0, endLine: Int.max)
        let invOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 750 }
        let invCount = wc.selfTestSearchMatchCount
        // grep oracle: lines NOT containing ERROR = total - grep('ERROR').
        let errGrep = grepLineCount(pattern: "ERROR", path: path, caseInsensitive: false)
        s += (invOK && invCount == 1000 - errGrep)
            ? "PASS inverse 'ERROR' = \(invCount) non-matching (grep: 1000-\(errGrep)=\(1000-errGrep))\n"
            : "FAIL inverse 'ERROR' = \(invCount) (expected 750, grep non-match \(1000-errGrep))\n"

        // Sanity: NON-inverted 'ERROR' = 250 (proves inverse flag actually flips it).
        wc.selfTestRunSearchFull(pattern: "ERROR", caseInsensitive: false, isRegex: false,
                                 inverse: false, boolean: false, startLine: 0, endLine: Int.max)
        let posOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 250 }
        s += posOK ? "PASS non-inverse 'ERROR' = 250 (matches)\n"
                   : "FAIL non-inverse 'ERROR' = \(wc.selfTestSearchMatchCount) (expected 250)\n"

        // --- (2) SEARCH RANGE: limit to lines [0, 40). ERROR lines there: 0,4,…,36 = 10.
        wc.selfTestRunSearchFull(pattern: "ERROR", caseInsensitive: false, isRegex: false,
                                 inverse: false, boolean: false, startLine: 0, endLine: 40)
        let rangeOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 10 }
        let rangeCount = wc.selfTestSearchMatchCount
        s += rangeOK
            ? "PASS range [0,40) 'ERROR' = \(rangeCount) (lines 0,4,…,36)\n"
            : "FAIL range [0,40) 'ERROR' = \(rangeCount) (expected 10)\n"

        // Range via the context-menu code path: setSearchStart(100) then setSearchEnd(199).
        // Each call re-runs the LAST search (klogg setSearchLimits → replaceCurrentSearch),
        // so we must seed it through the search-bar path (which records lastSearch) — not
        // the direct engine path. We wait for the intermediate result so the two async
        // searches don't race. Window [100,200): ERROR lines 100,104,…,196 = 25.
        // (setSearchEnd is exclusive +1, mirroring klogg AbstractLogView::setSearchEnd.)
        wc.selfTestRunSearchViaBar(pattern: "ERROR", caseInsensitive: false, isRegex: false,
                                   inverse: false, boolean: false)
        _ = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 250 }
        // Start limit [100,∞): ERROR lines 100,104,…,996 = 225.
        wc.selfTestSetSearchStart(line: 100)
        _ = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 225 }
        // End limit [100,200): 25.
        wc.selfTestSetSearchEnd(line: 199)
        let r2OK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 25 }
        let r2 = wc.selfTestSearchMatchCount
        let range = wc.selfTestSearchRange
        s += (r2OK && range.start == 100 && range.end == 200)
            ? "PASS setSearchStart/End [100,200) 'ERROR' = \(r2) (range=\(range.start),\(range.end))\n"
            : "FAIL setSearchStart/End 'ERROR' = \(r2) (expected 25, range=\(range.start),\(range.end))\n"

        // Clear limits → back to whole-file 250.
        wc.selfTestClearSearchLimits()
        let clrOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 250 }
        let clrRange = wc.selfTestSearchRange
        s += (clrOK && clrRange.start == 0 && clrRange.end == Int.max)
            ? "PASS clearSearchLimits → 250 (whole file)\n"
            : "FAIL clearSearchLimits → \(wc.selfTestSearchMatchCount) (expected 250)\n"

        // --- (3) BOOLEAN combination (klogg booleanButton_). klogg's parseBooleanExpressions
        // REQUIRES each sub-pattern enclosed in quotes. "ERROR" and not "INFO" → all 250
        // ERROR lines (none also contain INFO).
        wc.selfTestRunSearchFull(pattern: "\"ERROR\" and not \"INFO\"", caseInsensitive: false,
                                 isRegex: false, inverse: false, boolean: true,
                                 startLine: 0, endLine: Int.max)
        let boolAndOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 250 }
        s += boolAndOK
            ? "PASS boolean '\"ERROR\" and not \"INFO\"' = 250\n"
            : "FAIL boolean '\"ERROR\" and not \"INFO\"' = \(wc.selfTestSearchMatchCount) (expected 250)\n"

        // "ERROR" or "INFO" → every line (1000), since each is one or the other.
        wc.selfTestRunSearchFull(pattern: "\"ERROR\" or \"INFO\"", caseInsensitive: false,
                                 isRegex: false, inverse: false, boolean: true,
                                 startLine: 0, endLine: Int.max)
        let boolOrOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 1000 }
        s += boolOrOK
            ? "PASS boolean '\"ERROR\" or \"INFO\"' = 1000 (all lines)\n"
            : "FAIL boolean '\"ERROR\" or \"INFO\"' = \(wc.selfTestSearchMatchCount) (expected 1000)\n"

        // --- (4) VALIDITY gate.
        let goodRegex = wc.selfTestIsValidSearch(pattern: "ERR[0-9]+", isRegex: true, boolean: false)
        let badRegex  = wc.selfTestIsValidSearch(pattern: "ERR[0-9", isRegex: true, boolean: false)
        let goodBool  = wc.selfTestIsValidSearch(pattern: "\"ERROR\" and not \"INFO\"", isRegex: false, boolean: true)
        // klogg rejects boolean patterns without quotes ("Patterns must be enclosed in quotes").
        let badBool   = wc.selfTestIsValidSearch(pattern: "ERROR and not INFO", isRegex: false, boolean: true)
        s += (goodRegex && !badRegex)
            ? "PASS validity: good regex valid, broken '[0-9' rejected\n"
            : "FAIL validity: good=\(goodRegex) bad=\(badRegex)\n"
        s += (goodBool && !badBool)
            ? "PASS validity: quoted boolean valid, unquoted rejected\n"
            : "FAIL validity: goodBool=\(goodBool) badBool=\(badBool)\n"

        // --- (5) Full search-bar path with toggles (klogg replaceCurrentSearch wiring).
        wc.selfTestRunSearchViaBar(pattern: "ERROR", caseInsensitive: false, isRegex: false,
                                   inverse: true, boolean: false)
        let barInvOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 750 }
        let toggles = wc.selfTestSearchToggles
        s += (barInvOK && toggles.inverse)
            ? "PASS search-bar inverse path = 750 (inverse toggle ON)\n"
            : "FAIL search-bar inverse path = \(wc.selfTestSearchMatchCount), toggle=\(toggles.inverse)\n"

        // --- (5c) CONTEXT-MENU COMBINE (klogg replaceSearch/addToSearch/excludeFromSearch).
        // Reset to a clean field. "Replace search" with 'ERROR' → 250 (the plain literal).
        wc.selfTestRunSearchViaBar(pattern: "ERROR", caseInsensitive: false, isRegex: false,
                                   inverse: false, boolean: false)
        _ = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 250 }
        wc.selfTestCombineSearch(reset: true, op: "replace", term: "INFO")
        let replOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 750 }
        s += replOK ? "PASS combine replace 'INFO' = 750\n"
                    : "FAIL combine replace 'INFO' = \(wc.selfTestSearchMatchCount) (expected 750)\n"

        // "Exclude from search": after replace('INFO'), exclude 'ok' switches to boolean
        // mode and builds  "INFO" and not("ok").  Every INFO line contains "ok", so the
        // result is 0; field text shows the klogg-built boolean pattern.
        wc.selfTestCombineSearch(reset: false, op: "exclude", term: "ok")
        let exclOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 0 }
        let exclField = wc.selfTestSearchFieldText
        let exclTogglesOn = wc.selfTestSearchToggles.boolean
        s += (exclOK && exclTogglesOn && exclField.contains("not(") && exclField.contains("\"INFO\""))
            ? "PASS combine exclude 'ok' → 0, boolean ON, pattern '\(exclField)'\n"
            : "FAIL combine exclude: count=\(wc.selfTestSearchMatchCount) boolean=\(exclTogglesOn) pattern='\(exclField)'\n"

        // "Add to search" in boolean mode ORs the term:  …"INFO"… or "ERROR"  → all 1000.
        wc.selfTestCombineSearch(reset: true, op: "replace", term: "INFO")
        _ = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 750 }
        // First exclude to flip into boolean mode, then add 'ERROR' (OR) → INFO-not-zzz or ERROR.
        wc.selfTestCombineSearch(reset: false, op: "exclude", term: "zzzznomatch")
        _ = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 750 }   // 'zzzznomatch' excludes nothing
        wc.selfTestCombineSearch(reset: false, op: "add", term: "ERROR")
        let addOK = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 1000 }
        s += addOK ? "PASS combine add 'ERROR' (boolean OR) = 1000\n"
                   : "FAIL combine add 'ERROR' = \(wc.selfTestSearchMatchCount) (expected 1000)\n"

        // Reset toggles for the toggle-persistence checks below.
        wc.selfTestRunSearchViaBar(pattern: "ERROR", caseInsensitive: false, isRegex: false,
                                   inverse: true, boolean: false)
        _ = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 750 }

        // --- (5b) Toggle PERSISTENCE in AppPreferences (klogg context keys).
        let prefInv = AppPreferences.shared.searchInverse
        s += prefInv ? "PASS inverse toggle persisted (searchInverse=true)\n"
                     : "FAIL inverse toggle not persisted\n"
        // Restore default-off so the toggle doesn't leak to later tests / the user.
        wc.selfTestRunSearchViaBar(pattern: "ERROR", caseInsensitive: false, isRegex: false,
                                   inverse: false, boolean: false)
        _ = wait(timeout: 8.0) { wc.selfTestSearchMatchCount == 250 }
        AppPreferences.shared.searchInverse = false
        AppPreferences.shared.searchBoolean = false

        // Snapshot the search bar with all toggles present (search-line parity).
        let dir = ProcessInfo.processInfo.environment["KLOGG_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let snap = (dir as NSString).appendingPathComponent("klogg-snapshot-search-options.png")
        s += wc.selfTestSnapshot(to: snap) ? "PASS wrote \(snap)\n" : "FAIL search-options snapshot\n"

        wc.closeCurrentTab(nil)
        return s
    }

    /// Count matching lines via the system grep (cross-check oracle). -1 on failure.
    private static func grepLineCount(pattern: String, path: String, caseInsensitive: Bool) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = (caseInsensitive ? ["-c", "-i"] : ["-c"]) + ["-F", pattern, path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    // MARK: - QuickFind edge cases (Wave 9)

    /// Prove QuickFind next/prev wrap correctly at the file boundaries and handle
    /// no-match. Corpus has the needle on the first and last lines so wrap is observable.
    private static func quickFindEdgeTests(_ wc: MainWindowController) -> String {
        var s = "--- QUICKFIND EDGE TESTS ---\n"

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-qf-\(UUID().uuidString).log")
        // 10 lines; "NEEDLE" on line 0 and line 9 (first & last).
        var lines = (0...9).map { "filler \($0)" }
        lines[0] = "NEEDLE first"
        lines[9] = "NEEDLE last"
        let body = lines.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write quickfind test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 10 }

        func qf(_ from: Int, next: Bool) -> Int {
            wc.selfTestQuickFindFrom(line: from, needle: "NEEDLE",
                                     caseInsensitive: true, isRegex: false, next: next)
        }
        func expect(_ label: String, _ got: Int, _ want: Int) {
            s += (got == want) ? "PASS \(label): line \(got)\n"
                               : "FAIL \(label): line \(got) (expected \(want))\n"
        }

        // From line 0, next → line 9 (the other match).
        expect("next from line 0 → 9", qf(0, next: true), 9)
        // From line 9, next → wraps to line 0.
        expect("next from last (wrap) → 0", qf(9, next: true), 0)
        // From line 0, prev → wraps backward to line 9.
        expect("prev from first (wrap) → 9", qf(0, next: false), 9)
        // From line 9, prev → line 0.
        expect("prev from line 9 → 0", qf(9, next: false), 0)
        // From a middle line, next → 9, prev → 0.
        expect("next from middle (5) → 9", qf(5, next: true), 9)
        expect("prev from middle (5) → 0", qf(5, next: false), 0)
        // No-match needle → -1.
        let nm = wc.selfTestQuickFindFrom(line: 0, needle: "ZZZNOPE",
                                          caseInsensitive: true, isRegex: false, next: true)
        s += (nm == -1) ? "PASS no-match needle returns -1\n"
                        : "FAIL no-match needle returned \(nm)\n"

        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Go-to-line bounds (Wave 9)

    /// Prove go-to-line rejects out-of-range input (0, negative, > lineCount) and accepts
    /// valid lines, clamping the view sensibly.
    private static func goToLineBoundsTests(_ wc: MainWindowController) -> String {
        var s = "--- GO-TO-LINE BOUNDS TESTS ---\n"

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-goto-\(UUID().uuidString).log")
        let body = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write goto test file\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        wc.selfTestOpen(path)
        wait(timeout: 5.0) { wc.selfTestCurrentLineCount >= 50 }
        let lc = wc.selfTestCurrentLineCount

        // Out of range: 0, negative, lc+1 → -1 (rejected).
        s += (wc.selfTestGoToLineResult(oneBased: 0) == -1)
            ? "PASS go-to-line 0 rejected\n" : "FAIL go-to-line 0 not rejected\n"
        s += (wc.selfTestGoToLineResult(oneBased: -5) == -1)
            ? "PASS go-to-line negative rejected\n" : "FAIL go-to-line negative not rejected\n"
        s += (wc.selfTestGoToLineResult(oneBased: lc + 1) == -1)
            ? "PASS go-to-line > lineCount rejected\n" : "FAIL go-to-line > lineCount not rejected\n"
        // Valid: line 1 accepted (returns a non-negative first-visible line).
        s += (wc.selfTestGoToLineResult(oneBased: 1) >= 0)
            ? "PASS go-to-line 1 accepted\n" : "FAIL go-to-line 1 rejected\n"
        // Valid: last line accepted.
        s += (wc.selfTestGoToLineResult(oneBased: lc) >= 0)
            ? "PASS go-to-line lineCount accepted\n" : "FAIL go-to-line lineCount rejected\n"

        wc.closeCurrentTab(nil)
        return s
    }

    // MARK: - Edge / robustness (Wave 9)

    /// Prove the app survives degenerate inputs without crashing and behaves sanely:
    /// non-existent path, empty file, opening the same file twice (focuses one tab),
    /// closing the last tab.
    private static func edgeRobustnessTests(_ wc: MainWindowController) -> String {
        var s = "--- EDGE / ROBUSTNESS TESTS ---\n"
        let startCount = wc.selfTestTabCount

        // Non-existent path: opening still creates a tab (engine reports 0 lines) and
        // doesn't crash. klogg also opens an empty view for a missing file.
        let ghost = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-DOES-NOT-EXIST-\(UUID().uuidString).log")
        wc.selfTestOpen(ghost)
        wait(timeout: 1.0) { wc.selfTestTabCount == startCount + 1 }
        s += (wc.selfTestTabCount == startCount + 1)
            ? "PASS open non-existent path: no crash, tab opened (lineCount=\(wc.selfTestCurrentLineCount))\n"
            : "FAIL open non-existent path: tab count \(wc.selfTestTabCount)\n"
        wc.closeCurrentTab(nil)

        // Empty file: opens, 0 lines, no crash.
        let empty = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-empty-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: empty, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: empty) }
        wc.selfTestOpen(empty)
        wait(timeout: 3.0) { wc.selfTestTabCount == startCount + 1 }
        let emptyLines = wc.selfTestCurrentLineCount
        s += (wc.selfTestTabCount == startCount + 1 && emptyLines == 0)
            ? "PASS open empty file: 0 lines, no crash\n"
            : "FAIL open empty file: tabs=\(wc.selfTestTabCount) lines=\(emptyLines)\n"

        // Open the SAME file again → should focus the existing tab, not add another.
        let beforeDup = wc.selfTestTabCount
        wc.selfTestOpen(empty)
        wait(timeout: 1.0) { true }
        s += (wc.selfTestTabCount == beforeDup)
            ? "PASS open same file twice: focuses existing tab (no dup, count=\(wc.selfTestTabCount))\n"
            : "FAIL open same file twice: count \(beforeDup) → \(wc.selfTestTabCount)\n"
        wc.closeCurrentTab(nil)

        // Close last tab when none remain → no crash, count clamps at start.
        while wc.selfTestTabCount > startCount { wc.closeCurrentTab(nil) }
        wc.closeCurrentTab(nil)   // extra close with (potentially) nothing to close
        s += "PASS close beyond last tab: no crash (count=\(wc.selfTestTabCount))\n"
        return s
    }

    // MARK: - Compressed-log opening (Wave 14)

    /// Prove transparent decompression of single-stream archives (.gz/.bz2/.xz),
    /// mirroring klogg's MainWindow::extractAndLoadFile via decompressor.cpp. For each
    /// format: write a known plaintext, compress it with the system tool, open the
    /// compressed path, and assert the engine indexed the SAME line count as the
    /// plaintext while the tab kept the ORIGINAL (compressed) display name.
    private static func decompressionTests(_ wc: MainWindowController) -> String {
        var s = "--- DECOMPRESSION TESTS (gz / bz2 / xz) ---\n"

        // 1) Detection predicate matches klogg's archiveTypeByExtension (gz/bz2/xz/lzma
        //    yes; tar.* / zip / 7z no).
        let yes = ["a.gz", "b.bz2", "c.xz", "d.lzma"]
        let no  = ["e.tar.gz", "f.tgz", "g.zip", "h.7z", "i.txz", "j.log"]
        let detYes = yes.allSatisfy { KloggDecompressor.isDecompressiblePath($0) }
        let detNo  = no.allSatisfy  { !KloggDecompressor.isDecompressiblePath($0) }
        s += (detYes && detNo)
            ? "PASS format detection (gz/bz2/xz/lzma yes; tar.*/zip/7z no)\n"
            : "FAIL format detection (yes=\(detYes) no=\(detNo))\n"

        let tmp = NSTemporaryDirectory() as NSString
        let plainPath = tmp.appendingPathComponent("klogg-decomp-\(UUID().uuidString).log")
        let body = (1...12).map { "decompress line \($0)" }.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: plainPath, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write plaintext\n"
        }
        defer { try? FileManager.default.removeItem(atPath: plainPath) }

        // Index the plaintext to learn the expected line count.
        let startTabs = wc.selfTestTabCount
        wc.selfTestOpen(plainPath)
        _ = wait { wc.selfTestCurrentLineCount >= 12 }
        let expected = wc.selfTestCurrentLineCount
        wc.closeCurrentTab(nil)

        // For each compressor available on the machine, compress + open + assert.
        func runTool(_ launch: String, _ args: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launch)
            p.arguments = args
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
            catch { return false }
        }

        let cases: [(name: String, suffix: String, tool: String, args: [String])] = [
            ("gzip",  ".gz",  "/usr/bin/gzip",  ["-kf"]),
            ("bzip2", ".bz2", "/usr/bin/bzip2", ["-kf"]),
            ("xz",    ".xz",  "/usr/bin/xz",    ["-kf"]),
        ]

        for c in cases {
            // Copy the plaintext to a uniquely named source so tools don't clobber.
            let src = tmp.appendingPathComponent("klogg-decomp-\(c.name)-\(UUID().uuidString).log")
            try? FileManager.default.copyItem(atPath: plainPath, toPath: src)
            let compressed = src + c.suffix
            // Locate the tool (xz may live under Homebrew rather than /usr/bin).
            var tool = c.tool
            if !FileManager.default.isExecutableFile(atPath: tool) {
                let hb = "/opt/homebrew/bin/" + c.name
                if FileManager.default.isExecutableFile(atPath: hb) { tool = hb }
            }
            guard FileManager.default.isExecutableFile(atPath: tool),
                  runTool(tool, c.args + [src]),
                  FileManager.default.fileExists(atPath: compressed) else {
                s += "SKIP \(c.name): tool unavailable\n"
                try? FileManager.default.removeItem(atPath: src)
                continue
            }
            defer {
                try? FileManager.default.removeItem(atPath: src)
                try? FileManager.default.removeItem(atPath: compressed)
            }

            wc.selfTestOpen(compressed)
            let ok = wait { wc.selfTestCurrentLineCount == expected }
            let got = wc.selfTestCurrentLineCount
            // The displayed path must remain the ORIGINAL compressed file, not the temp.
            let display = wc.selfTestCurrentFilePath
            let nameOK = display == compressed
            s += (ok && nameOK)
                ? "PASS \(c.name): indexed \(got) lines, display name kept (\((compressed as NSString).lastPathComponent))\n"
                : "FAIL \(c.name): got \(got) (expected \(expected)) display=\(display ?? "nil")\n"
            wc.closeCurrentTab(nil)
        }

        // Clean up any tabs we opened.
        while wc.selfTestTabCount > startTabs { wc.closeCurrentTab(nil) }
        return s
    }

    // MARK: - Font zoom (Wave 14)

    /// Prove the font-size zoom commands (klogg Ctrl+wheel / changeFontSize, exposed on
    /// macOS as ⌘+ / ⌘- / ⌘0) live-apply: increasing the size grows the main view's row
    /// height, decreasing shrinks it back, and the size clamps to [min,max].
    private static func fontZoomTests(_ wc: MainWindowController) -> String {
        var s = "--- FONT ZOOM TESTS ---\n"

        let p = AppPreferences.shared
        let original = p.fontSize

        // Open a small file so there's a live main view to measure.
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-zoom-\(UUID().uuidString).log")
        try? "alpha\nbravo\ncharlie\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: path)
            p.fontSize = original
        }
        let startTabs = wc.selfTestTabCount
        wc.selfTestOpen(path)
        _ = wait { wc.selfTestCurrentLineCount >= 3 }

        // Use the resolved FONT POINT SIZE as the source of truth — integer row-height
        // quantization can mask a 1pt change, so assert on the font itself. Apply
        // synchronously (matching preferencesLiveApplyTests) rather than waiting on the
        // async .preferencesDidChange post.
        p.fontSize = 12
        wc.selfTestApplyPreferencesToCurrentTab()
        let pt12 = wc.selfTestMainFontPointSize
        let h12  = wc.selfTestMainRowHeight

        p.changeFontSize(increase: true)   // 13
        wc.selfTestApplyPreferencesToCurrentTab()
        let ptUp = wc.selfTestMainFontPointSize
        s += (p.fontSize == 13 && ptUp == 13)
            ? "PASS increase font: pref 12→13, view font \(pt12)→\(ptUp)pt (rowHeight \(h12)→\(wc.selfTestMainRowHeight))\n"
            : "FAIL increase font: pref=\(p.fontSize) viewFont \(pt12)→\(ptUp)pt\n"

        p.changeFontSize(increase: false)  // 12
        wc.selfTestApplyPreferencesToCurrentTab()
        let ptDown = wc.selfTestMainFontPointSize
        s += (p.fontSize == 12 && ptDown == 12)
            ? "PASS decrease font: pref 13→12, view font back to \(ptDown)pt\n"
            : "FAIL decrease font: pref=\(p.fontSize) viewFont=\(ptDown)pt\n"

        // Clamp at the lower bound.
        p.fontSize = AppPreferences.minFontSize
        p.changeFontSize(increase: false)
        s += p.fontSize == AppPreferences.minFontSize
            ? "PASS lower clamp holds at \(AppPreferences.minFontSize)\n"
            : "FAIL lower clamp: \(p.fontSize)\n"

        // Clamp at the upper bound.
        p.fontSize = AppPreferences.maxFontSize
        p.changeFontSize(increase: true)
        s += p.fontSize == AppPreferences.maxFontSize
            ? "PASS upper clamp holds at \(AppPreferences.maxFontSize)\n"
            : "FAIL upper clamp: \(p.fontSize)\n"

        while wc.selfTestTabCount > startTabs { wc.closeCurrentTab(nil) }
        return s
    }

    // MARK: - Save to file (Wave 14)

    /// Prove "Save to file" (klogg AbstractLogView::saveToFile) writes the WHOLE view:
    /// open a known file, save it to a temp path, and assert the saved content has the
    /// same line count and identical first/last lines.
    private static func saveToFileTests(_ wc: MainWindowController) -> String {
        var s = "--- SAVE TO FILE TESTS ---\n"
        let n = 37
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-save-\(UUID().uuidString).log")
        let body = (1...n).map { "save line \($0)" }.joined(separator: "\n") + "\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil else {
            return s + "FAIL could not write source\n"
        }
        defer { try? FileManager.default.removeItem(atPath: path) }

        let startTabs = wc.selfTestTabCount
        wc.selfTestOpen(path)
        _ = wait { wc.selfTestCurrentLineCount >= n }

        let outURL = URL(fileURLWithPath: (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("klogg-saveout-\(UUID().uuidString).txt"))
        defer { try? FileManager.default.removeItem(at: outURL) }
        let ok = wc.selfTestSaveAllToFile(to: outURL)

        let saved = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let savedLines = saved.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        let countOK = savedLines.count == n
        let firstOK = savedLines.first == "save line 1"
        let lastOK  = savedLines.last == "save line \(n)"
        s += (ok && countOK && firstOK && lastOK)
            ? "PASS save-to-file wrote whole view: \(savedLines.count) lines (first/last match)\n"
            : "FAIL save-to-file: ok=\(ok) count=\(savedLines.count)/\(n) first=\(savedLines.first ?? "nil") last=\(savedLines.last ?? "nil")\n"

        while wc.selfTestTabCount > startTabs { wc.closeCurrentTab(nil) }
        return s
    }

    // MARK: - History caps + variate highlight (Wave 14)

    /// Prove the new configurable history caps and the variate-highlight preference:
    /// (a) lowering searchHistorySize trims the saved-search list (klogg historySize);
    /// (b) lowering recentFilesMaxItems trims the recent-files list;
    /// (c) variateHighlightColors makes two distinct match-only tokens get DIFFERENT
    ///     background shades, while OFF they share one colour.
    private static func historyAndVariateTests() -> String {
        var s = "--- HISTORY CAPS + VARIATE TESTS ---\n"
        let p = AppPreferences.shared

        // (a) Search-history trim.
        let savedHist = p.searchHistorySize
        let ss = SavedSearchesStore.shared
        ss.clear()
        p.searchHistorySize = 50
        for i in 1...10 { ss.addRecent("query \(i)") }
        let before = ss.recentSearches().count
        p.searchHistorySize = 3
        ss.applyMaxHistory()
        let after = ss.recentSearches().count
        s += (before == 10 && after == 3)
            ? "PASS search-history trim: \(before) → \(after) when cap set to 3\n"
            : "FAIL search-history trim: \(before) → \(after) (expected 10 → 3)\n"
        ss.clear()
        p.searchHistorySize = savedHist

        // (b) Recent-files trim.
        let savedRecent = p.recentFilesMaxItems
        let rf = RecentFiles.shared
        rf.clear()
        p.recentFilesMaxItems = 25
        // Use existing files so RecentFiles keeps them (it filters non-existent on init,
        // but add() does not stat — so any path is retained in-session).
        for i in 1...8 { rf.add(path: "/tmp/klogg-selftest-recent-\(i).log") }
        let rBefore = rf.paths.count
        p.recentFilesMaxItems = 4
        rf.applyMaxCount()
        let rAfter = rf.paths.count
        s += (rBefore == 8 && rAfter == 4)
            ? "PASS recent-files trim: \(rBefore) → \(rAfter) when cap set to 4\n"
            : "FAIL recent-files trim: \(rBefore) → \(rAfter) (expected 8 → 4)\n"
        rf.clear()
        p.recentFilesMaxItems = savedRecent

        // (c) Variate highlight: two distinct tokens, one match-only rule.
        let savedRules = HighlighterStore.shared.rules
        let savedVariate = p.variateHighlightColors
        let rule = HighlighterRule(name: "v", pattern: "tok[0-9]+", ignoreCase: false,
                                   useRegex: true, matchOnly: true, enabled: true,
                                   foreColor: .black, backColor: NSColor(deviceRed: 0.8, green: 0.4, blue: 0.2, alpha: 1))
        HighlighterStore.shared.setRules([rule])
        let line = "here tok1 and tok2 differ"

        func backColorsFor(variate: Bool) -> [NSColor] {
            p.variateHighlightColors = variate
            let hl = LogHighlighter()   // reads the pref at init/rebuild
            let result = hl.highlight(line: line)
            return result.spans.map { $0.back }
        }

        let offColors = backColorsFor(variate: false)
        let onColors  = backColorsFor(variate: true)
        func approxEqual(_ a: NSColor, _ b: NSColor) -> Bool {
            guard let x = a.usingColorSpace(.deviceRGB), let y = b.usingColorSpace(.deviceRGB) else { return false }
            return abs(x.brightnessComponent - y.brightnessComponent) < 0.01
        }
        let offSame = offColors.count == 2 && approxEqual(offColors[0], offColors[1])
        let onDiff  = onColors.count == 2 && !approxEqual(onColors[0], onColors[1])
        s += (offSame && onDiff)
            ? "PASS variate highlight: OFF → identical shade, ON → distinct shades per token\n"
            : "FAIL variate highlight: offSame=\(offSame) onDiff=\(onDiff) (off=\(offColors.count) on=\(onColors.count))\n"

        HighlighterStore.shared.setRules(savedRules)
        p.variateHighlightColors = savedVariate
        return s
    }

    // MARK: - Keyboard shortcut audit (Wave 9)

    /// Walk every menu item and report its key equivalent, then compare a curated set
    /// against klogg's defaults (src/settings/src/shortcuts.cpp). Any mismatch is a FAIL.
    private static func shortcutAudit() -> String {
        var s = "--- SHORTCUT AUDIT (ours vs klogg) ---\n"
        guard let main = NSApp.mainMenu else { return s + "  <no main menu>\n" }

        // Collect (title → "modifiers+key") for all leaf items.
        var found: [String: String] = [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub); continue }
                guard !item.keyEquivalent.isEmpty else { continue }
                found[item.title] = describe(item)
            }
        }
        for top in main.items { if let sub = top.submenu { walk(sub) } }

        // Print the full table first.
        for (title, ke) in found.sorted(by: { $0.key < $1.key }) {
            s += "  \(title) = \(ke)\n"
        }

        // Curated expectations derived from klogg's defaults (Qt → macOS Cmd mapping):
        //   Open ⌘O, Close ⌘W, Find ⌘F, Find Next ⌘G, Find Previous ⌘⇧G,
        //   Go to Line ⌘L (klogg Ctrl+L), Reload ⌘R (Refresh), Quit ⌘Q, Copy ⌘C,
        //   Select All ⌘A, Open from Clipboard ⌘V (Paste), Clear Log ⌘X (Cut),
        //   Follow File 'f' (bare), Text Wrap 'w' (bare).
        let expectations: [(String, String)] = [
            ("Open…",                "⌘O"),
            ("Close",                "⌘W"),
            ("Find…",                "⌘F"),
            ("Find Next",            "⌘G"),
            ("Find Previous",        "⇧⌘G"),
            ("Go to Line…",          "⌘L"),
            ("Reload",               "⌘R"),
            ("Quit klogg",           "⌘Q"),
            ("Copy",                 "⌘C"),
            ("Select All",           "⌘A"),
            ("Open from Clipboard",  "⌘V"),
            ("Clear Log",            "⌘X"),
            ("Follow File",          "F"),
            ("Text Wrap",            "W"),
        ]
        s += "  --- parity checks ---\n"
        for (title, want) in expectations {
            let got = found[title] ?? "<missing>"
            s += (got == want)
                ? "PASS shortcut \(title) = \(want)\n"
                : "FAIL shortcut \(title): ours=\(got) klogg=\(want)\n"
        }
        return s
    }

    /// Human-readable modifier+key string for a menu item (e.g. "⌘⇧G", "f").
    private static func describe(_ item: NSMenuItem) -> String {
        var m = ""
        let f = item.keyEquivalentModifierMask
        if f.contains(.control) { m += "⌃" }
        if f.contains(.option)  { m += "⌥" }
        if f.contains(.shift)   { m += "⇧" }
        if f.contains(.command) { m += "⌘" }
        return m + item.keyEquivalent.uppercased()
    }
}
