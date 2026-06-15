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

    init(engine: KloggEngine, mode: LogViewMode = .main) {
        docView = LogDocumentView(engine: engine, mode: mode)
        gutter  = LogLineNumberGutter(font: docView.logFont, rowHeight: docView.rowHeight)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller   = true
        hasHorizontalScroller = true
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
        docView.needsDisplay = true
    }

    // MARK: - Scroll tracking

    /// On any scroll (including horizontal), repaint so the inline gutter — which is
    /// pinned to the viewport's left edge — follows the scroll position.
    @objc private func boundsChanged() {
        docView.needsDisplay = true
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

    // MARK: Highlighting / preferences

    /// Compiled highlighter rules; rebuilt when HighlighterStore changes.
    private let highlighter = LogHighlighter()

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
        // Width: compute from the longest line if we have lines, else use a wide default.
        // (We defer expensive full-scan; just use a generous initial width.)
        let docWidth = max(lineCountEstimatedMaxWidth, enclosingScrollView?.bounds.width ?? 800)
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

        // Compute which rows intersect dirtyRect.
        let firstRow = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let lastRow  = min(currentLineCount - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard firstRow <= lastRow else { return }

        // Fetch visible lines from engine (O(visible rows)).
        let range = NSRange(location: firstRow, length: lastRow - firstRow + 1)
        let fetched: [String]
        switch mode {
        case .main:
            fetched = engine.lines(in: range, expandTabs: true)
        case .filtered:
            fetched = engine.filteredLines(in: range, expandTabs: true)
        }

        // Gutter visibility is preference-driven: when line numbers are off for
        // this mode, the gutter collapses to width 0 and text starts at the left.
        let gutterWidth = lineNumbersEnabled ? (gutterView?.gutterWidth ?? 0) : 0
        let textX       = gutterWidth + textLeftPadding

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

        // 2) Line-number gutter, painted last so it overlays the text and stays
        //    pinned to the viewport's left edge as the content scrolls horizontally.
        if gutterWidth > 0 {
            drawGutter(dirtyRect: dirtyRect, firstRow: firstRow, lastRow: lastRow,
                       gutterWidth: gutterWidth)
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

    /// Paint the line-number gutter band at the left edge of the visible viewport.
    /// Drawn in document coordinates but offset by the clip view's horizontal scroll
    /// so it appears frozen at the left (klogg's abstractlogview left margin).
    private func drawGutter(dirtyRect: NSRect, firstRow: Int, lastRow: Int,
                            gutterWidth: CGFloat) {
        let scrollX = enclosingScrollView?.contentView.bounds.origin.x ?? 0
        let band = NSRect(x: scrollX, y: dirtyRect.minY,
                          width: gutterWidth, height: dirtyRect.height)

        (NSColor(named: NSColor.Name("gutterBackground")) ?? NSColor.controlBackgroundColor).setFill()
        band.fill()

        // Separator rule on the gutter's right edge.
        NSColor.separatorColor.setFill()
        NSRect(x: scrollX + gutterWidth - 1, y: dirtyRect.minY,
               width: 1, height: dirtyRect.height).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: logFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let innerPad: CGFloat = 6
        for row in firstRow ... lastRow {
            // In the filtered view, show each match's ORIGINAL source line number
            // (as klogg does); in the main view, the row index is the line number.
            let displayNum: Int
            if mode == .filtered {
                let src = engine.searchMatchLine(at: UInt(row))
                displayNum = (src == UInt.max) ? (row + 1) : Int(src) + 1
            } else {
                displayNum = row + 1
            }
            let label = "\(displayNum)" as NSString
            let size  = label.size(withAttributes: attrs)
            let x = scrollX + gutterWidth - innerPad - size.width
            let y = CGFloat(row) * rowHeight + (rowHeight - size.height) / 2
            label.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
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

    override func keyDown(with event: NSEvent) {
        // Let NSResponder handle Cmd+A / Cmd+C.
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "a": selectAll(self)
            case "c": copy(self)
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
            super.keyDown(with: event)
        }
    }

    /// Scroll so that `line` is visible.
    private func scrollLineToVisible(_ line: Int) {
        let y = CGFloat(line) * rowHeight
        scrollToVisible(NSRect(x: 0, y: y, width: 1, height: rowHeight))
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
            let nsRange  = NSRange(location: cursor, length: batchEnd - cursor + 1)
            let fetched: [String]
            switch mode {
            case .main:
                fetched = engine.lines(in: nsRange, expandTabs: true)
            case .filtered:
                fetched = engine.filteredLines(in: nsRange, expandTabs: true)
            }
            parts.append(contentsOf: fetched)
            cursor = batchEnd + 1
        }

        let text = parts.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Right-click / context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)),
                                  keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        let selectAllItem = NSMenuItem(title: "Select All",
                                       action: #selector(selectAll(_:)),
                                       keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        menu.addItem(copyItem)
        menu.addItem(selectAllItem)
        return menu
    }
}
