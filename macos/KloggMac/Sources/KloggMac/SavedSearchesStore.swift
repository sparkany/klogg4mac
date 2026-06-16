//
//  SavedSearchesStore.swift — recent-search history (mirrors klogg's SavedSearches).
//
//  klogg's search line edit is a combo box whose dropdown lists recent searches,
//  persisted in QSettings (savedsearches.cpp). Behaviour replicated 1:1:
//    * addRecent: ignore blanks, remove any existing duplicate, push to the FRONT,
//      then trim to historySize (default MaxNumberOfRecentSearches = 50).
//    * recentSearches: most-recent-first.
//  Persisted through AppDefaults so --selftest stays isolated (see [AppDefaults]).
//

import Foundation

extension Notification.Name {
    /// Posted (main thread) after the recent-search list changes so open search bars
    /// can rebuild their dropdown.
    static let savedSearchesDidChange = Notification.Name("klogg.savedSearchesDidChange")
}

final class SavedSearchesStore {

    static let shared = SavedSearchesStore()

    /// History size is configurable via Preferences (klogg savedSearches.historySize,
    /// default MaxNumberOfRecentSearches = 50).
    private var maxHistory: Int { AppPreferences.shared.searchHistorySize }
    private let key = "klogg.savedSearches"

    private(set) var searches: [String] = []

    private init() {
        searches = AppDefaults.store.stringArray(forKey: key) ?? []
    }

    /// Most-recent-first list of recent searches (klogg recentSearches()).
    func recentSearches() -> [String] { searches }

    /// Record a search (klogg addRecent): skip blanks, de-dupe, push front, trim.
    func addRecent(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        searches.removeAll { $0 == t }
        searches.insert(t, at: 0)
        if searches.count > maxHistory {
            searches = Array(searches.prefix(maxHistory))
        }
        persist()
    }

    /// Re-apply the (possibly lowered) history-size preference, trimming the tail.
    func applyMaxHistory() {
        if searches.count > maxHistory {
            searches = Array(searches.prefix(maxHistory))
            persist()
        }
    }

    func clear() {
        guard !searches.isEmpty else { return }
        searches.removeAll()
        persist()
    }

    private func persist() {
        AppDefaults.store.set(searches, forKey: key)
        NotificationCenter.default.post(name: .savedSearchesDidChange, object: self)
    }
}
