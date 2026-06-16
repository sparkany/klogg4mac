//
//  LogScrollView.swift — Phase-1 hardened custom log view (the highest-risk component).
//
//  Architecture (Phase 1 goal from ROADMAP §4):
//    * Fixed row height from monospaced font metrics → document height = lineCount * rowHeight.
//      Layout is O(1) up front; scroll to any line is instant.
//    * Only the visible row range is pulled from the engine and drawn each frame
//      (viewport-driven): draw cost is O(visible rows), never O(file size).
//    * Line-number gutter is a floating NSView that stays in the clip view's
//      coordinate space — it never scrolls vertically but does scroll horizontally
//      with the clip view.
//    * Selection model (LogSelectionController) handles click, shift-click, drag,
//      Cmd+A (select all), and Cmd+C (copy to NSPasteboard).
//    * Horizontal scrolling for long lines.
//
//  Key invariants mirrored from klogg's abstractlogview:
//    1. Right-aligned line-number gutter with a thin separator.
//    2. Monospaced font; row height = ceil(ascender + |descender| + leading) + 2px.
//    3. Selected lines drawn with highlight background (NSColor.selectedTextBackgroundColor).
//    4. Cmd+A selects all, Cmd+C copies selection as newline-delimited text.
//    5. Tab expansion delegated to the engine (linesInRange:expandTabs:).
//    6. Horizontal scroll range computed from the longest visible line.
//

import AppKit
import KloggBridge

// MARK: - LogScrollView (public container)

/// Whether this scroll view displays raw log lines (from LogData) or the
/// filtered search-match lines (from LogFilteredData).
enum LogViewMode {
    case main       // reads engine.lines(in:expandTabs:) and engine.lineCount
    case filtered   // reads engine.filteredLines(in:expandTabs:) and engine.searchMatchCount
}

/// Callbacks the log view's right-click context menu invokes, mirroring the actions
/// in klogg's abstractlogview popup (replace/add/exclude search, scratchpad, save to
/// file). The owning CrawlerTab supplies these; nil entries simply omit the item.
/// `selectedText` is the current selection's text (first line, trimmed) and the
/// selection's source-line range is available via the view's selectedSourceLines.
struct LogViewContextActions {
    /// Replace the current search with the selected text (klogg "Replace search").
    var replaceSearch: ((_ text: String) -> Void)?
    /// OR the selection into the current search (klogg "Add to search").
    var addToSearch: ((_ text: String) -> Void)?
    /// Exclude the selection from search (klogg "Exclude from search").
    var excludeFromSearch: ((_ text: String) -> Void)?
    /// Send the selection to the scratchpad (append).
    var sendToScratchpad: ((_ text: String) -> Void)?
    /// Replace the scratchpad with the selection.
    var replaceScratchpad: ((_ text: String) -> Void)?
    /// Set the search-range START to the selected source line (klogg "Set search start").
    var setSearchStart: ((_ line: Int) -> Void)?
    /// Set the search-range END to the selected source line (klogg "Set search end").
    var setSearchEnd: ((_ line: Int) -> Void)?
    /// Clear the search-range limits (klogg "Clear search limits").
    var clearSearchLimits: (() -> Void)?
}

/// Drop-in replacement for NSScrollView that hosts the log document view,
/// the floating line-number gutter, and wires engine callbacks.
final class LogScrollView: NSScrollView {

    private let docView: LogDocumentView
    private let gutter: LogLineNumberGutter
    /// Guards the one-shot stub auto-load (shared across all instances of this class).
    private static var stubAutoLoadFired = false

    /// Called when the user clicks (selects) a row. Argument is the row index
    /// within this view's coordinate space (0-based match index for .filtered mode,
    /// 0-based source line for .main mode).
    var onLineSelected: ((Int) -> Void)? {
        didSet { docView.onLineSelected = onLineSelected }
    }

    /// Context-menu / mark actions, bubbled to the owning CrawlerTab so it can drive
    /// search, scratchpad, and marks. Mirrors klogg's abstractlogview popup menu.
    var contextActions: LogViewContextActions? {
        get { docView.contextActions }
        set { docView.contextActions = newValue }
    }

    /// The marks store backing this view's gutter mark indicators. Both the main and
    /// filtered views of a tab share one store (marks are by SOURCE line).
    var marksStore: MarksStore? {
        get { docView.marksStore }
        set { docView.marksStore = newValue; docView.needsDisplay = true }
    }

    /// Map a row in THIS view's coordinate space to the original source-line index.
    /// In .main mode the row IS the source line; in .filtered mode it's the match's
    /// source line. Used so marks (identified by source line) work in both views.
    func sourceLine(forRow row: Int) -> Int { docView.sourceLine(forRow: row) }

    /// Explicit source-line list driving the filtered view (klogg visibility modes).
    /// When non-nil the filtered view renders exactly these source lines (fetched via
    /// engine.lines), instead of the default match-index path. nil = pure Matches mode
    /// (the original fast path). Has no effect on a .main view.
    var filteredSourceLines: [Int]? {
        get { docView.filteredSourceLines }
        set { docView.filteredSourceLines = newValue }
    }

    /// Toggle marks on the current selection (the &Mark / Unmark action).
    func markSelectedLines() { docView.markSelectedLines() }

    /// 0-based source lines currently selected (for the mark/copy-with-numbers paths).
    var selectedSourceLines: [Int] { docView.selectedSourceLines }

    /// Repaint (e.g. after marks change elsewhere).
    func refresh() { docView.needsDisplay = true }

    /// Paint match/mark tick markers on this view's vertical scrollbar trough (klogg
    /// scrollbar overview). `total` is the file height the trough represents; each
    /// marker is a (source line, colour) pair. Pass an empty array to clear.
    func setScrollbarMarkers(_ markers: [MarkerScroller.Marker], total: Int) {
        markerScroller.totalLines = total
        markerScroller.markers = markers
    }

    /// Number of scrollbar markers currently set (headless assertions).
    var scrollbarMarkerCount: Int { markerScroller.markers.count }

    /// Titles of the current context menu's non-separator items (headless assertions).
    func contextMenuItemTitles() -> [String] {
        docView.buildContextMenu().items.filter { !$0.isSeparatorItem }.map { $0.title }
    }

    /// Run the copy-with-line-numbers action programmatically (headless tests).
    func copyWithLineNumbersForTest() { docView.copyWithLineNumbers(nil) }

    /// Drive mark navigation and return the resulting current line (headless tests).
    func jumpToMarkForTest(next: Bool) -> Int {
        docView.jumpToMarkForTest_(next: next)
        return docView.currentSelectedLine ?? -1
    }

    /// Custom vertical scroller that overlays match/mark tick markers (klogg overview).
    private let markerScroller = MarkerScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))

    init(engine: KloggEngine, mode: LogViewMode = .main) {
        docView = LogDocumentView(engine: engine, mode: mode)
        gutter  = LogLineNumberGutter(font: docView.logFont, rowHeight: docView.rowHeight)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller   = true
        hasHorizontalScroller = true
        // Install the marker-painting vertical scroller (klogg scrollbar overview).
        // Force the legacy (non-overlay) style so the trough — and thus the markers —
        // stay visible regardless of the user's "show scrollbars" system setting.
        scrollerStyle         = .legacy
        verticalScroller      = markerScroller
        borderType            = .noBorder
        documentView          = docView

        // The gutter is NOT added to the view tree. It is kept only as a width
        // calculator; the line numbers are painted by LogDocumentView itself,
        // pinned to the left edge of the viewport. (Adding a sibling view to the
        // NSClipView alongside the documentView stopped the documentView from
        // rendering at all — hiding every log line — so the gutter is drawn inline.)
        docView.gutterView = gutter

        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Auto-load stub content on first appearance for stub-mode testing.
    /// In real mode (engine wired) this is a no-op.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, KloggEngine.isStub else { return }
        // Only the first view to appear triggers the load; the delegate callback
        // (MainWindowController.kloggEngine:loadingFinished:) will call
        // mainView.reloadFromEngine() to refresh the display.
        guard !LogScrollView.stubAutoLoadFired else { return }
        LogScrollView.stubAutoLoadFired = true
        // Synthetic path: stub generates 1,000,000 lines for any non-file path.
        docView.engine.openFile(atPath: "stub://1M-lines")
    }

    /// Scroll to make `line` visible and select it.
    func scrollToLine(_ line: Int) {
        docView.selectAndScrollToLine(line)
    }

    /// Select `line` without scrolling (headless tests / programmatic selection).
    /// Syncs the view's line count from the engine first so the selection isn't
    /// rejected when the view hasn't been laid out yet (headless path).
    func selectLine(_ line: Int) {
        reloadFromEngine()
        docView.selectAndScrollToLine(line)
    }

    /// Clear the current selection and repaint (headless tests).
    func clearSelection() {
        docView.clearSelectionForTest()
    }

    /// 0-based index of the currently selected/anchored line, or nil if none.
    /// Used by QuickFind to start searching from the current position.
    var currentLine: Int? { docView.currentSelectedLine }

    /// Number of lines this view currently displays.
    var lineCount: Int { docView.currentLineCount }

    /// Exact pixel height of one row (derived from font metrics). Changes when the
    /// font-size preference changes — the headless harness asserts on this to prove a
    /// font change live-applies.
    var rowHeight: CGFloat { docView.rowHeight }

    /// Point size of the resolved log font (changes with the font-size preference).
    /// Exposed so the headless harness can prove a font zoom live-applies even when
    /// integer row-height quantization hides the change.
    var fontPointSize: CGFloat { docView.logFont.pointSize }

    /// Default base name used when saving the whole view to a file (klogg "Save to
    /// file"). Set by the owning tab to the source file's base name.
    var sourceName: String? {
        get { docView.docViewSourceName }
        set { docView.docViewSourceName = newValue }
    }

    /// Headless "Save to file": write the entire view to `url`. Returns true on success.
    func saveAllToFileForTest(to url: URL) -> Bool { docView.saveAllToFileForTest(to: url) }

    /// The effective line-number gutter width: the gutter's computed width when the
    /// line-number preference for this view's mode is ON, otherwise 0 (gutter hidden).
    /// Lets the harness assert the gutter shows/hides as the preference toggles.
    var gutterWidth: CGFloat { docView.effectiveGutterWidth }

    /// Text of the first currently-selected line (trimmed), or nil if nothing is
    /// selected. Used by the colour-label feature to label the selected token.
    var currentSelectionText: String? { docView.currentSelectionText }

    /// 0-based index of the first line visible in the viewport (for the overview's
    /// "you are here" indicator). 0 when there's no content.
    var firstVisibleLine: Int { docView.firstVisibleLine }

    /// Number of lines visible in the viewport (for the overview indicator).
    var visibleLineCount: Int { docView.visibleLineCount }

    /// Called after any scroll so the owner can update an overview viewport indicator.
    var onScroll: (() -> Void)?

    /// Whether wrap is currently enabled on this view (headless assertions).
    var isWrapEnabled: Bool { docView.wrapEnabled }

    /// Number of visual rows the logical line `row` occupies at the current wrap width
    /// (1 when wrap is off, or for a short line). Lets headless tests prove a long line
    /// actually wraps to multiple rows. Returns 0 if `row` is out of range.
    func visualRowCount(forLine row: Int) -> Int {
        docView.visualRowCount(forLine: row)
    }

    // MARK: - Search / QuickFind highlight (Wave 6)

    /// Highlight the active SearchBarView pattern in this view (main-view search wash).
    func setSearchHighlight(pattern: String?, caseInsensitive: Bool, isRegex: Bool) {
        docView.setSearchHighlight(pattern: pattern, caseInsensitive: caseInsensitive, isRegex: isRegex)
        docView.needsDisplay = true
    }

    /// Highlight the active QuickFind needle in this view.
    func setQuickFindHighlight(pattern: String?, caseInsensitive: Bool, isRegex: Bool) {
        docView.setQuickFindHighlight(pattern: pattern, caseInsensitive: caseInsensitive, isRegex: isRegex)
        docView.needsDisplay = true
    }

    /// Set the active search-range limits (klogg AbstractLogView::setSearchLimits). Lines
    /// outside [start, end) are dimmed to show they're excluded from the search. Pass
    /// start=0, end=Int.max to clear (whole file searched, nothing dimmed).
    func setSearchLimitLines(start: Int, end: Int) {
        docView.setSearchLimitLines(start: start, end: end)
        docView.needsDisplay = true
    }

    /// Called after a file loads or a search completes.
    /// Pass `lineCount` explicitly so the filtered view can pass match count.
    func reloadFromEngine(lineCount: Int? = nil) {
        let count = lineCount ?? docView.effectiveLineCount()
        gutter.updateWidth(for: count)        // recompute gutter width for digit count
        docView.refreshSizing(lineCount: count)
        docView.needsDisplay = true
    }

    // MARK: - Live preference / highlighter updates

    /// Re-resolve the log font from preferences; if it changed, sync the gutter,
    /// resize rows, and repaint. Safe to call when nothing changed (no-op redraw).
    func applyFontPreference() {
        if docView.reloadFontFromPreferences() {
            gutter.updateFont(docView.logFont, rowHeight: docView.rowHeight)
            gutter.updateWidth(for: docView.currentLineCount)
            docView.refreshSizing(lineCount: docView.currentLineCount)
        }
        docView.needsDisplay = true
    }

    /// Rebuild compiled highlighter rules and repaint.
    func applyHighlighters() {
        docView.reloadHighlighters()
        docView.needsDisplay = true
    }

    /// Repaint to pick up view-preference changes (line-number visibility,
    /// hideAnsiColors) that don't change row metrics.
    func applyViewPreferences() {
        gutter.updateWidth(for: docView.currentLineCount)
        applyTextWrapPreference()
        docView.needsDisplay = true
    }

    /// Sync the text-wrap preference: hide the horizontal scroller when wrapping (long
    /// lines soft-wrap to the viewport instead of scrolling), show it otherwise. The
    /// document view re-lays out and repaints. Safe to call repeatedly.
    func applyTextWrapPreference() {
        let wrap = AppPreferences.shared.useTextWrap
        hasHorizontalScroller = !wrap
        docView.setWrapEnabled(wrap, viewportWidth: contentView.bounds.width)
    }

    // MARK: - Scroll tracking

    /// On any scroll (including horizontal), repaint so the inline gutter — which is
    /// pinned to the viewport's left edge — follows the scroll position.
    @objc private func boundsChanged() {
        docView.needsDisplay = true
        onScroll?()
    }
}

// MARK: - LogDocumentView (private; the actual self-drawn view)

/// Self-drawn document view that renders all log lines via viewport culling.
/// Owns the selection model and handles keyboard + mouse events.
final class LogDocumentView: NSView {

    // MARK: Internal references

    let engine: KloggEngine
    let mode: LogViewMode
    /// Set by LogScrollView after construction.
    weak var gutterView: LogLineNumberGutter?

    // MARK: Font / metrics

    /// Resolved from AppPreferences (fontFamily/fontSize); falls back to the
    /// system monospaced font. Recomputed when the font preference changes.
    private(set) var logFont: NSFont = LogDocumentView.resolveFont()
    /// Exact pixel height of one row, derived from font metrics.
    private(set) var rowHeight: CGFloat = 0
    /// Advance width of a single character (monospaced — all chars are the same).
    private var charWidth: CGFloat = 0

    // MARK: Text wrap (Wave 8)

    /// When true, long logical lines soft-wrap to the viewport width across multiple
    /// visual rows instead of scrolling horizontally. The non-wrap path is unchanged.
    ///
    /// Layout note (documented limitation): in wrap mode the document height stays the
    /// estimate `lineCount × rowHeight` (so the vertical scrollbar is approximate — a
    /// long wrapped line doesn't expand it). Rendering, however, is exact and O(visible):
    /// draw() picks the first visible LOGICAL line from the scroll offset and then stacks
    /// each subsequent logical line's wrapped sub-rows sequentially down the viewport, so
    /// no text is clipped or overlapped. Scrolling is therefore logical-line granular.
    private(set) var wrapEnabled = AppPreferences.shared.useTextWrap

    /// Enable/disable wrap and relayout. `viewportWidth` is advisory; draw() reads the
    /// live clip-view width so resizes reflow without extra plumbing.
    func setWrapEnabled(_ on: Bool, viewportWidth: CGFloat) {
        wrapEnabled = on
        refreshSizing(lineCount: currentLineCount)
        needsDisplay = true
    }

    /// Number of visual rows logical line `row` occupies at the current wrap width.
    /// 1 when wrap is off or the line fits; >1 when it wraps. 0 if out of range.
    func visualRowCount(forLine row: Int) -> Int {
        guard row >= 0, row < currentLineCount else { return 0 }
        guard wrapEnabled, rowHeight > 0 else { return 1 }
        let r = NSRange(location: row, length: 1)
        let line: String
        switch mode {
        case .main:     line = engine.lines(in: r, expandTabs: true).first ?? ""
        case .filtered: line = engine.filteredLines(in: r, expandTabs: true).first ?? ""
        }
        let gutterWidth = lineNumbersEnabled ? (gutterView?.gutterWidth ?? 0) : 0
        let textX = effectiveMarkZoneWidth + gutterWidth + textLeftPadding
        let viewportWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let wrapWidth = max(20, viewportWidth - textX - 6)
        let attr = NSAttributedString(string: line, attributes: [
            .font: logFont, .paragraphStyle: LogDocumentView.wrapParagraph,
        ])
        let bounding = attr.boundingRect(
            with: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(1, Int(ceil(bounding.height / rowHeight)))
    }

    // MARK: Highlighting / preferences

    /// Compiled highlighter rules; rebuilt when HighlighterStore changes.
    private let highlighter = LogHighlighter()

    /// Transient search-match highlight: the active SearchBarView pattern (Wave 6),
    /// painted as a distinct background layer ON TOP of the user highlighter spans so
    /// search hits stand out in the MAIN view (klogg highlights search matches there).
    /// nil when no search is active or the "highlight search in main" pref is off.
    private var searchMatchRegex: NSRegularExpression?
    /// Background colour for a search-match span (klogg uses a yellow-ish match wash).
    private let searchMatchBack = NSColor.systemYellow.withAlphaComponent(0.45)

    /// Transient QuickFind highlight: the current QuickFind needle (Wave 6), painted
    /// like a search match but in a distinct colour so the in-place find is visible.
    private var quickFindRegex: NSRegularExpression?
    private let quickFindBack = NSColor.systemOrange.withAlphaComponent(0.55)

    /// Set/clear the search-match highlight pattern. Honours the
    /// `highlightSearchInMain` preference; clears the layer when the pref is off or
    /// the pattern is empty. Mirrors klogg's search-hit colouring in the main view.
    func setSearchHighlight(pattern: String?, caseInsensitive: Bool, isRegex: Bool) {
        guard let pattern = pattern, !pattern.isEmpty,
              AppPreferences.shared.highlightSearchInMain else {
            searchMatchRegex = nil
            return
        }
        searchMatchRegex = LogDocumentView.compile(pattern: pattern,
                                                   caseInsensitive: caseInsensitive,
                                                   isRegex: isRegex)
    }

    /// Active search-range limits (klogg searchStart_ / searchEnd_). Lines with index
    /// < start or >= end are dimmed. Defaults span the whole file (no dimming).
    private(set) var searchLimitStart = 0
    private(set) var searchLimitEnd = Int.max
    /// Wash painted over lines outside the active search range (klogg dims them).
    private let searchLimitDim = NSColor.gray.withAlphaComponent(0.20)

    /// Set the search-range limits and repaint. start=0,end=Int.max ⇒ no dimming.
    func setSearchLimitLines(start: Int, end: Int) {
        searchLimitStart = max(0, start)
        searchLimitEnd = end
    }

    /// True when an explicit (non-whole-file) search range is active.
    var hasSearchLimit: Bool { searchLimitStart > 0 || searchLimitEnd != Int.max }

    /// Whether source line `line` is OUTSIDE the active search range (so it's dimmed).
    func isLineOutsideSearchLimit(_ line: Int) -> Bool {
        guard hasSearchLimit else { return false }
        return line < searchLimitStart || line >= searchLimitEnd
    }

    /// Set/clear the QuickFind highlight pattern (independent of search highlight).
    func setQuickFindHighlight(pattern: String?, caseInsensitive: Bool, isRegex: Bool) {
        guard let pattern = pattern, !pattern.isEmpty else {
            quickFindRegex = nil
            return
        }
        quickFindRegex = LogDocumentView.compile(pattern: pattern,
                                                 caseInsensitive: caseInsensitive,
                                                 isRegex: isRegex)
    }

    /// Compile a search/quickfind needle into an NSRegularExpression (literal
    /// substrings are escaped when isRegex is false). Returns nil if it won't compile.
    static func compile(pattern: String, caseInsensitive: Bool, isRegex: Bool) -> NSRegularExpression? {
        let text = isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: text, options: opts)
    }

    /// Resolve the log font from preferences, falling back to system monospaced.
    static func resolveFont() -> NSFont {
        let prefs = AppPreferences.shared
        let size = CGFloat(prefs.fontSize)
        let family = prefs.fontFamily
        if !family.isEmpty,
           let f = NSFont(name: family, size: size) {
            return f
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Recompute row height + char advance from the current logFont.
    private func recomputeMetrics() {
        let ascender  = logFont.ascender
        let descender = abs(logFont.descender)
        let leading   = logFont.leading
        rowHeight = ceil(ascender + descender + leading) + 2
        charWidth = logFont.advancement(forGlyph: logFont.glyph(withName: "M")).width
    }

    /// Whether the line-number gutter should be shown for this view's mode,
    /// per AppPreferences. When false the gutter width collapses to 0.
    private var lineNumbersEnabled: Bool {
        switch mode {
        case .main:     return AppPreferences.shared.lineNumbersInMain
        case .filtered: return AppPreferences.shared.lineNumbersInFiltered
        }
    }

    /// The gutter width as draw() uses it: the computed width when line numbers are on
    /// for this mode, else 0. Exposed for headless assertions on gutter visibility.
    var effectiveGutterWidth: CGFloat {
        lineNumbersEnabled ? (gutterView?.gutterWidth ?? 0) : 0
    }

    // MARK: Layout constants (matching klogg's abstractlogview feel)

    private let textLeftPadding: CGFloat = 6   // between gutter separator and text
    private let lineCountEstimatedMaxWidth: CGFloat = 4000  // initial doc width

    // MARK: State

    private(set) var currentLineCount: Int = 0
    /// Cache of lines visible in the last draw pass (for Cmd+C without re-fetching).
    private var visibleLineCache: [Int: String] = [:]

    // MARK: Selection

    private let selection = LogSelectionController()
    /// Set when user is dragging to extend the selection.
    private var isDragging: Bool = false

    /// Fires when the user clicks a row. Set by LogScrollView.
    var onLineSelected: ((Int) -> Void)?

    /// Context-menu action callbacks (search / scratchpad). Set by LogScrollView.
    var contextActions: LogViewContextActions?

    /// Marks store backing the gutter mark indicators. Set by LogScrollView.
    var marksStore: MarksStore?

    /// Explicit source-line list for the filtered view (klogg visibility modes).
    /// When non-nil (and mode == .filtered) the view shows exactly these source lines,
    /// fetched by absolute source index via engine.lines, so the lower pane can mix
    /// matches + marks ("Marks and matches") or show marked lines only ("Marks").
    /// nil = the original Matches-only fast path (rows are match indices).
    var filteredSourceLines: [Int]?

    /// True when this filtered view is rendering an explicit source-line list.
    private var usesSourceList: Bool { mode == .filtered && filteredSourceLines != nil }

    /// Width of the mark-indicator zone painted at the LEFT edge (before the line-number
    /// gutter) when a marks store is present. Mirrors klogg's bullet/arrow margin
    /// (abstractlogview), which is always shown — even when line numbers are OFF — so a
    /// marked line is visible without the gutter.
    private let markZoneWidth: CGFloat = 11

    /// The effective mark-zone width: markZoneWidth when a marks store is attached,
    /// else 0. This zone sits to the LEFT of the line-number gutter and is independent
    /// of the line-number preference, so marks always have a place to draw.
    private var effectiveMarkZoneWidth: CGFloat { marksStore != nil ? markZoneWidth : 0 }

    /// Source (original file) line for a row in this view's coordinate space.
    /// .main: identity. .filtered: the match's source line (falls back to row).
    func sourceLine(forRow row: Int) -> Int {
        switch mode {
        case .main:
            return row
        case .filtered:
            // Explicit source-line list (visibility modes) takes precedence.
            if let list = filteredSourceLines {
                guard row >= 0, row < list.count else { return row }
                return list[row]
            }
            let src = engine.searchMatchLine(at: UInt(row))
            return src == UInt.max ? row : Int(src)
        }
    }

    /// Fetch the text of the rows in [first, last] for this view's mode, honouring an
    /// explicit filtered source-line list (visibility modes) when present.
    private func fetchRows(first: Int, last: Int) -> [String] {
        guard first <= last else { return [] }
        switch mode {
        case .main:
            return engine.lines(in: NSRange(location: first, length: last - first + 1),
                                expandTabs: true)
        case .filtered:
            if let list = filteredSourceLines {
                // Source lines may be non-contiguous; fetch each by absolute index.
                // Guard against stale source indices (a re-index can shrink the file
                // while a marks-derived list still references higher lines).
                let total = Int(engine.lineCount())
                var out: [String] = []
                out.reserveCapacity(last - first + 1)
                for row in first ... last {
                    guard row >= 0, row < list.count else { out.append(""); continue }
                    let s = list[row]
                    guard s >= 0, s < total else { out.append(""); continue }
                    let one = engine.lines(in: NSRange(location: s, length: 1), expandTabs: true)
                    out.append(one.first ?? "")
                }
                return out
            }
            return engine.filteredLines(in: NSRange(location: first, length: last - first + 1),
                                        expandTabs: true)
        }
    }

    /// 0-based SOURCE lines covered by the current selection.
    var selectedSourceLines: [Int] {
        guard let range = selection.state.normalizedRange else { return [] }
        let lo = max(0, range.lowerBound)
        let hi = min(currentLineCount - 1, range.upperBound)
        guard lo <= hi else { return [] }
        return (lo...hi).map { sourceLine(forRow: $0) }
    }

    /// Toggle marks on the selected lines (klogg &Mark / Unmark).
    func markSelectedLines() {
        guard let store = marksStore else { return }
        let lines = selectedSourceLines
        guard !lines.isEmpty else { return }
        store.toggle(lines: lines)
        needsDisplay = true
    }

    /// 0-based extent (caret) of the current selection; nil when nothing selected.
    /// QuickFind reads this to start its incremental find from the current position.
    var currentSelectedLine: Int? { selection.state.extentLine }

    /// First line visible in the enclosing scroll view's viewport (0 if no content).
    var firstVisibleLine: Int {
        guard rowHeight > 0 else { return 0 }
        let y = enclosingScrollView?.contentView.bounds.origin.y ?? 0
        return max(0, min(currentLineCount, Int(floor(y / rowHeight))))
    }

    /// Number of lines that fit in the viewport.
    var visibleLineCount: Int {
        guard rowHeight > 0 else { return 0 }
        let h = enclosingScrollView?.contentView.bounds.height ?? bounds.height
        return max(0, Int(ceil(h / rowHeight)))
    }

    /// Trimmed text of the first selected line, fetched from the engine. nil when no
    /// selection. Drives the colour-label feature (label the selected token).
    var currentSelectionText: String? {
        guard let range = selection.state.normalizedRange else { return nil }
        let lo = max(0, min(range.lowerBound, currentLineCount - 1))
        // Prefer the draw cache; fall back to a single-line engine fetch.
        let raw = visibleLineCache[lo] ?? fetchRows(first: lo, last: lo).first ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Init

    init(engine: KloggEngine, mode: LogViewMode = .main) {
        self.engine = engine
        self.mode   = mode
        super.init(frame: .zero)
        // Use typographic line height: ascender + |descender| + leading, rounded up + 2px.
        recomputeMetrics()
    }

    /// Re-resolve the font from preferences and recompute metrics. Returns true
    /// when the font (and hence row height) changed so the owner can relayout.
    @discardableResult
    func reloadFontFromPreferences() -> Bool {
        let newFont = LogDocumentView.resolveFont()
        guard newFont != logFont else { return false }
        logFont = newFont
        recomputeMetrics()
        return true
    }

    /// Rebuild the compiled highlighter rules (HighlighterStore changed).
    func reloadHighlighters() {
        highlighter.rebuild()
    }

    /// Returns the current line count for this view's mode.
    func effectiveLineCount() -> Int {
        switch mode {
        case .main:
            return Int(engine.lineCount())
        case .filtered:
            if let list = filteredSourceLines { return list.count }
            return Int(engine.searchMatchCount())
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }    // y=0 at top, like a text editor
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Sizing

    func refreshSizing(lineCount: Int) {
        currentLineCount = lineCount
        let height = CGFloat(lineCount) * rowHeight
        // Width: in wrap mode the document is exactly the viewport width (no horizontal
        // scroll); otherwise use a generous default (we defer the expensive full-scan).
        let viewportWidth = enclosingScrollView?.contentView.bounds.width
            ?? enclosingScrollView?.bounds.width ?? 800
        let docWidth = wrapEnabled
            ? max(1, viewportWidth)
            : max(lineCountEstimatedMaxWidth, viewportWidth)
        setFrameSize(NSSize(width: docWidth, height: max(height, 1)))
    }

    override func invalidateIntrinsicContentSize() {
        refreshSizing(lineCount: currentLineCount)
        super.invalidateIntrinsicContentSize()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        guard currentLineCount > 0, rowHeight > 0 else { return }

        if wrapEnabled {
            drawWrapped(dirtyRect: dirtyRect)
            return
        }

        // Compute which rows intersect dirtyRect.
        let firstRow = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let lastRow  = min(currentLineCount - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard firstRow <= lastRow else { return }

        // Fetch visible lines from engine (O(visible rows)).
        let fetched = fetchRows(first: firstRow, last: lastRow)

        // Left margins: [mark zone][line-number gutter][text]. The mark zone is shown
        // whenever marks are enabled (independent of line numbers); the gutter is
        // preference-driven and collapses to 0 when line numbers are off.
        let markZone    = effectiveMarkZoneWidth
        let gutterWidth = lineNumbersEnabled ? (gutterView?.gutterWidth ?? 0) : 0
        let textX       = markZone + gutterWidth + textLeftPadding

        let hideAnsi = AppPreferences.shared.hideAnsiColors

        // Base text attributes (used for non-highlighted lines + as the highlight base).
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: logFont,
            .foregroundColor: NSColor.textColor,
        ]
        let selectedAttrs: [NSAttributedString.Key: Any] = [
            .font: logFont,
            .foregroundColor: NSColor.selectedTextColor,
        ]

        // 1) Row backgrounds (selection) + text (with highlighter colouring).
        for (offset, rawText) in fetched.enumerated() {
            let row = firstRow + offset
            let y   = CGFloat(row) * rowHeight
            let lineText = hideAnsi ? LogDocumentView.stripAnsi(rawText) : rawText
            let isSelected = selection.state.contains(line: row)

            if isSelected {
                NSColor.selectedTextBackgroundColor.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
            }

            // Search-range dimming (klogg searchStart_/searchEnd_): in the main view, a
            // line outside the active range is washed grey to show it won't be searched.
            if mode == .main && isLineOutsideSearchLimit(row) {
                searchLimitDim.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
            }

            // Search-match + QuickFind washes: painted as translucent backgrounds
            // BEFORE the text so the glyphs stay legible on top. Each char-range is
            // mapped to an x-band using the monospaced char advance.
            if searchMatchRegex != nil || quickFindRegex != nil {
                let ns = lineText as NSString
                let full = NSRange(location: 0, length: ns.length)
                if let re = searchMatchRegex {
                    paintMatchWash(re, in: lineText, full: full, colour: searchMatchBack,
                                   textX: textX, y: y)
                }
                if let re = quickFindRegex {
                    paintMatchWash(re, in: lineText, full: full, colour: quickFindBack,
                                   textX: textX, y: y)
                }
            }

            let hl = highlighter.hasRules ? highlighter.highlight(line: lineText) : .none

            if hl.isEmpty {
                // Fast path: plain line, no highlighter spans.
                (lineText as NSString).draw(at: NSPoint(x: textX, y: y),
                                            withAttributes: isSelected ? selectedAttrs : normalAttrs)
            } else {
                drawHighlightedLine(lineText, highlight: hl, at: NSPoint(x: textX, y: y),
                                    baseAttrs: isSelected ? selectedAttrs : normalAttrs,
                                    isSelected: isSelected)
            }

            // Cache for fast copy access.
            visibleLineCache[row] = lineText
        }

        // 2) Mark zone + line-number gutter, painted last so they overlay the text and
        //    stay pinned to the viewport's left edge as the content scrolls horizontally.
        if markZone > 0 || gutterWidth > 0 {
            drawGutter(dirtyRect: dirtyRect, firstRow: firstRow, lastRow: lastRow,
                       markZone: markZone, gutterWidth: gutterWidth)
        }
    }

    // MARK: - Wrapped drawing (Wave 8)

    /// Wrapping paragraph style: wrap on word boundaries, falling back to char wrapping
    /// for long unbroken tokens so a single huge token still fits the viewport.
    private static let wrapParagraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byCharWrapping
        return p
    }()

    /// Render the visible logical lines, soft-wrapped to the viewport width. Starts at
    /// the first logical line implied by the scroll offset and stacks each subsequent
    /// line's wrapped height down the viewport until past dirtyRect. O(visible lines).
    private func drawWrapped(dirtyRect: NSRect) {
        let markZone    = effectiveMarkZoneWidth
        let gutterWidth = lineNumbersEnabled ? (gutterView?.gutterWidth ?? 0) : 0
        let textX       = markZone + gutterWidth + textLeftPadding
        let scrollX     = enclosingScrollView?.contentView.bounds.origin.x ?? 0
        // Text wraps to the space between the gutter and the right edge of the viewport.
        let viewportWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let wrapWidth = max(20, viewportWidth - textX - 6)
        let hideAnsi  = AppPreferences.shared.hideAnsiColors

        // Anchor: the first logical line to draw, from the scroll offset (estimate model).
        let anchorRow = max(0, min(currentLineCount - 1, Int(floor(dirtyRect.minY / rowHeight))))

        // Track each drawn line's [y, height] so the gutter can place numbers on the
        // first visual row of each logical line (klogg-style).
        var rowYs: [(row: Int, y: CGFloat, height: CGFloat)] = []

        var y = CGFloat(anchorRow) * rowHeight
        var row = anchorRow
        let stopY = dirtyRect.maxY
        // Fetch in modest batches to stay O(visible) without one call per line.
        let batch = 64
        while row < currentLineCount && y < stopY {
            let end = min(currentLineCount - 1, row + batch - 1)
            let fetched = fetchRows(first: row, last: end)
            for raw in fetched {
                guard y < stopY else { break }
                let lineText = hideAnsi ? LogDocumentView.stripAnsi(raw) : raw
                let h = drawWrappedLine(lineText, row: row, atY: y,
                                        textX: textX, wrapWidth: wrapWidth)
                rowYs.append((row, y, h))
                visibleLineCache[row] = lineText
                y += h
                row += 1
            }
        }

        // Mark zone + gutter band + per-line numbers on the first visual row of each
        // logical line.
        let totalMargin = markZone + gutterWidth
        if totalMargin > 0 {
            (NSColor(named: NSColor.Name("gutterBackground")) ?? NSColor.controlBackgroundColor).setFill()
            NSRect(x: scrollX, y: dirtyRect.minY, width: totalMargin, height: dirtyRect.height).fill()
            NSColor.separatorColor.setFill()
            NSRect(x: scrollX + totalMargin - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: logFont, .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let innerPad: CGFloat = 6
            for entry in rowYs {
                if gutterWidth > 0 {
                    let displayNum = sourceLine(forRow: entry.row) + 1
                    let label = "\(displayNum)" as NSString
                    let size  = label.size(withAttributes: attrs)
                    let lx = scrollX + markZone + gutterWidth - innerPad - size.width
                    let ly = entry.y + (rowHeight - size.height) / 2
                    label.draw(at: NSPoint(x: lx, y: ly), withAttributes: attrs)
                }
                if markZone > 0, let store = marksStore,
                   store.isMarked(sourceLine(forRow: entry.row)) {
                    drawMarkArrow(atX: scrollX, rowTop: entry.y)
                }
            }
        }
    }

    /// Draw one logical line wrapped to `wrapWidth`, returning the height it occupied
    /// (a multiple of rowHeight, at least one row). Applies selection background,
    /// search/quickfind washes, and highlighter colours via attribute runs so wrapping
    /// is handled natively by AppKit.
    private func drawWrappedLine(_ text: String, row: Int, atY y: CGFloat,
                                 textX: CGFloat, wrapWidth: CGFloat) -> CGFloat {
        let isSelected = selection.state.contains(line: row)
        let fore = isSelected ? NSColor.selectedTextColor : NSColor.textColor
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: logFont,
            .foregroundColor: fore,
            .paragraphStyle: LogDocumentView.wrapParagraph,
        ])
        let full = NSRange(location: 0, length: (text as NSString).length)

        // Highlighter colours (foreground + background spans).
        if highlighter.hasRules {
            let hl = highlighter.highlight(line: text)
            for span in hl.spans {
                let r = NSIntersectionRange(span.range, full)
                guard r.length > 0 else { continue }
                attr.addAttribute(.foregroundColor, value: span.fore, range: r)
                attr.addAttribute(.backgroundColor, value: span.back, range: r)
            }
        }
        // Search-match + QuickFind washes as background runs (legible: text on top).
        for (re, colour) in [(searchMatchRegex, searchMatchBack), (quickFindRegex, quickFindBack)] {
            guard let re = re else { continue }
            for m in re.matches(in: text, options: [], range: full) where m.range.length > 0 {
                attr.addAttribute(.backgroundColor, value: colour, range: m.range)
            }
        }

        // Measure the wrapped height for this width.
        let bounding = attr.boundingRect(
            with: NSSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let rows = max(1, Int(ceil(bounding.height / rowHeight)))
        let height = CGFloat(rows) * rowHeight

        // Selection background spans the full logical-line height across the viewport.
        if isSelected {
            NSColor.selectedTextBackgroundColor.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: height).fill()
        }

        attr.draw(with: NSRect(x: textX, y: y, width: wrapWidth, height: height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        return height
    }

    /// Paint a translucent wash behind every match of `re` on this line. Match
    /// char-offsets are converted to x-bands using the monospaced char advance,
    /// matching how text is laid out (each glyph occupies exactly `charWidth`).
    private func paintMatchWash(_ re: NSRegularExpression, in line: String,
                                full: NSRange, colour: NSColor,
                                textX: CGFloat, y: CGFloat) {
        let matches = re.matches(in: line, options: [], range: full)
        guard !matches.isEmpty, charWidth > 0 else { return }
        colour.setFill()
        for m in matches where m.range.length > 0 {
            let x = textX + CGFloat(m.range.location) * charWidth
            let w = CGFloat(m.range.length) * charWidth
            NSRect(x: x, y: y, width: w, height: rowHeight).fill()
        }
    }

    /// Draw one line with per-range highlighter colours via an NSAttributedString.
    /// Selection (when present) keeps a visible background by layering the
    /// selectedTextBackgroundColor under the highlight back-colours.
    private func drawHighlightedLine(_ text: String, highlight: LineHighlight,
                                     at point: NSPoint,
                                     baseAttrs: [NSAttributedString.Key: Any],
                                     isSelected: Bool) {
        let attr = NSMutableAttributedString(string: text, attributes: baseAttrs)
        let full = NSRange(location: 0, length: (text as NSString).length)
        for span in highlight.spans {
            // Clamp the span to the line in case the engine expanded tabs and
            // shifted offsets (defensive — ranges come from this same string).
            let r = NSIntersectionRange(span.range, full)
            guard r.length > 0 else { continue }
            attr.addAttribute(.foregroundColor, value: span.fore, range: r)
            attr.addAttribute(.backgroundColor, value: span.back, range: r)
        }
        attr.draw(at: point)
    }

    /// Strip ANSI/VT100 escape sequences (CSI ... final-byte) so coloured logs
    /// render as plain text when AppPreferences.hideAnsiColors is on.
    static func stripAnsi(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression)
    }

    /// Paint the left margins — [mark zone][line-number gutter] — at the left edge of
    /// the visible viewport. Drawn in document coordinates but offset by the clip view's
    /// horizontal scroll so they appear frozen at the left (klogg abstractlogview margin).
    /// `markZone` is the dedicated bullet column (shown even when line numbers are off);
    /// `gutterWidth` is the line-number band (0 when line numbers are off).
    private func drawGutter(dirtyRect: NSRect, firstRow: Int, lastRow: Int,
                            markZone: CGFloat, gutterWidth: CGFloat) {
        let scrollX = enclosingScrollView?.contentView.bounds.origin.x ?? 0
        let totalWidth = markZone + gutterWidth
        let band = NSRect(x: scrollX, y: dirtyRect.minY,
                          width: totalWidth, height: dirtyRect.height)

        (NSColor(named: NSColor.Name("gutterBackground")) ?? NSColor.controlBackgroundColor).setFill()
        band.fill()

        // Separator rule on the right edge of the whole margin.
        NSColor.separatorColor.setFill()
        NSRect(x: scrollX + totalWidth - 1, y: dirtyRect.minY,
               width: 1, height: dirtyRect.height).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: logFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let innerPad: CGFloat = 6
        for row in firstRow ... lastRow {
            // Line numbers right-align within the gutter band (to the right of the
            // mark zone), only when the gutter is shown.
            if gutterWidth > 0 {
                let displayNum = sourceLine(forRow: row) + 1
                let label = "\(displayNum)" as NSString
                let size  = label.size(withAttributes: attrs)
                let x = scrollX + markZone + gutterWidth - innerPad - size.width
                let y = CGFloat(row) * rowHeight + (rowHeight - size.height) / 2
                label.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            }

            // Mark indicator (klogg's bullet/arrow): a filled arrow in the mark zone at
            // the very left, drawn whenever the line is marked — independent of the
            // line-number gutter.
            if markZone > 0, let store = marksStore,
               store.isMarked(sourceLine(forRow: row)) {
                drawMarkArrow(atX: scrollX, rowTop: CGFloat(row) * rowHeight)
            }
        }
    }

    /// Draw a small filled rightward arrow (klogg's mark glyph) in the mark zone.
    private func drawMarkArrow(atX x: CGFloat, rowTop: CGFloat) {
        let midY = rowTop + rowHeight / 2
        let zoneW = markZoneWidth
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + 2, y: midY - 3))
        path.line(to: NSPoint(x: x + zoneW / 2, y: midY - 3))
        path.line(to: NSPoint(x: x + zoneW / 2, y: midY - 5))
        path.line(to: NSPoint(x: x + zoneW - 1, y: midY))
        path.line(to: NSPoint(x: x + zoneW / 2, y: midY + 5))
        path.line(to: NSPoint(x: x + zoneW / 2, y: midY + 3))
        path.line(to: NSPoint(x: x + 2, y: midY + 3))
        path.close()
        NSColor.systemBlue.setFill()
        path.fill()
    }

    // MARK: - Hit testing (coordinate → line number)

    /// Convert a point in the view's coordinate space to a (clamped) line index.
    private func lineIndex(for point: NSPoint) -> Int {
        let raw = Int(floor(point.y / rowHeight))
        return max(0, min(currentLineCount - 1, raw))
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let line  = lineIndex(for: point)

        // Click in the left mark zone toggles a mark on that line (klogg: clicking the
        // left bullet margin marks the line). The mark zone is the leftmost margin,
        // frozen at the viewport's left edge, and is present whenever marks are enabled
        // (independent of the line-number gutter).
        if let store = marksStore {
            let scrollX = enclosingScrollView?.contentView.bounds.origin.x ?? 0
            if point.x >= scrollX && point.x < scrollX + effectiveMarkZoneWidth {
                store.toggle(lines: [sourceLine(forRow: line)])
                needsDisplay = true
                return
            }
        }

        if event.modifierFlags.contains(.shift) {
            selection.extendTo(line: line)
        } else {
            selection.setAnchor(line: line)
        }
        isDragging = true
        needsDisplay = true
        // Notify owner so filtered-view clicks can jump the main view.
        onLineSelected?(line)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let line  = lineIndex(for: point)
        selection.extendTo(line: line)
        needsDisplay = true
        // Auto-scroll when dragging near viewport edges.
        if let sv = enclosingScrollView {
            let visibleRect = sv.documentVisibleRect
            let autoscrollMargin: CGFloat = rowHeight * 2
            if point.y < visibleRect.minY + autoscrollMargin {
                scroll(NSPoint(x: visibleRect.minX,
                               y: max(0, visibleRect.minY - rowHeight)))
            } else if point.y > visibleRect.maxY - autoscrollMargin {
                let maxY = CGFloat(currentLineCount) * rowHeight
                scroll(NSPoint(x: visibleRect.minX,
                               y: min(maxY - visibleRect.height,
                                      visibleRect.minY + rowHeight)))
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    // MARK: - Keyboard events

    /// Ctrl+wheel zooms the log font, mirroring klogg's AbstractLogView::wheelEvent
    /// (abstractlogview.cpp:939 → changeFontSize). All other wheel events scroll as usual.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            let dy = event.scrollingDeltaY
            if dy != 0 {
                AppPreferences.shared.changeFontSize(increase: dy > 0)
            }
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Cmd+'+'/'-'/'0' zoom the log font (macOS convention; klogg uses Ctrl+wheel).
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "a": selectAll(self)
            case "c": copy(self)
            case "+", "=": AppPreferences.shared.changeFontSize(increase: true)
            case "-", "_": AppPreferences.shared.changeFontSize(increase: false)
            case "0": AppPreferences.shared.fontSize = 12
            default:  super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 125: // Down arrow
            if let ext = selection.state.extentLine {
                let next = min(currentLineCount - 1, ext + 1)
                selection.setAnchor(line: next)
                scrollLineToVisible(next)
                needsDisplay = true
            }
        case 126: // Up arrow
            if let ext = selection.state.extentLine {
                let prev = max(0, ext - 1)
                selection.setAnchor(line: prev)
                scrollLineToVisible(prev)
                needsDisplay = true
            }
        case 36, 76: // Return / Enter — keep selection, do nothing extra
            break
        default:
            // klogg log-view mark shortcuts: 'm' mark, ']' next mark, '[' prev mark.
            switch event.charactersIgnoringModifiers {
            case "m":
                markSelectedLines()
            case "]":
                jumpToMark(next: true)
            case "[":
                jumpToMark(next: false)
            default:
                super.keyDown(with: event)
            }
        }
    }

    /// Headless wrapper for mark navigation.
    func jumpToMarkForTest_(next: Bool) { jumpToMark(next: next) }

    /// Jump to the next/previous marked SOURCE line (klogg LogViewNextMark/PrevMark),
    /// wrapping at the ends. No-op if there are no marks.
    private func jumpToMark(next: Bool) {
        guard let store = marksStore else { return }
        let here = sourceLine(forRow: selection.state.extentLine ?? firstVisibleLine)
        guard let targetSource = next ? store.nextMark(after: here)
                                      : store.previousMark(before: here) else { return }
        // Map the source line back to a row in THIS view's coordinate space.
        let targetRow: Int
        switch mode {
        case .main:
            targetRow = targetSource
        case .filtered:
            // Find the match row whose source line equals targetSource (best-effort).
            targetRow = (0..<currentLineCount).first { sourceLine(forRow: $0) == targetSource } ?? targetSource
        }
        selectAndScrollToLine(targetRow)
    }

    /// Scroll so that `line` is visible.
    private func scrollLineToVisible(_ line: Int) {
        let y = CGFloat(line) * rowHeight
        scrollToVisible(NSRect(x: 0, y: y, width: 1, height: rowHeight))
    }

    /// Clear the selection and repaint (headless tests).
    func clearSelectionForTest() {
        selection.clear()
        needsDisplay = true
    }

    /// Select `line` and scroll it into view (called by LogScrollView.scrollToLine).
    func selectAndScrollToLine(_ line: Int) {
        guard line >= 0, line < currentLineCount else { return }
        selection.setAnchor(line: line)
        scrollLineToVisible(line)
        needsDisplay = true
    }

    // MARK: - Actions (wired to first-responder chain)

    @IBAction override func selectAll(_ sender: Any?) {
        selection.selectAll(lineCount: currentLineCount)
        needsDisplay = true
    }

    @IBAction func copy(_ sender: Any?) {
        // Build selected text from cache + engine fallback.
        guard let range = selection.state.normalizedRange else { return }
        let lo = max(range.lowerBound, 0)
        let hi = min(range.upperBound, currentLineCount - 1)
        guard lo <= hi else { return }

        // Fetch lines we may not have in cache (e.g. a Cmd+A on a 1M-line file).
        var parts: [String] = []
        // Batch fetch in chunks to avoid a single enormous array in memory.
        let chunkSize = 10_000
        var cursor    = lo
        while cursor <= hi {
            let batchEnd = min(cursor + chunkSize - 1, hi)
            parts.append(contentsOf: fetchRows(first: cursor, last: batchEnd))
            cursor = batchEnd + 1
        }

        let text = parts.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copy the selection with each line prefixed by its (source) line number, as
    /// klogg's "Copy with line numbers" does. Format: "<num>\t<text>".
    @IBAction func copyWithLineNumbers(_ sender: Any?) {
        guard let range = selection.state.normalizedRange else { return }
        let lo = max(range.lowerBound, 0)
        let hi = min(range.upperBound, currentLineCount - 1)
        guard lo <= hi else { return }

        var parts: [String] = []
        var cursor = lo
        let chunkSize = 10_000
        while cursor <= hi {
            let batchEnd = min(cursor + chunkSize - 1, hi)
            let fetched = fetchRows(first: cursor, last: batchEnd)
            for (i, txt) in fetched.enumerated() {
                let num = sourceLine(forRow: cursor + i) + 1
                parts.append("\(num)\t\(txt)")
            }
            cursor = batchEnd + 1
        }
        let text = parts.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Trimmed text of the current selection's first line (drives the search/scratchpad
    /// context actions). Empty string when nothing meaningful is selected.
    private var selectionText: String { currentSelectionText ?? "" }

    // MARK: - Context-menu action targets (klogg abstractlogview popup)

    @objc private func ctxMark(_ sender: Any?)              { markSelectedLines() }
    @objc private func ctxReplaceSearch(_ sender: Any?)     { contextActions?.replaceSearch?(selectionText) }
    @objc private func ctxAddToSearch(_ sender: Any?)       { contextActions?.addToSearch?(selectionText) }
    @objc private func ctxExcludeSearch(_ sender: Any?)     { contextActions?.excludeFromSearch?(selectionText) }
    @objc private func ctxSendScratchpad(_ sender: Any?)    { contextActions?.sendToScratchpad?(selectionText) }
    @objc private func ctxReplaceScratchpad(_ sender: Any?) { contextActions?.replaceScratchpad?(selectionText) }
    @objc private func ctxSaveToFile(_ sender: Any?)        { saveSelectionToFile() }
    @objc private func ctxSaveAllToFile(_ sender: Any?)     { saveAllToFile() }
    @objc private func ctxSetSearchStart(_ sender: Any?) {
        guard let line = selectedSourceLines.first else { return }
        contextActions?.setSearchStart?(line)
    }
    @objc private func ctxSetSearchEnd(_ sender: Any?) {
        guard let line = selectedSourceLines.last else { return }
        contextActions?.setSearchEnd?(line)
    }
    @objc private func ctxClearSearchLimits(_ sender: Any?) { contextActions?.clearSearchLimits?() }

    /// Save the current selection to a file via an NSSavePanel (klogg "Save selected
    /// to file"). Headless-safe: only runs when a window is present.
    private func saveSelectionToFile() {
        guard let range = selection.state.normalizedRange, window != nil else { return }
        let lo = max(range.lowerBound, 0)
        let hi = min(range.upperBound, currentLineCount - 1)
        guard lo <= hi else { return }
        let nsRange = NSRange(location: lo, length: hi - lo + 1)
        let lines: [String]
        switch mode {
        case .main:     lines = engine.lines(in: nsRange, expandTabs: false)
        case .filtered: lines = engine.filteredLines(in: nsRange, expandTabs: false)
        }
        let text = lines.joined(separator: "\n") + "\n"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "selection.txt"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Save the ENTIRE current view (the whole file in the main view, or all matches in
    /// the filtered view) to a file, mirroring klogg's AbstractLogView::saveToFile
    /// (abstractlogview.cpp:1411 → saveLinesToFile over [0, getNbLine)). Streams the
    /// content in chunks so a multi-million-line file doesn't have to materialise in
    /// memory at once. Headless-safe: no-op without a window.
    private func saveAllToFile() {
        guard window != nil else { return }
        let total = effectiveLineCount()
        guard total > 0 else { return }
        let defaultName = (docViewSourceName ?? "log") + ".txt"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        let modeCapture = mode
        let engineCapture = engine
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            _ = Self.streamLines(total: total, mode: modeCapture, engine: engineCapture, to: url)
        }
    }

    /// Stream all `total` lines of `mode` from `engine` to `url` in chunks. Returns true
    /// on success. Shared by the interactive Save-to-file and the headless harness.
    @discardableResult
    static func streamLines(total: Int, mode: LogViewMode, engine: KloggEngine, to url: URL) -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        let chunkSize = 50_000
        var cursor = 0
        while cursor < total {
            let count = min(chunkSize, total - cursor)
            let nsRange = NSRange(location: cursor, length: count)
            let lines: [String]
            switch mode {
            case .main:     lines = engine.lines(in: nsRange, expandTabs: false)
            case .filtered: lines = engine.filteredLines(in: nsRange, expandTabs: false)
            }
            let block = lines.joined(separator: "\n") + "\n"
            if let data = block.data(using: .utf8) { handle.write(data) }
            cursor += count
        }
        return true
    }

    /// Headless wrapper: write the entire view to `url` without a save panel. Reads the
    /// count straight from the engine (the view may not be laid out in --selftest).
    func saveAllToFileForTest(to url: URL) -> Bool {
        Self.streamLines(total: effectiveLineCount(), mode: mode, engine: engine, to: url)
    }

    /// Best-effort source name for the default save filename (set by the owning tab).
    var docViewSourceName: String?

    // MARK: - Right-click / context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        // If the right-click lands on an unselected line, select it first (klogg
        // selects the clicked line before showing the popup).
        let point = convert(event.locationInWindow, from: nil)
        let line  = lineIndex(for: point)
        if !selection.state.contains(line: line) {
            selection.setAnchor(line: line)
            needsDisplay = true
        }
        return buildContextMenu()
    }

    /// Build the right-click menu mirroring klogg's abstractlogview popup ordering:
    /// Mark · Copy / Copy with line numbers / scratchpad · Replace/Add/Exclude search ·
    /// Select All · Save selected to file.
    func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "")
        let isSingle = (selection.state.normalizedRange.map { $0.lowerBound == $0.upperBound }) ?? false

        // Mark / Unmark (text flips when every selected line is already marked).
        if let store = marksStore {
            let lines = selectedSourceLines
            let allMarked = !lines.isEmpty && lines.allSatisfy { store.isMarked($0) }
            let mark = NSMenuItem(title: allMarked ? "Unmark" : "Mark",
                                  action: #selector(ctxMark(_:)), keyEquivalent: "")
            mark.target = self
            mark.isEnabled = !lines.isEmpty
            menu.addItem(mark)
            menu.addItem(.separator())
        }

        // Copy / Copy with line numbers.
        let copyTitle = isSingle ? "Copy this line" : "Copy"
        let copyItem = NSMenuItem(title: copyTitle, action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        menu.addItem(copyItem)

        let copyNumTitle = isSingle ? "Copy this line with line number" : "Copy with line numbers"
        let copyNum = NSMenuItem(title: copyNumTitle,
                                 action: #selector(copyWithLineNumbers(_:)), keyEquivalent: "")
        copyNum.target = self
        menu.addItem(copyNum)

        // Scratchpad (only if wired).
        if contextActions?.sendToScratchpad != nil {
            let send = NSMenuItem(title: "Send to scratchpad",
                                  action: #selector(ctxSendScratchpad(_:)), keyEquivalent: "")
            send.target = self
            menu.addItem(send)
        }
        if contextActions?.replaceScratchpad != nil {
            let repl = NSMenuItem(title: "Replace scratchpad",
                                  action: #selector(ctxReplaceScratchpad(_:)), keyEquivalent: "")
            repl.target = self
            menu.addItem(repl)
        }

        // Search actions (klogg: replace / add / exclude). Only meaningful with a
        // non-empty selection.
        let hasSel = !selectionText.isEmpty
        if contextActions?.replaceSearch != nil
            || contextActions?.addToSearch != nil
            || contextActions?.excludeFromSearch != nil {
            menu.addItem(.separator())
            if contextActions?.replaceSearch != nil {
                let it = NSMenuItem(title: "Replace search", action: #selector(ctxReplaceSearch(_:)), keyEquivalent: "")
                it.target = self; it.isEnabled = hasSel; menu.addItem(it)
            }
            if contextActions?.addToSearch != nil {
                let it = NSMenuItem(title: "Add to search", action: #selector(ctxAddToSearch(_:)), keyEquivalent: "")
                it.target = self; it.isEnabled = hasSel; menu.addItem(it)
            }
            if contextActions?.excludeFromSearch != nil {
                let it = NSMenuItem(title: "Exclude from search", action: #selector(ctxExcludeSearch(_:)), keyEquivalent: "")
                it.target = self; it.isEnabled = hasSel; menu.addItem(it)
            }
        }

        // Search-range limits (klogg: Set search start / Set search end / Clear search
        // limits). Enabled when a line is selected; "Set search start" anchors the range
        // at the clicked source line, "Set search end" one past it.
        if contextActions?.setSearchStart != nil
            || contextActions?.setSearchEnd != nil
            || contextActions?.clearSearchLimits != nil {
            menu.addItem(.separator())
            let hasLine = !selectedSourceLines.isEmpty
            if contextActions?.setSearchStart != nil {
                let it = NSMenuItem(title: "Set search start", action: #selector(ctxSetSearchStart(_:)), keyEquivalent: "")
                it.target = self; it.isEnabled = hasLine; menu.addItem(it)
            }
            if contextActions?.setSearchEnd != nil {
                let it = NSMenuItem(title: "Set search end", action: #selector(ctxSetSearchEnd(_:)), keyEquivalent: "")
                it.target = self; it.isEnabled = hasLine; menu.addItem(it)
            }
            if contextActions?.clearSearchLimits != nil {
                let it = NSMenuItem(title: "Clear search limits", action: #selector(ctxClearSearchLimits(_:)), keyEquivalent: "")
                it.target = self; menu.addItem(it)
            }
        }

        menu.addItem(.separator())
        let selectAllItem = NSMenuItem(title: "Select All",
                                       action: #selector(selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        let save = NSMenuItem(title: "Save selected to file",
                              action: #selector(ctxSaveToFile(_:)), keyEquivalent: "")
        save.target = self
        save.isEnabled = selection.state.normalizedRange != nil
        menu.addItem(save)

        // Save the entire view (whole file / all filtered matches) — klogg "Save to file".
        let saveAll = NSMenuItem(title: "Save to file",
                                 action: #selector(ctxSaveAllToFile(_:)), keyEquivalent: "")
        saveAll.target = self
        saveAll.isEnabled = currentLineCount > 0
        menu.addItem(saveAll)

        return menu
    }
}
