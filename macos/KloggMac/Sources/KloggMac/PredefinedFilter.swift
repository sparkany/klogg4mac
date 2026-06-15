//
//  PredefinedFilter.swift — Data model + store for named predefined filters.
//
//  A predefined filter is a saved search pattern (name, regex, ignoreCase).
//  It appears in the search bar's filter picker so the user can quickly re-run
//  common patterns without retyping them.
//
//  Storage key: "klogg.predefinedFilters" → JSON-encoded [PredefinedFilter].
//  This is a macOS-native extension; the Qt port stores filters in a different
//  QSettings group but the concept is identical.
//

import Foundation

extension Notification.Name {
    /// Posted (main thread) after the predefined-filter list changes so every open
    /// tab's search-bar picker can rebuild. A plain `onChange` closure can only have one
    /// subscriber, but the picker lives per-tab, so a broadcast notification is needed
    /// to refresh all of them.
    static let predefinedFiltersDidChange = Notification.Name("klogg.predefinedFiltersDidChange")
}

// MARK: - PredefinedFilter

struct PredefinedFilter: Codable, Equatable {
    var name: String
    var pattern: String
    var ignoreCase: Bool
    var useRegex: Bool

    init(name: String = "Filter", pattern: String = "", ignoreCase: Bool = false, useRegex: Bool = true) {
        self.name = name
        self.pattern = pattern
        self.ignoreCase = ignoreCase
        self.useRegex = useRegex
    }
}

// MARK: - PredefinedFilterStore

final class PredefinedFilterStore {

    static let shared = PredefinedFilterStore()

    private(set) var filters: [PredefinedFilter] = []
    var onChange: (([PredefinedFilter]) -> Void)?

    private let key = "klogg.predefinedFilters"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() { load() }

    func setFilters(_ newFilters: [PredefinedFilter]) {
        filters = newFilters
        save()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onChange?(self.filters)
            NotificationCenter.default.post(name: .predefinedFiltersDidChange, object: self)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? decoder.decode([PredefinedFilter].self, from: data) else {
            filters = []
            return
        }
        filters = decoded
    }

    private func save() {
        guard let data = try? encoder.encode(filters) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
