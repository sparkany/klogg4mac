//
//  OverviewView.swift — file-overview minimap strip (klogg's OverviewWidget).
//
//  A thin vertical strip placed beside the main log view (NOT inside the scroll
//  view's clip view). It represents the WHOLE file along its height and marks the
//  vertical position of every search match, so the user sees at a glance where hits
//  are clustered. Clicking the strip scrolls the main view to the corresponding line.
//
//  Drawing is O(match count): each match's source line maps to y = (line/total)*H.
//  When there are more matches than pixels, marks overlap (as in klogg) — we draw a
//  1px (or 2px) band per match; dense regions read as solid bars. The current
//  viewport is drawn as a translucent rectangle so the user knows where they are.
//

import AppKit

final class OverviewView: NSView {

    /// Total number of source lines (the file height the strip represents).
    var totalLines: Int = 0 { didSet { needsDisplay = true } }

    /// Match source-line provider: index → 0-based source line. Set by CrawlerTab to
    /// read engine.searchMatchLine(at:). Count is `matchCount`.
    var matchCount: Int = 0
    var matchLineAt: ((Int) -> Int)?

    /// Current main-view viewport, as a (firstVisibleLine, visibleLineCount) pair,
    /// so the strip can draw a "you are here" indicator. Updated on scroll.
    var viewportFirstLine: Int = 0 { didSet { needsDisplay = true } }
    var viewportLineCount: Int = 0 { didSet { needsDisplay = true } }

    /// Called with a 0-based target line when the user clicks the strip.
    var onScrollToLine: ((Int) -> Void)?

    /// Fixed strip width (klogg uses a narrow ~32px gutter-like strip).
    static let stripWidth: CGFloat = 36

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }   // y=0 at top, matching the log view

    /// Refresh match data from the engine and repaint.
    func reload(totalLines: Int, matchCount: Int) {
        self.totalLines = totalLines
        self.matchCount = matchCount
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Background + left separator rule (mirrors the gutter separator).
        (NSColor(named: NSColor.Name("gutterBackground")) ?? NSColor.controlBackgroundColor).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        guard totalLines > 0, bounds.height > 0 else { return }
        let h = bounds.height
        let markInset: CGFloat = 4   // leave the separator edge clear

        // Viewport indicator: a translucent band showing the visible range.
        if viewportLineCount > 0 {
            let y0 = CGFloat(viewportFirstLine) / CGFloat(totalLines) * h
            let y1 = CGFloat(min(totalLines, viewportFirstLine + viewportLineCount))
                / CGFloat(totalLines) * h
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            NSRect(x: 0, y: y0, width: bounds.width, height: max(2, y1 - y0)).fill()
        }

        // Match marks: one short horizontal band per match, mapped by source line.
        guard matchCount > 0, let provider = matchLineAt else { return }
        NSColor.systemYellow.withAlphaComponent(0.85).setFill()
        let markHeight: CGFloat = 2
        let markWidth = bounds.width - markInset * 2
        for i in 0 ..< matchCount {
            let line = provider(i)
            guard line >= 0, line < totalLines else { continue }
            let y = CGFloat(line) / CGFloat(totalLines) * h
            NSRect(x: markInset, y: max(0, y - markHeight / 2),
                   width: markWidth, height: markHeight).fill()
        }
    }

    // MARK: - Click → scroll

    override func mouseDown(with event: NSEvent) { jump(to: event) }
    override func mouseDragged(with event: NSEvent) { jump(to: event) }

    private func jump(to event: NSEvent) {
        guard totalLines > 0, bounds.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let frac = max(0, min(1, p.y / bounds.height))
        let line = min(totalLines - 1, Int(frac * CGFloat(totalLines)))
        onScrollToLine?(line)
    }
}
