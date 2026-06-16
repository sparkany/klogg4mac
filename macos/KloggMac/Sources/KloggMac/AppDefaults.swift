//
//  AppDefaults.swift — single swappable UserDefaults backing store.
//
//  Every persisted store in the app (AppPreferences, FavoritesStore,
//  HighlighterStore, ColorLabelsStore, PredefinedFilterStore, RecentFiles,
//  SavedSearchesStore) reads/writes through `AppDefaults.store` instead of
//  `UserDefaults.standard` directly.
//
//  Why: the headless `--selftest` harness round-trips favorites / highlighters /
//  filters / session / color-labels through these stores. If they wrote to the
//  real "KloggMac" domain, running --selftest would corrupt the user's actual
//  preferences (a known defect). The selftest entry point swaps `store` to a
//  throwaway suite (`useIsolatedSuite()`) BEFORE any `.shared` store is touched,
//  so nothing the harness does ever reaches the user's real defaults.
//
//  In normal app runs `store` is `UserDefaults.standard`, so behaviour is
//  unchanged.
//

import Foundation

enum AppDefaults {

    /// The UserDefaults all persisted stores route through. Defaults to the real
    /// per-user domain; swapped to an isolated suite under --selftest.
    private(set) static var store: UserDefaults = .standard

    /// Point every store at a fresh, throwaway suite so test mutations never touch
    /// the user's real "KloggMac" preferences. The suite is cleared on entry so each
    /// run starts from defaults. Must be called before any `.shared` store is first
    /// accessed (the stores read their initial state in `init`).
    static func useIsolatedSuite(named name: String = "klogg.selftest.isolated") {
        let suite = UserDefaults(suiteName: name) ?? .standard
        // Start clean: remove anything a previous run left behind.
        suite.removePersistentDomain(forName: name)
        store = suite
    }
}
