//
//  LogScrollView.swift — Phase-1 custom log view (the highest-risk component).
//
//  Strategy for rendering millions of lines (ROADMAP §4 Phase 1):
//    * fixed row height (monospaced font) => the document view's height is just
//      lineCount * rowHeight; no per-line layout up front.
//    * only the visible row range is pulled from the engine and drawn each frame
//      (viewport-driven), so memory and draw cost are O(visible rows), not O(file).
//
//  This is the skeleton the `logview` role hardens: selection, copy, line-number
//  gutter, tab expansion, find highlighting, and a pixel-for-pixel match to klogg's
//  abstractlogview rendering.
//

import AppKit
import KloggBridge

final class LogScrollView: NSScrollView {

    private let docView: LogDocumentView

    init(engine: KloggEngine) {
        docView = LogDocumentView(engine: engine)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        borderType = .noBorder
        documentView = docView
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func boundsChanged() { docView.needsDisplay = true }

    func reloadFromEngine() {
        docView.refreshSizing()
        docView.needsDisplay = true
    }
}

private final class LogDocumentView: NSView {

    private let engine: KloggEngine
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var rowHeight: CGFloat = 16
    private let leftPadding: CGFloat = 8

    init(engine: KloggEngine) {
        self.engine = engine
        super.init(frame: .zero)
        rowHeight = ceil(font.ascender - font.descender + font.leading) + 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }   // origin top-left, like a text editor

    func refreshSizing() {
        let lines = engine.lineCount()
        // Width is approximate for now; horizontal layout is a Phase-1 task.
        let height = CGFloat(lines) * rowHeight
        setFrameSize(NSSize(width: max(bounds.width, 2000), height: max(height, 1)))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let lineCount = Int(engine.lineCount())
        guard lineCount > 0, rowHeight > 0 else { return }

        // Only lay out the rows intersecting the dirty rect.
        let first = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let last  = min(lineCount - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard first <= last else { return }

        let lines = engine.lines(in: NSRange(location: first, length: last - first + 1),
                                 expandTabs: true)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
        ]
        for (offset, text) in lines.enumerated() {
            let row = first + offset
            let y = CGFloat(row) * rowHeight
            (text as NSString).draw(at: NSPoint(x: leftPadding, y: y), withAttributes: attrs)
        }
    }
}
