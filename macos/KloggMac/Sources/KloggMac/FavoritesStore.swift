//
//  FavoritesStore.swift — Persisted favorite-files list (mirrors klogg's favorites).
//
//  Backed by UserDefaults (klogg.favorites). Unlike RecentFiles this is not capped
//  and preserves insertion order; the user explicitly adds/removes entries.
//

import Foundation

final class FavoritesStore {

    static let shared = FavoritesStore()

    private let defaultsKey = "klogg.favorites"

    // Observers receive the updated list (main thread).
    var onChange: (([String]) -> Void)?

    private(set) var paths: [String] {
        didSet { persist(); onChange?(paths) }
    }

    private init() {
        paths = AppDefaults.store.stringArray(forKey: defaultsKey) ?? []
    }

    func isFavorite(_ path: String) -> Bool {
        paths.contains(path)
    }

    /// Add `path` (no-op if already present).
    func add(path: String) {
        guard !paths.contains(path) else { return }
        paths.append(path)
    }

    /// Remove `path` (no-op if absent).
    func remove(path: String) {
        guard paths.contains(path) else { return }
        paths = paths.filter { $0 != path }
    }

    /// Toggle membership; returns true if the path is a favorite afterwards.
    @discardableResult
    func toggle(path: String) -> Bool {
        if isFavorite(path) { remove(path: path); return false }
        add(path: path); return true
    }

    private func persist() {
        AppDefaults.store.set(paths, forKey: defaultsKey)
    }
}
