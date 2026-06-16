//
//  ScratchpadWindowController.swift — Floating scratchpad panel.
//
//  Mirrors klogg's ScratchPad widget (scratchpad.cpp):
//
//  Left pane: editable plain-text view (notes, pasted log lines).
//  Right pane: live read-only transformation display (CRC32 hex/dec,
//              Windows FILETIME→UTC, Dec→Hex, Hex→Dec).
//  Toolbar: From base64 / To base64 / From hex / To hex / Decode URL /
//           Format JSON / Format XML
//
//  All toolbar transforms operate on the current selection, falling back
//  to the entire text when nothing is selected.  Result replaces the
//  selection/text and is also copied to the clipboard (matching klogg).
//
//  Auto-saves content to UserDefaults on every keystroke so it survives
//  a restart.  Toggle show/hide via toggle().
//

import AppKit
import Foundation
import zlib   // for CRC32

// MARK: - ScratchpadWindowController

final class ScratchpadWindowController: NSWindowController {

    // MARK: - Subviews

    private let textView    = NSTextView()
    private let scrollView  = NSScrollView()

    // Right-pane live transformation display
    private let crc32HexField = NSTextField()
    private let crc32DecField = NSTextField()
    private let fileTimeField = NSTextField()
    private let decToHexField = NSTextField()
    private let hexToDecField = NSTextField()

    private let statusLabel = NSTextField(labelWithString: "")
    private var statusTimer: Timer?

    private let contentKey = "klogg.scratchpadText"

    // MARK: - Init

    init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        win.title = "Scratchpad"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.setFrameAutosaveName("klogg.scratchpad")
        super.init(window: win)
        buildUI()
        loadContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Public API

    func toggle() {
        guard let win = window else { return }
        if win.isVisible { win.orderOut(nil) } else { win.makeKeyAndOrderFront(nil) }
    }

    /// Append text from log view selection (mirrors klogg's ScratchPad::addData).
    func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        textView.textStorage?.append(NSAttributedString(string: "\n" + text))
        saveContent()
    }

    /// Replace entire text (mirrors klogg's ScratchPad::replaceData).
    func replaceText(_ text: String) {
        guard !text.isEmpty else { return }
        textView.string = text
        saveContent()
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Left: text editor
        textView.isEditable              = true
        textView.isRichText              = false
        textView.font                    = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.allowsUndo              = true
        textView.isVerticallyResizable   = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset      = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self

        scrollView.documentView          = textView
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType            = .bezelBorder

        // Right: transform display panel
        let rightPanel = buildTransformPanel()

        // Toolbar
        let toolbarRow = buildToolbar()

        // Status label
        statusLabel.font      = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        // Bottom bar
        let saveBtn  = NSButton(title: "Save…", target: self, action: #selector(saveToFile(_:)))
        let clearBtn = NSButton(title: "Clear",  target: self, action: #selector(clearContent(_:)))
        saveBtn.bezelStyle  = .rounded
        clearBtn.bezelStyle = .rounded
        let bottomBar = NSStackView(views: [statusLabel, NSView(), clearBtn, saveBtn])
        bottomBar.distribution = .fill
        bottomBar.spacing      = 8

        // Horizontal split
        let split = NSSplitView()
        split.isVertical   = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(scrollView)
        split.addArrangedSubview(rightPanel)

        let mainStack = NSStackView(views: [toolbarRow, split, bottomBar])
        mainStack.orientation = .vertical
        mainStack.spacing     = 6
        mainStack.edgeInsets  = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: content.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rightPanel.widthAnchor.constraint(equalToConstant: 270),
        ])

        DispatchQueue.main.async { [weak split] in
            let w = split?.bounds.width ?? 700
            split?.setPosition(w * 0.6, ofDividerAt: 0)
        }
    }

    private func buildToolbar() -> NSView {
        func btn(_ title: String, sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .roundRect
            b.font       = .systemFont(ofSize: 11)
            return b
        }
        let bar = NSStackView(views: [
            btn("From base64", sel: #selector(actDecodeBase64(_:))),
            btn("To base64",   sel: #selector(actEncodeBase64(_:))),
            btn("From hex",    sel: #selector(actDecodeHex(_:))),
            btn("To hex",      sel: #selector(actEncodeHex(_:))),
            btn("Decode URL",  sel: #selector(actDecodeURL(_:))),
            NSView(),
            btn("Format JSON", sel: #selector(actFormatJSON(_:))),
            btn("Format XML",  sel: #selector(actFormatXML(_:))),
        ])
        bar.orientation  = .horizontal
        bar.distribution = .fill
        bar.spacing      = 4
        return bar
    }

    private func buildTransformPanel() -> NSView {
        for f in [crc32HexField, crc32DecField, fileTimeField, decToHexField, hexToDecField] {
            f.isEditable         = false
            f.isSelectable       = true
            f.font               = .monospacedSystemFont(ofSize: 11, weight: .regular)
            f.usesSingleLineMode = true
            f.lineBreakMode      = .byTruncatingTail
        }

        func label(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font      = .systemFont(ofSize: 11)
            f.alignment = .right
            return f
        }

        let grid = NSGridView(views: [
            [label("CRC32 hex:"), crc32HexField],
            [label("CRC32 dec:"), crc32DecField],
            [label("File time:"),  fileTimeField],
            [label("Dec→Hex:"),    decToHexField],
            [label("Hex→Dec:"),    hexToDecField],
        ])
        grid.column(at: 0).width = 74
        grid.rowSpacing    = 5
        grid.columnSpacing = 6

        let box = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
        ])
        return box
    }

    // MARK: - Persistence

    private func loadContent() {
        textView.string = AppDefaults.store.string(forKey: contentKey) ?? ""
    }

    private func saveContent() {
        AppDefaults.store.set(textView.string, forKey: contentKey)
    }

    // MARK: - Live transforms

    private func updateTransforms() {
        let text = selectedOrAllText()
        crc32HexField.stringValue = crc32HexOf(text)
        crc32DecField.stringValue = crc32DecOf(text)
        fileTimeField.stringValue = windowsFileTimeOf(text)
        decToHexField.stringValue = decToHexOf(text)
        hexToDecField.stringValue = hexToDecOf(text)
    }

    private func selectedOrAllText() -> String {
        let range = textView.selectedRange()
        if range.length > 0 {
            return (textView.string as NSString).substring(with: range)
        }
        return textView.string
    }

    private func crc32HexOf(_ text: String) -> String {
        let data = Data(text.utf8)
        var val: uLong = 0
        data.withUnsafeBytes { buf in
            val = zlib.crc32(0,
                buf.baseAddress?.assumingMemoryBound(to: Bytef.self),
                uInt(buf.count))
        }
        return String(format: "0x%08x", val)
    }

    private func crc32DecOf(_ text: String) -> String {
        let data = Data(text.utf8)
        var val: uLong = 0
        data.withUnsafeBytes { buf in
            val = zlib.crc32(0,
                buf.baseAddress?.assumingMemoryBound(to: Bytef.self),
                uInt(buf.count))
        }
        return "\(val)"
    }

    private func windowsFileTimeOf(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ticks = Int64(t), ticks > 0 else { return "" }
        let unixSeconds = ticks / 10_000_000 - 11_644_473_600
        let date = Date(timeIntervalSince1970: Double(unixSeconds))
        let fmt  = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(abbreviation: "UTC")
        return fmt.string(from: date)
    }

    private func decToHexOf(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = Int64(t) else { return "" }
        return String(format: "%08llx", v)
    }

    private func hexToDecOf(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
        guard let v = Int64(t, radix: 16) else { return "" }
        return "\(v)"
    }

    // MARK: - Toolbar actions

    @objc private func actDecodeBase64(_ sender: Any?) { transformInPlace(Transforms.decodeBase64) }
    @objc private func actEncodeBase64(_ sender: Any?) { transformInPlace(Transforms.encodeBase64) }
    @objc private func actDecodeHex(_ sender: Any?)    { transformInPlace(Transforms.decodeHex) }
    @objc private func actEncodeHex(_ sender: Any?)    { transformInPlace(Transforms.encodeHex) }
    @objc private func actDecodeURL(_ sender: Any?)    { transformInPlace(Transforms.decodeURL) }
    @objc private func actFormatJSON(_ sender: Any?)   { transformInPlace(Transforms.formatJSON) }
    @objc private func actFormatXML(_ sender: Any?)    { transformInPlace(Transforms.formatXML) }

    // MARK: - Pure transforms (window-free, so the headless harness can verify them)

    /// The toolbar transforms as pure String → String? functions. The `act…` handlers
    /// and the self-test both call these; nil means "no usable result" (caller beeps /
    /// shows a status). Kept here so the exact behaviour matches what the UI runs.
    enum Transforms {
        static func decodeBase64(_ text: String) -> String? {
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  options: .ignoreUnknownCharacters),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }

        static func encodeBase64(_ text: String) -> String? {
            Data(text.utf8).base64EncodedString()
        }

        static func decodeHex(_ text: String) -> String? {
            let clean = text.replacingOccurrences(of: " ", with: "")
                            .replacingOccurrences(of: "\n", with: "")
            var bytes: [UInt8] = []
            var i = clean.startIndex
            while i < clean.endIndex {
                let j = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
                if let b = UInt8(clean[i..<j], radix: 16) { bytes.append(b) }
                i = j
            }
            return String(bytes: bytes, encoding: .utf8)
                ?? String(bytes: bytes, encoding: .isoLatin1)
        }

        static func encodeHex(_ text: String) -> String? {
            Data(text.utf8).map { String(format: "%02x", $0) }.joined()
        }

        static func decodeURL(_ text: String) -> String? {
            text.removingPercentEncoding
        }

        static func formatJSON(_ text: String) -> String? {
            guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
            let sub = String(text[start...])
            guard let data   = sub.data(using: .utf8),
                  let obj    = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(
                      withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                  let str    = String(data: pretty, encoding: .utf8) else { return nil }
            return str
        }

        static func formatXML(_ text: String) -> String? {
            guard text.contains("<"),
                  let data = text.data(using: .utf8),
                  let doc  = try? XMLDocument(data: data, options: .nodePrettyPrint)
            else { return nil }
            return doc.xmlString(options: .nodePrettyPrint)
        }
    }

    // MARK: - Transform helper

    private func transformInPlace(_ transform: (String) -> String?) {
        let range        = textView.selectedRange()
        let hasSelection = range.length > 0
        let input        = hasSelection
            ? (textView.string as NSString).substring(with: range)
            : textView.string
        guard let result = transform(input), !result.isEmpty else {
            showStatus("Empty transformation")
            return
        }
        if hasSelection {
            textView.insertText(result, replacementRange: range)
        } else {
            textView.string = result
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        showStatus("Copied to clipboard")
        saveContent()
    }

    private func showStatus(_ msg: String) {
        statusLabel.stringValue = msg
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.statusLabel.stringValue = ""
        }
    }

    // MARK: - Bottom bar

    @objc private func clearContent(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText     = "Clear Scratchpad?"
        alert.informativeText = "This will permanently erase all scratchpad text."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        textView.string = ""
        updateTransforms()
        saveContent()
    }

    @objc private func saveToFile(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title                = "Save Scratchpad"
        panel.allowedContentTypes  = [.plainText]
        panel.nameFieldStringValue = "scratchpad.txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            do {
                try self.textView.string.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

// MARK: - NSTextViewDelegate

extension ScratchpadWindowController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        saveContent()
        updateTransforms()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateTransforms()
    }
}
