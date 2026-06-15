//
//  AppPreferences.swift — Typed settings store mirroring klogg's configuration.cpp.
//
//  All keys are kept 1:1 with klogg's QSettings keys so that preference files
//  written by this app are readable by the Qt klogg build (and vice-versa).
//
//  Singleton: AppPreferences.shared.  Subscribers can set onChange to be
//  notified (on the main thread) after any value changes.
//

import Foundation

final class AppPreferences {

    static let shared = AppPreferences()
    var onChange: (() -> Void)?

    // MARK: - Display  (keys: mainFont.*, view.*)

    var fontFamily: String {
        get { str("mainFont.family", default: "") }
        set { set("mainFont.family", s: newValue) }
    }

    var fontSize: Int {
        get { int("mainFont.size", default: 12) }
        set { set("mainFont.size", i: newValue) }
    }

    var useBoldFont: Bool {
        get { bool("mainFont.bold", default: false) }
        set { set("mainFont.bold", b: newValue) }
    }

    var useTextWrap: Bool {
        get { bool("view.textWrap", default: false) }
        set { set("view.textWrap", b: newValue) }
    }

    var hideAnsiColors: Bool {
        get { bool("view.hideAnsiColors", default: false) }
        set { set("view.hideAnsiColors", b: newValue) }
    }

    var lineNumbersInMain: Bool {
        get { bool("view.lineNumbersVisibleInMain", default: true) }
        set { set("view.lineNumbersVisibleInMain", b: newValue) }
    }

    var lineNumbersInFiltered: Bool {
        get { bool("view.lineNumbersVisibleInFiltered", default: true) }
        set { set("view.lineNumbersVisibleInFiltered", b: newValue) }
    }

    // MARK: - Search  (keys: regexpType.*, defaultView.*)

    /// 0 = Extended Regexp, 1 = Fixed Strings  (matches klogg's SearchRegexpType index)
    var mainRegexpType: Int {
        get { int("regexpType.main", default: 0) }
        set { set("regexpType.main", i: newValue) }
    }

    var searchIgnoreCase: Bool {
        get { bool("defaultView.searchIgnoreCase", default: false) }
        set { set("defaultView.searchIgnoreCase", b: newValue) }
    }

    var searchAutoRefresh: Bool {
        get { bool("defaultView.searchAutoRefresh", default: false) }
        set { set("defaultView.searchAutoRefresh", b: newValue) }
    }

    var autoRunSearch: Bool {
        get { bool("regexpType.autoRunSearch", default: false) }
        set { set("regexpType.autoRunSearch", b: newValue) }
    }

    var highlightSearchInMain: Bool {
        get { bool("regexpType.mainHighlight", default: true) }
        set { set("regexpType.mainHighlight", b: newValue) }
    }

    var quickfindIncremental: Bool {
        get { bool("quickfind.incremental", default: true) }
        set { set("quickfind.incremental", b: newValue) }
    }

    // MARK: - Behavior  (keys: session.*, perf.*)

    var loadLastSession: Bool {
        get { bool("session.loadLast", default: false) }
        set { set("session.loadLast", b: newValue) }
    }

    var followFileOnLoad: Bool {
        get { bool("session.followOnLoad", default: false) }
        set { set("session.followOnLoad", b: newValue) }
    }

    var nativeFileWatch: Bool {
        get { bool("perf.nativeFileWatch", default: true) }
        set { set("perf.nativeFileWatch", b: newValue) }
    }

    var pollingEnabled: Bool {
        get { bool("perf.pollingEnabled", default: false) }
        set { set("perf.pollingEnabled", b: newValue) }
    }

    var pollIntervalMs: Int {
        get { int("perf.pollIntervalMs", default: 500) }
        set { set("perf.pollIntervalMs", i: max(10, newValue)) }
    }

    var allowFollowOnScroll: Bool {
        get { bool("perf.allowFollowOnScroll", default: false) }
        set { set("perf.allowFollowOnScroll", b: newValue) }
    }

    // MARK: - Performance  (keys: perf.*)

    var useParallelSearch: Bool {
        get { bool("perf.useParallelSearch", default: true) }
        set { set("perf.useParallelSearch", b: newValue) }
    }

    var useSearchResultsCache: Bool {
        get { bool("perf.useSearchResultsCache", default: true) }
        set { set("perf.useSearchResultsCache", b: newValue) }
    }

    var searchResultsCacheLines: Int {
        get { int("perf.searchResultsCacheLines", default: 1_000_000) }
        set { set("perf.searchResultsCacheLines", i: max(100_000, newValue)) }
    }

    var indexReadBufferSizeMb: Int {
        get { int("perf.indexReadBufferSizeMb", default: 64) }
        set { set("perf.indexReadBufferSizeMb", i: max(1, min(1024, newValue))) }
    }

    // MARK: - Encoding  (key: defaultView.encodingMib)

    /// -1 = Auto-detect (klogg default). Positive values are QTextCodec MIB numbers.
    var defaultEncodingMib: Int {
        get { int("defaultView.encodingMib", default: -1) }
        set { set("defaultView.encodingMib", i: newValue) }
    }

    // MARK: - Internals

    private let prefix = "klogg."

    private func key(_ k: String) -> String { prefix + k }

    private func bool(_ k: String, default d: Bool) -> Bool {
        let full = key(k)
        guard UserDefaults.standard.object(forKey: full) != nil else { return d }
        return UserDefaults.standard.bool(forKey: full)
    }

    private func int(_ k: String, default d: Int) -> Int {
        let full = key(k)
        guard UserDefaults.standard.object(forKey: full) != nil else { return d }
        return UserDefaults.standard.integer(forKey: full)
    }

    private func str(_ k: String, default d: String) -> String {
        UserDefaults.standard.string(forKey: key(k)) ?? d
    }

    private func set(_ k: String, b: Bool)   { UserDefaults.standard.set(b, forKey: key(k)); notify() }
    private func set(_ k: String, i: Int)    { UserDefaults.standard.set(i, forKey: key(k)); notify() }
    private func set(_ k: String, s: String) { UserDefaults.standard.set(s, forKey: key(k)); notify() }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}
