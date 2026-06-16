//
//  LogHighlighter.swift — Applies HighlighterStore rules to log text during draw.
//
//  Faithful port of klogg's HighlighterSet::matchLine (src/ui/src/highlighterset.cpp):
//    * Rules are evaluated from LAST to FIRST in the list.
//    * A matching `matchOnly == false` (full-line) rule sets LineMatch, clears any
//      accumulated word matches, and colors the WHOLE line with that rule's colors.
//      Because evaluation is last→first, the FIRST full-line rule in the list wins.
//    * A matching `matchOnly == true` (word) rule contributes the matched substring
//      ranges; these accumulate (WordMatch) unless a full-line rule later clears them.
//
//  Compiled NSRegularExpressions are cached, keyed by the rule's pattern + options,
//  so draw() never recompiles a pattern per frame. The cache is rebuilt only when the
//  rule list actually changes (HighlighterStore.onChange → rebuild()).
//

import AppKit

/// One coloured span within a line (UTF-16 offsets, matching NSString ranges).
struct HighlightSpan {
    let range: NSRange
    let fore: NSColor
    let back: NSColor
}

/// Per-line highlight result: whether the whole line is coloured (LineMatch) plus
/// the spans to paint. For a full-line match `spans` holds a single line-wide span.
struct LineHighlight {
    let isFullLine: Bool
    let spans: [HighlightSpan]

    static let none = LineHighlight(isFullLine: false, spans: [])
    var isEmpty: Bool { spans.isEmpty }
}

/// Holds compiled rules and evaluates a single line against them.
final class LogHighlighter {

    /// One compiled rule: the NSRegularExpression (nil if the pattern failed to
    /// compile) plus the resolved colours and the full-line/word mode.
    private struct CompiledRule {
        let regex: NSRegularExpression?
        let fore: NSColor
        let back: NSColor
        let matchOnly: Bool
    }

    private var compiled: [CompiledRule] = []

    /// True when at least one enabled rule compiled — lets draw() skip all work
    /// when there are no highlighters.
    private(set) var hasRules = false

    /// Cached at rebuild(): whether match-only spans get a per-token shade variation
    /// (klogg variateColors). Read once per rebuild so draw() doesn't hit prefs.
    private var variateColors = false

    /// klogg colorVariance_ default — the ± percentage applied to the darker() factor.
    private static let colorVariance = 15

    /// Map a matched token to a QColor::darker-style factor (100 = unchanged),
    /// deterministically per token (klogg seeds minstd_rand0 with crc32(match)).
    private static func variFactor(for token: String) -> Int {
        var h: UInt32 = 2166136261   // FNV-1a, a stable per-token hash
        for b in token.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let span = 2 * colorVariance + 1
        return 100 - colorVariance + Int(h % UInt32(span))
    }

    init() {
        rebuild()
    }

    /// Recompile from the current HighlighterStore rules. Call when the list changes.
    ///
    /// Colour labels (ColorLabelsStore) are merged in as match-only rules AFTER the
    /// user rules. Because highlight() evaluates last→first, labels are applied first
    /// in the pass and accumulate as word matches under any later user rules — i.e. a
    /// quick label colours just the selected token, exactly like a matchOnly rule.
    func rebuild() {
        var rules: [CompiledRule] = HighlighterStore.shared.rules.compactMap { rule in
            guard rule.enabled, !rule.pattern.isEmpty else { return nil }

            // klogg's non-regex mode is a literal substring match; escape the pattern.
            let patternText = rule.useRegex
                ? rule.pattern
                : NSRegularExpression.escapedPattern(for: rule.pattern)

            var options: NSRegularExpression.Options = []
            if rule.ignoreCase { options.insert(.caseInsensitive) }

            let regex = try? NSRegularExpression(pattern: patternText, options: options)
            return CompiledRule(regex: regex,
                                fore: rule.foreColor,
                                back: rule.backColor,
                                matchOnly: rule.matchOnly)
        }

        // Colour labels: literal, case-sensitive, match-only spans coloured by slot.
        for label in ColorLabelsStore.shared.labels {
            guard !label.text.isEmpty else { continue }
            let patternText = NSRegularExpression.escapedPattern(for: label.text)
            let regex = try? NSRegularExpression(pattern: patternText, options: [])
            rules.append(CompiledRule(regex: regex,
                                      fore: .labelColor,
                                      back: ColorLabelsStore.color(forSlot: label.slot),
                                      matchOnly: true))
        }

        compiled = rules
        hasRules = !compiled.isEmpty
        variateColors = AppPreferences.shared.variateHighlightColors
    }

    /// Evaluate `line` against the compiled rules, mirroring klogg's last→first pass.
    func highlight(line: String) -> LineHighlight {
        guard hasRules else { return .none }

        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)

        var spans: [HighlightSpan] = []
        var isFullLine = false

        // Iterate from last rule to first (klogg semantics).
        for rule in compiled.reversed() {
            guard let regex = rule.regex else { continue }
            let matches = regex.matches(in: line, options: [], range: full)
            guard !matches.isEmpty else { continue }

            if rule.matchOnly {
                // Word match: contribute the matched substring ranges (or capture
                // groups, as klogg does when the pattern has capture groups). When the
                // "variate colours" preference is on, derive a per-match shade from a
                // hash of the matched text (klogg Highlighter::vairateColors), so each
                // distinct token gets a consistent but distinguishable colour.
                let variate = variateColors
                for m in matches {
                    func addSpan(_ r: NSRange) {
                        guard r.location != NSNotFound, r.length > 0 else { return }
                        if variate {
                            let token = ns.substring(with: r)
                            let factor = Self.variFactor(for: token)
                            spans.append(HighlightSpan(range: r,
                                                       fore: rule.fore.darkened(by: factor),
                                                       back: rule.back.darkened(by: factor)))
                        } else {
                            spans.append(HighlightSpan(range: r, fore: rule.fore, back: rule.back))
                        }
                    }
                    if m.numberOfRanges > 1 {
                        for i in 1..<m.numberOfRanges { addSpan(m.range(at: i)) }
                    } else {
                        addSpan(m.range)
                    }
                }
            } else {
                // Full-line match: clear accumulated word matches and colour the
                // whole line. Because we go last→first, the first such rule wins.
                isFullLine = true
                spans = [HighlightSpan(range: full, fore: rule.fore, back: rule.back)]
            }
        }

        return LineHighlight(isFullLine: isFullLine, spans: spans)
    }
}

// MARK: - QColor::darker(factor) equivalent

private extension NSColor {
    /// Mirror Qt's QColor::darker(factor): for factor >= 100, divide value (HSV) by
    /// factor/100; for factor < 100 it lightens. Operates in HSB to match Qt.
    func darkened(by factor: Int) -> NSColor {
        guard let c = usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let f = CGFloat(max(1, factor)) / 100.0
        let nb = min(1.0, max(0.0, b / f))
        return NSColor(hue: h, saturation: s, brightness: nb, alpha: a)
    }
}
