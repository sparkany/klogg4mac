//
//  ColorLabelsStore.swift — quick-assign colour labels for selected text.
//
//  Faithful port of klogg's ColorLabelsManager (src/ui/.../colorlabelsmanager):
//  a small fixed set of colour "slots" the user can quick-assign (⌘1–⌘9) to the
//  currently-selected token. A labelled token is shown coloured in the log view.
//
//  Implementation strategy (per the Wave-8 brief): rather than a separate drawing
//  layer, each label is materialised as a match-only HighlighterRule-equivalent in a
//  PARALLEL "labels" list that LogHighlighter merges with the user's highlighter
//  rules. This reuses the existing draw()/LogHighlighter span machinery — labelled
//  text colours exactly the same way a matchOnly highlighter does — so nothing in the
//  fragile render path changes shape.
//
//  A label is keyed by its literal text (case-sensitive substring), so re-assigning
//  the same token to a different slot moves it, and assigning slot 0 clears it.
//  Persisted to UserDefaults so labels survive relaunch, like klogg.
//

import AppKit

extension Notification.Name {
    /// Posted (main thread) after the colour-label set changes so log views rebuild
    /// their compiled rules and repaint. Distinct from .highlightersDidChange so the
    /// two layers can refresh independently.
    static let colorLabelsDidChange = Notification.Name("klogg.colorLabelsDidChange")
}

/// One assigned colour label: a literal token plus the slot's colour.
struct ColorLabel: Codable, Equatable {
    var text: String        // the literal selected substring
    var slot: Int           // 1...ColorLabelsStore.slotCount
}

final class ColorLabelsStore {

    static let shared = ColorLabelsStore()

    /// Number of colour slots (klogg ships 9, mapped to ⌘1–⌘9). Slot 0 = "clear".
    static let slotCount = 9

    /// The slot palette. Backgrounds are vivid match washes; the foreground is chosen
    /// per-slot for contrast. Index 0 is unused (slot numbers are 1-based).
    static let palette: [NSColor] = [
        .clear,                                              // 0 — unused / clear
        NSColor.systemYellow.withAlphaComponent(0.55),
        NSColor.systemGreen.withAlphaComponent(0.50),
        NSColor.systemTeal.withAlphaComponent(0.50),
        NSColor.systemBlue.withAlphaComponent(0.45),
        NSColor.systemPurple.withAlphaComponent(0.45),
        NSColor.systemPink.withAlphaComponent(0.45),
        NSColor.systemOrange.withAlphaComponent(0.55),
        NSColor.systemRed.withAlphaComponent(0.45),
        NSColor.systemGray.withAlphaComponent(0.50),
    ]

    /// Colour for a slot (1-based); falls back to yellow for out-of-range slots.
    static func color(forSlot slot: Int) -> NSColor {
        guard slot >= 1, slot < palette.count else { return palette[1] }
        return palette[slot]
    }

    private(set) var labels: [ColorLabel] = []
    var onChange: (([ColorLabel]) -> Void)?

    private let key = "klogg.colorLabels"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() { load() }

    /// Assign `text` to `slot`. Slot 0 (or empty text) clears any existing label for
    /// that text. Re-assigning an already-labelled token moves it to the new slot.
    func assign(text: String, slot: Int) {
        let token = text
        guard !token.isEmpty else { return }
        labels.removeAll { $0.text == token }
        if slot >= 1, slot <= ColorLabelsStore.slotCount {
            labels.append(ColorLabel(text: token, slot: slot))
        }
        save()
        notify()
    }

    /// Remove every assigned label.
    func clearAll() {
        guard !labels.isEmpty else { return }
        labels.removeAll()
        save()
        notify()
    }

    /// The slot currently assigned to `text`, or 0 if unlabelled.
    func slot(forText text: String) -> Int {
        labels.first { $0.text == text }?.slot ?? 0
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onChange?(self.labels)
            NotificationCenter.default.post(name: .colorLabelsDidChange, object: self)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? decoder.decode([ColorLabel].self, from: data) else {
            labels = []
            return
        }
        labels = decoded
    }

    private func save() {
        guard let data = try? encoder.encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
