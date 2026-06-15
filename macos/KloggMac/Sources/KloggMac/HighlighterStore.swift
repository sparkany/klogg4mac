//
//  HighlighterStore.swift — Singleton that persists highlighter rules to
//  UserDefaults and notifies subscribers when the list changes.
//
//  Storage key: "klogg.highlighters" → JSON-encoded [HighlighterRule].
//  Keys within each rule match klogg's QSettings schema so that rules can
//  be round-tripped via the shared settings file.
//

import Foundation

final class HighlighterStore {

    static let shared = HighlighterStore()

    // Sorted list of highlighter rules; first rule wins on a per-line match.
    private(set) var rules: [HighlighterRule] = []

    /// Called on the main thread whenever the rule list changes.
    var onChange: (([HighlighterRule]) -> Void)?

    private let key = "klogg.highlighters"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        load()
    }

    // MARK: - Public API

    /// Replace the entire rule list and persist.
    func setRules(_ newRules: [HighlighterRule]) {
        rules = newRules
        save()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onChange?(self.rules)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? decoder.decode([HighlighterRule].self, from: data) else {
            rules = []
            return
        }
        rules = decoded
    }

    private func save() {
        guard let data = try? encoder.encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
