//
//  MarkerScroller.swift — vertical NSScroller that paints match/mark tick markers.
//
//  klogg draws a per-file "overview" of search-match and mark positions as small
//  coloured ticks down the scrollbar trough (abstractlogview / overviewwidget), so
//  the user sees at a glance where hits are in the WHOLE file. We replicate that by
//  subclassing NSScroller and overlaying ticks on the knob slot AFTER the system
//  draws the trough + knob. The markers are positioned by source line:
//      y = (line / totalLines) * slotHeight
//
//  This lives ON the scroller (the scroll view's vertical scroller), never inside the
//  document/clip view — so it can't disturb the O(visible) log text rendering.
//

import AppKit

final class MarkerScroller: NSScroller {

    /// Total source lines the trough represents (the file height). 0 → no markers.
    var totalLines: Int = 0 { didSet { needsDisplay = true } }

    /// Source (0-based) lines to mark with a tick + the colour to use. Set by the
    /// owning view; typically search matches (yellow) and marks (blue/red).
    struct Marker { let line: Int; let color: NSColor }
    var markers: [Marker] = [] { didSet { needsDisplay = true } }

    /// Keep the scroller always visible (legacy/overlay independent) so the markers
    /// read as a persistent overview, matching klogg.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMarkers()
    }

    /// Paint each marker as a short horizontal tick across the knob slot.
    private func drawMarkers() {
        guard totalLines > 0, !markers.isEmpty else { return }
        // The knob slot is the trough region the knob travels in; map lines into it.
        let slot = rect(for: .knobSlot)
        guard slot.height > 0 else { return }

        let inset: CGFloat = 2
        let tickHeight: CGFloat = 2
        let x = slot.minX + inset
        let w = max(1, slot.width - inset * 2)

        for m in markers {
            guard m.line >= 0, m.line < totalLines else { continue }
            let frac = CGFloat(m.line) / CGFloat(totalLines)
            // NSScroller is not flipped: y grows upward, but line 0 should sit at the
            // TOP of the slot, so invert.
            let yTop = slot.maxY - frac * slot.height
            let y = yTop - tickHeight / 2
            m.color.withAlphaComponent(0.9).setFill()
            NSRect(x: x, y: y, width: w, height: tickHeight).fill()
        }
    }
}
