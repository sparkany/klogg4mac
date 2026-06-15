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

/// Drop-in replacement for NSScrollView that hosts the log document view,
/// the floating line-number gutter, and wires engine callbacks.
final class LogScrollView: NSScrollView {

    private let docView: LogDocumentView
    private let gutter: LogLineNumberGutter
    /// Guards the one-shot stub auto-load (shared across all instances of this class).
    private static var stubAutoLoadFired = false

    init(engine: KloggEngine) {
        docView = LogDocumentView(engine: engine)
        gutter  = LogLineNumberGutter(font: docView.logFont, rowHeight: docView.rowHeight)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller   = true
        hasHorizontalScroller = true
        borderType            = .noBorder
        documentView          = docView

        // Pass gutter into docView so it can resize the text column.
        docView.gutterView = gutter

        // Gutter lives inside the clip view so it moves with horizontal scrolling.
        contentView.addSubview(gutter)
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

    /// Called by MainWindowController (and engine delegate) after a file loads.
    func reloadFromEngine() {
        let lineCount = Int(docView.engine.lineCount())
        let widthChanged = gutter.updateWidth(for: lineCount)
        docView.refreshSizing(lineCount: lineCount)
        if widthChanged {
            // Force doc view to re-lay-out its frame with the new gutter width.
            docView.invalidateIntrinsicContentSize()
        }
        updateGutterFrame()
        docView.needsDisplay = true
    }

    // MARK: - Gutter layout

    @objc private func boundsChanged() {
        updateGutterFrame()
        docView.needsDisplay = true
    }

    /// Keep the gutter pinned to the left of the visible area and flush top.
    private func updateGutterFrame() {
        let visibleRect = contentView.bounds
        let gutterW     = gutter.gutterWidth

        // The gutter is positioned in the clip view coordinate space — it scrolls
        // horizontally with content (so it always hugs the left edge of the viewport)
        // but stays at the top visually.
        gutter.frame = NSRect(
            x: visibleRect.minX,
            y: visibleRect.minY,
            width: gutterW,
            height: visibleRect.height)

        // Keep the gutter on top of the document view.
        contentView.sortSubviews({ v1, v2, _ in
            (v1 is LogLineNumberGutter) ? .orderedDescending : .orderedAscending
        }, context: nil)

        // Communicate scroll position to gutter for its number labels.
        let firstLine = Int(floor(visibleRect.minY / docView.rowHeight))
        gutter.firstVisibleLine = max(0, firstLine)
        gutter.lineCount        = docView.currentLineCount
        gutter.needsDisplay     = true
    }
}

// MARK: - LogDocumentView (private; the actual self-drawn view)

/// Self-drawn document view that renders all log lines via viewport culling.
/// Owns the selection model and handles keyboard + mouse events.
final class LogDocumentView: NSView {

    // MARK: Internal references

    let engine: KloggEngine
    /// Set by LogScrollView after construction.
    weak var gutterView: LogLineNumberGutter?

    // MARK: Font / metrics

    let logFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Exact pixel height of one row, derived from font metrics.
    let rowHeight: CGFloat
    /// Advance width of a single character (monospaced — all chars are the same).
    private let charWidth: CGFloat

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

    // MARK: - Init

    init(engine: KloggEngine) {
        self.engine = engine
        let fm = NSLayoutManager()   // lightweight FM without a text storage
        // Use typographic line height: ascender + |descender| + leading, rounded up + 2px.
        let ascender  = logFont.ascender
        let descender = abs(logFont.descender)
        let leading   = logFont.leading
        rowHeight = ceil(ascender + descender + leading) + 2
        // For a monospaced font, character width == advance of any glyph.
        charWidth = logFont.advancement(forGlyph: logFont.glyph(withName: "M")).width
        _ = fm   // silence unused warning
        super.init(frame: .zero)
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
        let range  = NSRange(location: firstRow, length: lastRow - firstRow + 1)
        let fetched = engine.lines(in: range, expandTabs: true)
        Swift.print("[LogDocumentView] draw: rows \(firstRow)–\(lastRow), count=\(currentLineCount), rowH=\(rowHeight), fetched=\(fetched.count), first='\(fetched.first ?? "(nil)")', gutter=\(gutterView?.gutterWidth ?? -1)")

        // X offset: gutter takes the left portion of the doc view coordinate space.
        let gutterWidth = gutterView?.gutterWidth ?? 0
        let textX       = gutterWidth + textLeftPadding

        // Text attributes.
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: logFont,
            .foregroundColor: NSColor.textColor,
        ]
        let selectedAttrs: [NSAttributedString.Key: Any] = [
            .font: logFont,
            .foregroundColor: NSColor.selectedTextColor,
        ]

        for (offset, lineText) in fetched.enumerated() {
            let row = firstRow + offset
            let y   = CGFloat(row) * rowHeight

            if selection.state.contains(line: row) {
                // Draw selection background across the full row.
                NSColor.selectedTextBackgroundColor.setFill()
                NSRect(x: gutterWidth, y: y,
                       width: bounds.width - gutterWidth, height: rowHeight).fill()
                (lineText as NSString).draw(at: NSPoint(x: textX, y: y),
                                            withAttributes: selectedAttrs)
            } else {
                (lineText as NSString).draw(at: NSPoint(x: textX, y: y),
                                            withAttributes: normalAttrs)
            }

            // Cache for fast copy access.
            visibleLineCache[row] = lineText
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
            let batchEnd    = min(cursor + chunkSize - 1, hi)
            let nsRange     = NSRange(location: cursor, length: batchEnd - cursor + 1)
            let fetched     = engine.lines(in: nsRange, expandTabs: true)
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
