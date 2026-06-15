//
//  LogSelection.swift — Line-granularity selection model for the native log view.
//
//  Mirrors klogg's abstractlogview Selection: the user selects one or more whole
//  lines by clicking (and extending with shift-click or drag).  Character-level
//  selection within a single line is tracked as a column range on the anchor line
//  but for Phase 1 we keep it line-granular, exactly like klogg's default feel.
//
//  Consumers:
//    * LogDocumentView — drives highlight painting and Cmd+A.
//    * LogScrollView   — forwards copy (Cmd+C) through this model.
//

import AppKit

/// Immutable snapshot of the current selection state.
struct LogSelectionState: Equatable {
    /// First selected line index (0-based), or nil when nothing is selected.
    var anchorLine: Int?
    /// Inclusive end of the selection range; equal to anchorLine for a single-line selection.
    var extentLine: Int?

    static let empty = LogSelectionState(anchorLine: nil, extentLine: nil)

    var isEmpty: Bool { anchorLine == nil }

    /// The [lo, hi] range, always low-to-high regardless of selection direction.
    var normalizedRange: ClosedRange<Int>? {
        guard let a = anchorLine, let e = extentLine else { return nil }
        return min(a, e) ... max(a, e)
    }

    /// Whether `line` falls inside the current selection.
    func contains(line: Int) -> Bool {
        normalizedRange?.contains(line) ?? false
    }
}

/// Stateful controller for click, shift-click, drag, and keyboard selection.
final class LogSelectionController {

    private(set) var state: LogSelectionState = .empty
    // Keeps the anchor fixed while the user drags or shift-clicks.
    private var pivotLine: Int?

    // MARK: - Mutation

    /// Set a single-line selection (mouse down on line, no modifier).
    func setAnchor(line: Int) {
        pivotLine = line
        state = LogSelectionState(anchorLine: line, extentLine: line)
    }

    /// Extend the selection to `line` from the current pivot (shift-click / drag).
    func extendTo(line: Int) {
        guard let pivot = pivotLine else {
            setAnchor(line: line)
            return
        }
        state = LogSelectionState(anchorLine: pivot, extentLine: line)
    }

    /// Select the entire range [0, lineCount-1].
    func selectAll(lineCount: Int) {
        guard lineCount > 0 else { state = .empty; return }
        pivotLine = 0
        state = LogSelectionState(anchorLine: 0, extentLine: lineCount - 1)
    }

    /// Clear the selection.
    func clear() {
        pivotLine = nil
        state = .empty
    }

    // MARK: - Text assembly (for Cmd+C)

    /// Assemble the text for the current selection, fetching lines from `engine`.
    /// Returns nil when nothing is selected.
    func selectedText(from lines: [String]) -> String? {
        guard let range = state.normalizedRange else { return nil }
        // Clamp to available lines.
        let lo = max(range.lowerBound, 0)
        let hi = min(range.upperBound, lines.count - 1)
        guard lo <= hi else { return nil }
        return lines[lo ... hi].joined(separator: "\n")
    }
}
