//
//  MarksStore.swift — per-file line marks (bookmarks), mirroring klogg's Marks.
//
//  klogg lets the user MARK lines (abstractlogview: click the left bullet margin,
//  the &Mark/Unmark context-menu action, or the mark keyboard shortcut). Marks are
//  drawn as a filled arrow in the left bullet zone and persisted per file in the
//  session. This is a pure UI-layer concept here (the Obj-C bridge exposes none),
//  so we keep the marks in Swift and persist them per absolute file path through
//  AppDefaults (so --selftest stays isolated, see [AppDefaults]).
//
//  Marks are stored as ORIGINAL (source) 0-based line indices — the same identity
//  klogg uses — so they survive switching between the main and filtered views.
//

import Foundation

extension Notification.Name {
    /// Posted (main thread) after the mark set for some file changes, so any open
    /// view of that file repaints its gutter.
    static let marksDidChange = Notification.Name("klogg.marksDidChange")
}

/// Marks for a single open file. One instance per CrawlerTab; persistence is keyed
/// by the file's absolute path so reopening the file restores its marks.
final class MarksStore {

    /// Absolute path this store persists under (empty for unsaved/synthetic files).
    private let filePath: String
    private let keyPrefix = "klogg.marks."

    /// The set of marked source-line indices (0-based). Kept sorted for "next/prev
    /// mark" navigation and stable persistence.
    private(set) var marks: Set<Int> = []

    init(filePath: String) {
        self.filePath = filePath
        load()
    }

    private var key: String { keyPrefix + filePath }

    private func load() {
        guard !filePath.isEmpty,
              let arr = AppDefaults.store.array(forKey: key) as? [Int] else { return }
        marks = Set(arr)
    }

    private func persist() {
        guard !filePath.isEmpty else { return }
        if marks.isEmpty {
            AppDefaults.store.removeObject(forKey: key)
        } else {
            AppDefaults.store.set(marks.sorted(), forKey: key)
        }
        NotificationCenter.default.post(name: .marksDidChange, object: self)
    }

    func isMarked(_ line: Int) -> Bool { marks.contains(line) }

    /// Mark `line` (no-op if already marked).
    func mark(_ line: Int) {
        guard !marks.contains(line) else { return }
        marks.insert(line)
        persist()
    }

    /// Unmark `line` (no-op if not marked).
    func unmark(_ line: Int) {
        guard marks.contains(line) else { return }
        marks.remove(line)
        persist()
    }

    /// Toggle a set of lines: if ANY of them is currently unmarked, mark them all;
    /// otherwise unmark them all. Mirrors klogg's &Mark/Unmark behaviour where the
    /// action text flips to "Unmark" only when every selected line is already marked.
    func toggle(lines: [Int]) {
        guard !lines.isEmpty else { return }
        let hasUnmarked = lines.contains { !marks.contains($0) }
        if hasUnmarked {
            for l in lines { marks.insert(l) }
        } else {
            for l in lines { marks.remove(l) }
        }
        persist()
    }

    func clearAll() {
        guard !marks.isEmpty else { return }
        marks.removeAll()
        persist()
    }

    /// Sorted marks > `line`, wrapping to the first mark. nil if there are no marks.
    func nextMark(after line: Int) -> Int? {
        let sorted = marks.sorted()
        return sorted.first { $0 > line } ?? sorted.first
    }

    /// Sorted marks < `line`, wrapping to the last mark. nil if there are no marks.
    func previousMark(before line: Int) -> Int? {
        let sorted = marks.sorted()
        return sorted.last { $0 < line } ?? sorted.last
    }
}
