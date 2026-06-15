//
//  QuickFindController.swift — incremental in-place find over engine lines (Wave 6).
//
//  Mirrors klogg's QuickFind (src/ui/src/quickfind.cpp): given a needle it scans the
//  log line-by-line FROM THE CURRENT POSITION (forward or backward), stopping at the
//  first match — it never builds a filtered index, so it stays responsive on huge
//  files. Wrap-around is supported and reported so the UI can flash "Search hit
//  bottom, continued from top".
//
//  Line access goes through the KloggEngine bridge (lineStringAtIndex:) — one line at
//  a time, so memory stays O(1). A scan is bounded by the line count; for a needle
//  with no hits this is O(lineCount) string matches but only on the (rare) full-miss
//  path. Each line match uses NSRegularExpression.firstMatch on a single line.
//

import AppKit
import KloggBridge

final class QuickFindController {

    enum Direction { case forward, backward }

    /// Result of a find step.
    struct Result {
        let line: Int        // 0-based matched source line
        let wrapped: Bool    // true when the scan wrapped past an end
    }

    private let engine: KloggEngine
    private var regex: NSRegularExpression?
    private var caseInsensitive = true

    init(engine: KloggEngine) {
        self.engine = engine
    }

    /// Set the active needle. Returns false if the pattern is empty / won't compile.
    /// QuickFind treats the needle as a literal substring (klogg's default), unless
    /// `isRegex` is set, matching the SearchBarView semantics for consistency.
    @discardableResult
    func setNeedle(_ needle: String, caseInsensitive ci: Bool, isRegex: Bool = false) -> Bool {
        caseInsensitive = ci
        guard !needle.isEmpty else { regex = nil; return false }
        regex = LogDocumentView.compile(pattern: needle, caseInsensitive: ci, isRegex: isRegex)
        return regex != nil
    }

    /// The compiled needle (nil when empty / invalid) — for highlight wiring.
    var hasNeedle: Bool { regex != nil }

    /// Find the next/previous match relative to `from` (0-based). When `inclusive`
    /// is true the `from` line itself is eligible (used for the first incremental
    /// find as the user types, so a match on the current line is found in place);
    /// when false the search starts at the adjacent line (used by Return/next).
    /// Returns nil when there is no match anywhere in the file.
    func find(direction: Direction, from: Int, inclusive: Bool) -> Result? {
        guard let regex = regex else { return nil }
        let count = Int(engine.lineCount())
        guard count > 0 else { return nil }

        let start = max(0, min(from, count - 1))

        switch direction {
        case .forward:
            let first = inclusive ? start : start + 1
            // [first, count)
            if first < count, let hit = scanForward(regex, lo: first, hi: count - 1) {
                return Result(line: hit, wrapped: false)
            }
            // wrap: [0, first)
            if first > 0, let hit = scanForward(regex, lo: 0, hi: first - 1) {
                return Result(line: hit, wrapped: true)
            }
            // inclusive==false but the start line itself may match after a full wrap
            if !inclusive, lineMatches(regex, start) {
                return Result(line: start, wrapped: true)
            }
            return nil

        case .backward:
            let first = inclusive ? start : start - 1
            if first >= 0, let hit = scanBackward(regex, lo: 0, hi: first) {
                return Result(line: hit, wrapped: false)
            }
            // wrap: (first, count)
            if first < count - 1, let hit = scanBackward(regex, lo: first + 1, hi: count - 1) {
                return Result(line: hit, wrapped: true)
            }
            if !inclusive, lineMatches(regex, start) {
                return Result(line: start, wrapped: true)
            }
            return nil
        }
    }

    // MARK: - Scanning (one line at a time, O(1) memory)

    private func scanForward(_ regex: NSRegularExpression, lo: Int, hi: Int) -> Int? {
        guard lo <= hi else { return nil }
        for line in lo ... hi where lineMatches(regex, line) { return line }
        return nil
    }

    private func scanBackward(_ regex: NSRegularExpression, lo: Int, hi: Int) -> Int? {
        guard lo <= hi else { return nil }
        var line = hi
        while line >= lo {
            if lineMatches(regex, line) { return line }
            line -= 1
        }
        return nil
    }

    private func lineMatches(_ regex: NSRegularExpression, _ index: Int) -> Bool {
        guard let text = engine.lineString(at: UInt(index)) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
