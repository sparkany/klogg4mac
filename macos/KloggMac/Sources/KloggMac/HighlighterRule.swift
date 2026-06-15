//
//  HighlighterRule.swift — Data model for a single highlighter rule.
//
//  Mirrors klogg's Highlighter / HighlighterSet storage schema so that rule
//  files written here are readable by the Qt port (and vice-versa via the
//  shared QSettings / UserDefaults bridge in the engine layer).
//
//  Persistence key layout (UserDefaults, matching klogg QSettings groups):
//    klogg.highlighters  →  [[String: Any]]
//      Each dict:
//        "regexp"        String   – raw pattern
//        "ignore_case"   Bool
//        "match_only"    Bool     – highlight only the matched span (not full line)
//        "use_regex"     Bool
//        "fore_colour"   String   – "#AARRGGBB"
//        "back_colour"   String   – "#AARRGGBB"
//        "enabled"       Bool     – macOS-native extension (klogg ignores unknown keys)
//        "name"          String   – macOS-native extension for human label
//

import AppKit

// MARK: - HighlighterRule

struct HighlighterRule: Codable, Equatable {

    var name: String           // display label (macOS extension)
    var pattern: String        // raw text or regex
    var ignoreCase: Bool
    var useRegex: Bool
    var matchOnly: Bool        // highlight only the matched span, not the full line
    var enabled: Bool          // macOS extension; klogg ignores on import
    var foreColorHex: String   // "#AARRGGBB" — klogg format
    var backColorHex: String

    // Defaults matching klogg's Highlighter constructor defaults.
    init(
        name: String = "Rule",
        pattern: String = "",
        ignoreCase: Bool = false,
        useRegex: Bool = true,
        matchOnly: Bool = false,
        enabled: Bool = true,
        foreColor: NSColor = .labelColor,
        backColor: NSColor = .yellow
    ) {
        self.name = name
        self.pattern = pattern
        self.ignoreCase = ignoreCase
        self.useRegex = useRegex
        self.matchOnly = matchOnly
        self.enabled = enabled
        self.foreColorHex = foreColor.toArgbHex()
        self.backColorHex = backColor.toArgbHex()
    }

    var foreColor: NSColor { NSColor(argbHex: foreColorHex) ?? .labelColor }
    var backColor: NSColor { NSColor(argbHex: backColorHex) ?? .yellow }
}

// MARK: - NSColor hex helpers

private extension NSColor {
    /// Returns "#AARRGGBB" (klogg's fore_colour / back_colour format).
    func toArgbHex() -> String {
        guard let c = usingColorSpace(.deviceRGB) else { return "#FFEEEEEE" }
        let a = Int(c.alphaComponent * 255)
        let r = Int(c.redComponent   * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent  * 255)
        return String(format: "#%02X%02X%02X%02X", a, r, g, b)
    }
}

extension NSColor {
    /// Parse "#AARRGGBB" or "#RRGGBB" (klogg QColor::name(HexArgb) format).
    convenience init?(argbHex: String) {
        var hex = argbHex.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
        let a, r, g, b: CGFloat
        if hex.count == 8 {
            a = CGFloat((value >> 24) & 0xFF) / 255
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >>  8) & 0xFF) / 255
            b = CGFloat( value        & 0xFF) / 255
        } else if hex.count == 6 {
            a = 1.0
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >>  8) & 0xFF) / 255
            b = CGFloat( value        & 0xFF) / 255
        } else {
            return nil
        }
        self.init(deviceRed: r, green: g, blue: b, alpha: a)
    }
}
