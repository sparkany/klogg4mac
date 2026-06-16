//
//  StatusBar.swift — Status / info bar at the bottom of the window.
//
//  Mirrors klogg's infoline / pathline / displayfilepath combination:
//    • File path (PathLine equivalent) — shown in the toolbar area
//    • Line count, current position, file size, encoding (in the toolbar)
//
//  This view is hosted in the window toolbar (via AppToolbar) and updated
//  by TabController when the active tab changes or the engine reports progress.
//

import AppKit

/// A lightweight view that shows [filePath | size | lineCount | encoding].
/// Hosted as a toolbar item's view so it stretches between the action buttons.
final class StatusBarView: NSView {

    // MARK: - Subviews

    private let pathField: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.lineBreakMode = .byTruncatingMiddle
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }()

    private let sizeField: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentHuggingPriority(.required, for: .horizontal)
        return f
    }()

    private let lineField: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentHuggingPriority(.required, for: .horizontal)
        return f
    }()

    private let encodingField: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentHuggingPriority(.required, for: .horizontal)
        return f
    }()

    /// "modified on <date>" — mirrors klogg's dateField (mainwindow.cpp).
    private let dateField: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentHuggingPriority(.required, for: .horizontal)
        return f
    }()

    /// Total line count of the current file, cached so updatePosition can render
    /// klogg's "Ln:N/Total" format without re-querying.
    private var totalLines: Int = 0

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func buildLayout() {
        let separator1 = makeSeparator()
        let separator2 = makeSeparator()
        let separator3 = makeSeparator()
        let separator4 = makeSeparator()

        // klogg toolbar order (mainwindow.cpp createToolBars): info | size | date |
        // encoding | line-number.
        let stack = NSStackView(views: [
            pathField, separator1,
            sizeField, separator2,
            dateField, separator3,
            encodingField, separator4,
            lineField,
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func makeSeparator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    // MARK: - Update API

    /// Called by TabController when a file finishes loading or the tab changes.
    func update(filePath: String?, lineCount: Int?, fileSize: Int64?, encoding: String?,
                modified: Date? = nil) {
        pathField.stringValue = filePath ?? ""
        pathField.toolTip = filePath

        if let sz = fileSize {
            sizeField.stringValue = formatSize(sz)
        } else {
            sizeField.stringValue = ""
        }

        // klogg "modified on <date>" (dateField).
        if let d = modified {
            dateField.stringValue = "modified on " + Self.dateFormatter.string(from: d)
        } else {
            dateField.stringValue = ""
        }

        totalLines = lineCount ?? 0
        // klogg shows Ln:1/Total once the file is loaded (lineNumberHandler).
        if let lc = lineCount, lc > 0 {
            lineField.stringValue = "Ln:1/\(lc)"
        } else {
            lineField.stringValue = ""
        }

        encodingField.stringValue = encoding ?? ""
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Called by MainWindowController when the user picks an encoding from the menu.
    func updateEncoding(_ name: String) {
        encodingField.stringValue = name
    }

    /// Called by TabController on selection changes. Mirrors klogg's lineNumberHandler
    /// (mainwindow.cpp): "Ln:N/Total" plain, "Ln:N/Total Col:C Sel:S|L" with a portion
    /// selection on one line, "Ln:N/Total Sel:S|L" across multiple selected lines.
    /// - Parameters:
    ///   - line: 0-based current line.
    ///   - column: 0-based start column of a portion selection (nil = whole line).
    ///   - selSymbols: number of selected characters (0 = no portion selection).
    ///   - selLines: number of selected lines.
    func updatePosition(line: Int?, column: Int?, selSymbols: Int = 0, selLines: Int = 1) {
        guard let ln = line, totalLines > 0 else { return }
        let n = ln + 1
        if selSymbols == 0 {
            lineField.stringValue = "Ln:\(n)/\(totalLines)"
        } else if selLines == 1, let col = column {
            lineField.stringValue = "Ln:\(n)/\(totalLines) Col:\(col) Sel:\(selSymbols)|\(selLines)"
        } else {
            lineField.stringValue = "Ln:\(n)/\(totalLines) Sel:\(selSymbols)|\(selLines)"
        }
    }

    // MARK: - Loading progress

    func showProgress(_ percent: Int) {
        lineField.stringValue = "Loading… \(percent)%"
    }

    /// Current text of the line-position field (headless assertions).
    var selfTestLineFieldText: String { lineField.stringValue }

    // MARK: - Helpers

    private func formatSize(_ bytes: Int64) -> String {
        let kb: Int64 = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        switch bytes {
        case 0..<kb:  return "\(bytes) B"
        case kb..<mb: return String(format: "%.1f KB", Double(bytes) / Double(kb))
        case mb..<gb: return String(format: "%.1f MB", Double(bytes) / Double(mb))
        default:       return String(format: "%.2f GB", Double(bytes) / Double(gb))
        }
    }
}
