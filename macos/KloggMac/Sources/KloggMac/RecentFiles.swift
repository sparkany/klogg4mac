//
//  RecentFiles.swift — Persisted recent-files list (mirrors klogg's RecentFiles).
//
//  Backed by UserDefaults (klogg.recentFiles). Capped at maxCount entries.
//  Matching klogg's behaviour: opening a file moves it to the top; duplicates
//  are removed before insertion.
//

import Foundation

final class RecentFiles {

    static let shared = RecentFiles()

    // Cap is configurable via Preferences (klogg recentFiles.filesHistoryMaxItems).
    private var maxCount: Int { AppPreferences.shared.recentFilesMaxItems }
    private let defaultsKey = "klogg.recentFiles"

    // Observers receive the updated list.
    var onChange: (([String]) -> Void)?

    private(set) var paths: [String] {
        didSet { persist(); onChange?(paths) }
    }

    private init() {
        let stored = AppDefaults.store.stringArray(forKey: defaultsKey) ?? []
        paths = stored.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Record `path` as most-recently used. Duplicate is moved to front.
    func add(path: String) {
        var updated = paths.filter { $0 != path }
        updated.insert(path, at: 0)
        if updated.count > maxCount { updated = Array(updated.prefix(maxCount)) }
        paths = updated
    }

    /// Remove a single path.
    func remove(path: String) {
        paths = paths.filter { $0 != path }
    }

    /// Clear the entire list.
    func clear() {
        paths = []
    }

    /// Re-apply the (possibly lowered) max-count preference, trimming the tail.
    func applyMaxCount() {
        if paths.count > maxCount { paths = Array(paths.prefix(maxCount)) }
    }

    private func persist() {
        AppDefaults.store.set(paths, forKey: defaultsKey)
    }
}
