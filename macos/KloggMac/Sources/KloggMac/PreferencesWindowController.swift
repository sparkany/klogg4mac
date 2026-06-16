//
//  PreferencesWindowController.swift — Tabbed Preferences/Options dialog.
//
//  Mirrors klogg's OptionsDialog (src/ui/src/optionsdialog.cpp), covering
//  the same settings groups with native AppKit controls:
//
//    Display  — main font family + size, text wrap, hide ANSI colors
//    Search   — default regexp type, case sensitivity, auto-refresh,
//               highlight in main view, auto-run search
//    Behavior — session restore, follow on load, file-watch / polling
//    Perf     — parallel search, search results cache, index buffer sizes
//    Advanced — logging level, encoding default MIB
//
//  Settings are persisted via AppPreferences (UserDefaults keys matching
//  klogg's QSettings keys) so files are interoperable between builds.
//  Changes take effect immediately (live-apply) and each tab section
//  round-trips its values: values written here read back identically.
//

import AppKit

final class PreferencesWindowController: NSWindowController {

    // MARK: - Init

    override init(window: NSWindow?) { super.init(window: window) }

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        win.title = "Preferences"
        win.isReleasedWhenClosed = false
        self.init(window: win)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Display tab controls

    private let fontFamilyField   = NSTextField()
    private let fontSizeField     = NSTextField()
    private let wrapCheck         = NSButton(checkboxWithTitle: "Wrap long lines",         target: nil, action: nil)
    private let hideAnsiCheck     = NSButton(checkboxWithTitle: "Hide ANSI color sequences", target: nil, action: nil)
    private let boldFontCheck     = NSButton(checkboxWithTitle: "Bold font",               target: nil, action: nil)
    private let lineNumMainCheck  = NSButton(checkboxWithTitle: "Show line numbers in main view",     target: nil, action: nil)
    private let lineNumFiltCheck  = NSButton(checkboxWithTitle: "Show line numbers in filtered view", target: nil, action: nil)

    // MARK: - Search tab controls

    private let regexpTypeSegment  = NSSegmentedControl(labels: ["Extended Regexp", "Fixed Strings"],
                                                        trackingMode: .selectOne, target: nil, action: nil)
    private let ignoreCaseCheck    = NSButton(checkboxWithTitle: "Ignore case by default",     target: nil, action: nil)
    private let autoRefreshCheck   = NSButton(checkboxWithTitle: "Auto-refresh search results",target: nil, action: nil)
    private let autoRunCheck       = NSButton(checkboxWithTitle: "Auto-run search while typing",target: nil, action: nil)
    private let highlightMainCheck = NSButton(checkboxWithTitle: "Highlight matches in main view", target: nil, action: nil)
    private let incrementalCheck   = NSButton(checkboxWithTitle: "Incremental QuickFind",      target: nil, action: nil)
    private let variateHlCheck     = NSButton(checkboxWithTitle: "Variate highlight colours per match", target: nil, action: nil)
    private let searchHistoryField = NSTextField()
    private let recentFilesField   = NSTextField()

    // MARK: - Behavior tab controls

    private let loadLastCheck      = NSButton(checkboxWithTitle: "Restore last session on launch",  target: nil, action: nil)
    private let followLoadCheck    = NSButton(checkboxWithTitle: "Follow file when opened (tail mode)", target: nil, action: nil)
    private let nativeWatchCheck   = NSButton(checkboxWithTitle: "Use native filesystem watch (kqueue)", target: nil, action: nil)
    private let pollingCheck       = NSButton(checkboxWithTitle: "Fallback polling",               target: nil, action: nil)
    private let pollIntervalField  = NSTextField()
    private let followScrollCheck  = NSButton(checkboxWithTitle: "Allow follow on scroll",         target: nil, action: nil)

    // MARK: - Performance tab controls

    private let parallelSearchCheck = NSButton(checkboxWithTitle: "Use parallel search (multi-threaded)", target: nil, action: nil)
    private let resultsCacheCheck   = NSButton(checkboxWithTitle: "Cache search results",  target: nil, action: nil)
    private let cacheLinesStepper   = NSStepper()
    private let cacheLinesField     = NSTextField()
    private let indexBufStepper     = NSStepper()
    private let indexBufField       = NSTextField()

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false

        tabView.addTabViewItem(makeDisplayTab())
        tabView.addTabViewItem(makeSearchTab())
        tabView.addTabViewItem(makeBehaviorTab())
        tabView.addTabViewItem(makePerfTab())

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closePanel(_:)))
        closeBtn.keyEquivalent = "\r"
        let btnRow = NSStackView(views: [NSView(), closeBtn])
        btnRow.distribution = .fill

        let mainStack = NSStackView(views: [tabView, btnRow])
        mainStack.orientation = .vertical
        mainStack.spacing     = 10
        mainStack.edgeInsets  = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: content.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        loadValues()
        wireActions()

    }

    // MARK: - Tab builders

    private func makeDisplayTab() -> NSTabViewItem {
        let item = NSTabViewItem(); item.label = "Display"

        fontFamilyField.placeholderString = "System monospaced (leave blank)"
        fontFamilyField.toolTip           = "Monospaced font family; blank = system default"
        fontSizeField.formatter           = intFormatter(min: 6, max: 72)

        func lbl(_ s: String) -> NSTextField { let f = NSTextField(labelWithString: s); f.alignment = .right; return f }

        let grid = NSGridView(views: [
            [lbl("Font family:"), fontFamilyField],
            [lbl("Font size:"),   fontSizeField],
        ])
        grid.column(at: 0).width = 90
        grid.rowSpacing    = 8
        grid.columnSpacing = 8

        let stack = NSStackView(views: [
            grid, wrapCheck, boldFontCheck, hideAnsiCheck,
            NSBox().asSep(),
            lineNumMainCheck, lineNumFiltCheck, NSView(),
        ])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        item.view = stack
        return item
    }

    private func makeSearchTab() -> NSTabViewItem {
        let item = NSTabViewItem(); item.label = "Search"

        let typeLbl = NSTextField(labelWithString: "Default search type:")
        typeLbl.font = .systemFont(ofSize: 13)

        func lbl(_ s: String) -> NSTextField { let f = NSTextField(labelWithString: s); f.alignment = .right; return f }
        searchHistoryField.formatter = intFormatter(min: 1, max: 1000)
        recentFilesField.formatter   = intFormatter(min: 1, max: 25)
        let histRow = NSStackView(views: [lbl("Search history size:"), searchHistoryField])
        histRow.spacing = 8
        let recentRow = NSStackView(views: [lbl("Recent files kept:"), recentFilesField])
        recentRow.spacing = 8

        let stack = NSStackView(views: [
            typeLbl, regexpTypeSegment,
            NSBox().asSep(),
            ignoreCaseCheck, autoRefreshCheck, autoRunCheck,
            highlightMainCheck, variateHlCheck, incrementalCheck,
            NSBox().asSep(),
            histRow, recentRow, NSView(),
        ])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        item.view = stack
        return item
    }

    private func makeBehaviorTab() -> NSTabViewItem {
        let item = NSTabViewItem(); item.label = "Behavior"

        // Polling interval row
        let intervalLbl = NSTextField(labelWithString: "Polling interval (ms):")
        pollIntervalField.formatter    = intFormatter(min: 10, max: 3_600_000)
        pollIntervalField.stringValue  = "500"
        let pollRow = NSStackView(views: [intervalLbl, pollIntervalField])
        pollRow.spacing = 8

        let stack = NSStackView(views: [
            loadLastCheck, followLoadCheck,
            NSBox().asSep(),
            nativeWatchCheck, pollingCheck, pollRow, followScrollCheck, NSView(),
        ])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        item.view = stack
        return item
    }

    private func makePerfTab() -> NSTabViewItem {
        let item = NSTabViewItem(); item.label = "Performance"

        cacheLinesStepper.minValue       = 100_000
        cacheLinesStepper.maxValue       = 10_000_000
        cacheLinesStepper.increment      = 100_000
        cacheLinesField.formatter        = intFormatter(min: 100_000, max: 10_000_000)
        cacheLinesField.stringValue      = "1000000"

        indexBufStepper.minValue         = 1
        indexBufStepper.maxValue         = 1024
        indexBufStepper.increment        = 1
        indexBufField.formatter          = intFormatter(min: 1, max: 1024)
        indexBufField.stringValue        = "64"

        func lbl(_ s: String) -> NSTextField { let f = NSTextField(labelWithString: s); f.alignment = .right; return f }

        let cacheRow = NSStackView(views: [lbl("Cache lines:"), cacheLinesField, cacheLinesStepper])
        cacheRow.spacing = 4
        let indexRow = NSStackView(views: [lbl("Index buffer (MB):"), indexBufField, indexBufStepper])
        indexRow.spacing = 4

        let stack = NSStackView(views: [
            parallelSearchCheck, resultsCacheCheck, cacheRow, indexRow, NSView(),
        ])
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        item.view = stack
        return item
    }

    // MARK: - Load / apply

    /// Called when window appears; also called by showWindow(_:) via NSWindowController.
    override func showWindow(_ sender: Any?) {
        loadValues()
        super.showWindow(sender)
    }

    private func loadValues() {
        let p = AppPreferences.shared

        fontFamilyField.stringValue      = p.fontFamily
        fontSizeField.integerValue       = p.fontSize
        wrapCheck.state                  = p.useTextWrap          ? .on : .off
        boldFontCheck.state              = p.useBoldFont          ? .on : .off
        hideAnsiCheck.state              = p.hideAnsiColors       ? .on : .off
        lineNumMainCheck.state           = p.lineNumbersInMain    ? .on : .off
        lineNumFiltCheck.state           = p.lineNumbersInFiltered ? .on : .off

        regexpTypeSegment.selectedSegment = p.mainRegexpType == 1 ? 1 : 0
        ignoreCaseCheck.state            = p.searchIgnoreCase     ? .on : .off
        autoRefreshCheck.state           = p.searchAutoRefresh    ? .on : .off
        autoRunCheck.state               = p.autoRunSearch        ? .on : .off
        highlightMainCheck.state         = p.highlightSearchInMain ? .on : .off
        variateHlCheck.state             = p.variateHighlightColors ? .on : .off
        incrementalCheck.state           = p.quickfindIncremental ? .on : .off
        searchHistoryField.integerValue  = p.searchHistorySize
        recentFilesField.integerValue    = p.recentFilesMaxItems

        loadLastCheck.state              = p.loadLastSession      ? .on : .off
        followLoadCheck.state            = p.followFileOnLoad     ? .on : .off
        nativeWatchCheck.state           = p.nativeFileWatch      ? .on : .off
        pollingCheck.state               = p.pollingEnabled       ? .on : .off
        pollIntervalField.integerValue   = p.pollIntervalMs
        followScrollCheck.state          = p.allowFollowOnScroll  ? .on : .off

        parallelSearchCheck.state        = p.useParallelSearch    ? .on : .off
        resultsCacheCheck.state          = p.useSearchResultsCache ? .on : .off
        cacheLinesField.integerValue     = p.searchResultsCacheLines
        cacheLinesStepper.intValue       = Int32(p.searchResultsCacheLines)
        indexBufField.integerValue       = p.indexReadBufferSizeMb
        indexBufStepper.intValue         = Int32(p.indexReadBufferSizeMb)
    }

    private func wireActions() {
        let checks: [NSButton] = [
            wrapCheck, boldFontCheck, hideAnsiCheck, lineNumMainCheck, lineNumFiltCheck,
            ignoreCaseCheck, autoRefreshCheck, autoRunCheck, highlightMainCheck, incrementalCheck,
            variateHlCheck,
            loadLastCheck, followLoadCheck, nativeWatchCheck, pollingCheck, followScrollCheck,
            parallelSearchCheck, resultsCacheCheck,
        ]
        for btn in checks { btn.target = self; btn.action = #selector(checkChanged(_:)) }

        regexpTypeSegment.target = self
        regexpTypeSegment.action = #selector(regexpTypeChanged(_:))

        for tf: NSTextField in [fontFamilyField, fontSizeField, pollIntervalField,
                                 cacheLinesField, indexBufField,
                                 searchHistoryField, recentFilesField] {
            tf.target = self
            tf.action = #selector(textChanged(_:))
        }

        cacheLinesStepper.target = self; cacheLinesStepper.action = #selector(stepperChanged(_:))
        indexBufStepper.target   = self; indexBufStepper.action   = #selector(stepperChanged(_:))
    }

    // MARK: - Actions

    @objc private func checkChanged(_ sender: NSButton) {
        let on = sender.state == .on
        let p  = AppPreferences.shared
        switch sender {
        case wrapCheck:          p.useTextWrap            = on
        case boldFontCheck:      p.useBoldFont            = on
        case hideAnsiCheck:      p.hideAnsiColors         = on
        case lineNumMainCheck:   p.lineNumbersInMain      = on
        case lineNumFiltCheck:   p.lineNumbersInFiltered  = on
        case ignoreCaseCheck:    p.searchIgnoreCase       = on
        case autoRefreshCheck:   p.searchAutoRefresh      = on
        case autoRunCheck:       p.autoRunSearch          = on
        case highlightMainCheck: p.highlightSearchInMain  = on
        case variateHlCheck:     p.variateHighlightColors = on
        case incrementalCheck:   p.quickfindIncremental   = on
        case loadLastCheck:      p.loadLastSession        = on
        case followLoadCheck:    p.followFileOnLoad       = on
        case nativeWatchCheck:   p.nativeFileWatch        = on
        case pollingCheck:       p.pollingEnabled         = on
        case followScrollCheck:  p.allowFollowOnScroll    = on
        case parallelSearchCheck: p.useParallelSearch     = on
        case resultsCacheCheck:  p.useSearchResultsCache  = on
        default: break
        }
    }

    @objc private func regexpTypeChanged(_ sender: NSSegmentedControl) {
        AppPreferences.shared.mainRegexpType = sender.selectedSegment
    }

    @objc private func textChanged(_ sender: NSTextField) {
        let p = AppPreferences.shared
        switch sender {
        case fontFamilyField:   p.fontFamily              = sender.stringValue
        case fontSizeField:     p.fontSize                = max(6, min(72, sender.integerValue))
        case pollIntervalField: p.pollIntervalMs          = max(10, sender.integerValue)
        case cacheLinesField:
            let v = max(100_000, sender.integerValue)
            p.searchResultsCacheLines = v
            cacheLinesStepper.intValue = Int32(v)
        case indexBufField:
            let v = max(1, min(1024, sender.integerValue))
            p.indexReadBufferSizeMb = v
            indexBufStepper.intValue = Int32(v)
        case searchHistoryField: p.searchHistorySize  = sender.integerValue
        case recentFilesField:   p.recentFilesMaxItems = sender.integerValue
        default: break
        }
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        let p = AppPreferences.shared
        if sender === cacheLinesStepper {
            let v = Int(sender.intValue)
            p.searchResultsCacheLines = v
            cacheLinesField.integerValue = v
        } else {
            let v = Int(sender.intValue)
            p.indexReadBufferSizeMb  = v
            indexBufField.integerValue = v
        }
    }

    @objc private func closePanel(_ sender: Any?) {
        window?.orderOut(nil)
    }

    // MARK: - Helpers

    private func intFormatter(min: Int, max: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.minimum = NSNumber(value: min)
        f.maximum = NSNumber(value: max)
        f.allowsFloats = false
        return f
    }
}

// MARK: - NSBox separator helper

private extension NSBox {
    func asSep() -> NSBox { boxType = .separator; return self }
}
