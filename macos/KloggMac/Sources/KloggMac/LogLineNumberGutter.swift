//
//  LogLineNumberGutter.swift — Line-number gutter for the native log view.
//
//  Mirrors klogg's abstractlogview left-margin: right-aligned line numbers in a
//  subtle monospaced gutter separated from the text area by a thin vertical rule.
//  The gutter is a floating (non-scrolling) companion view pinned to the left edge
//  of the LogScrollView.  It redraws on every scroll notification — because it
//  shares the same font and row height as LogDocumentView it stays perfectly in sync.
//
//  Layout (matches klogg):
//    [  gutter  |rule| text area                                           ]
//               ^--- gutterWidth computed from digit count of lineCount
//
//  Owners: LogScrollView creates and positions this view.
//

import AppKit

final class LogLineNumberGutter: NSView {

    // Exposed so LogScrollView can resize the gutter when lineCount changes.
    private(set) var gutterWidth: CGFloat = 0

    // Styling — same font as LogDocumentView. Mutable so the gutter can follow
    // a live font-preference change (LogScrollView.applyFont).
    private var font: NSFont
    private var rowHeight: CGFloat
    private let separatorColor: NSColor = .separatorColor
    private let numberColor: NSColor = .secondaryLabelColor
    private let backgroundColor: NSColor = NSColor(named: NSColor.Name("gutterBackground"))
        ?? NSColor.controlBackgroundColor

    // Set by LogScrollView before drawing.
    var firstVisibleLine: Int = 0
    var lineCount: Int = 0

    // Internal horizontal padding inside the number column.
    static let innerPadding: CGFloat = 6
    // Width of the separator rule on the right edge of the gutter.
    static let separatorWidth: CGFloat = 1

    init(font: NSFont, rowHeight: CGFloat) {
        self.font = font
        self.rowHeight = rowHeight
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Gutter does not flip — it is positioned in the clip view's coordinate space
        // and LogScrollView directly sets its origin.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Public API

    /// Update font + row height after a font-preference change so the gutter's
    /// width recomputation and number layout stay in sync with the document view.
    func updateFont(_ newFont: NSFont, rowHeight newRowHeight: CGFloat) {
        font = newFont
        rowHeight = newRowHeight
    }

    /// Recompute the gutter width from the current digit count.  Call whenever
    /// lineCount changes.  Returns true when the width changed (caller must re-layout).
    @discardableResult
    func updateWidth(for lineCount: Int) -> Bool {
        let digits = max(1, lineCount).description.count
        let sample = String(repeating: "9", count: digits)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = (sample as NSString).size(withAttributes: attrs).width
        let newWidth = ceil(textWidth) + LogLineNumberGutter.innerPadding * 2
            + LogLineNumberGutter.separatorWidth
        if newWidth != gutterWidth {
            gutterWidth = newWidth
            return true
        }
        return false
    }

    // MARK: - Drawing

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Background.
        backgroundColor.setFill()
        dirtyRect.fill()

        // Separator rule on the right edge.
        let ruleX = bounds.maxX - LogLineNumberGutter.separatorWidth
        separatorColor.setFill()
        NSRect(x: ruleX, y: 0, width: LogLineNumberGutter.separatorWidth,
               height: bounds.height).fill()

        guard lineCount > 0, rowHeight > 0 else { return }

        // Derive the visible range from the scroll position. The gutter's origin
        // is kept at the scroll-view's top-left by LogScrollView, and its height
        // equals the visible height, so dirtyRect gives us the visible band.
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: numberColor,
        ]

        let firstRow = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let lastRow  = min(lineCount - 1, Int(ceil(dirtyRect.maxY / rowHeight)))

        for row in firstRow ... lastRow {
            let lineNum = firstVisibleLine + row   // absolute line number (0-based)
            guard lineNum < lineCount else { break }
            let label = "\(lineNum + 1)" as NSString   // 1-based display
            let labelSize = label.size(withAttributes: textAttrs)
            // Right-align within the gutter, left of the separator.
            let x = ruleX - LogLineNumberGutter.innerPadding - labelSize.width
            let y = CGFloat(row) * rowHeight + (rowHeight - labelSize.height) / 2
            label.draw(at: NSPoint(x: x, y: y), withAttributes: textAttrs)
        }
    }
}
