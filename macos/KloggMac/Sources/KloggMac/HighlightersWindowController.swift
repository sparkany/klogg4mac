//
//  HighlightersWindowController.swift — NSPanel for editing highlighter rules.
//
//  Layout:
//    ┌──────────────────────────────────────────────────────┐
//    │  [+] [-] [↑] [↓]     table of rules (name column)  │
//    ├──────────────────────────────────────────────────────┤
//    │  Name: ___________________________________________   │
//    │  Pattern: _______________________________________ □ Regex  □ Ignore Case  │
//    │  Fore: [color well]   Back: [color well]   □ Match only  □ Enabled  │
//    ├──────────────────────────────────────────────────────┤
//    │                              [Cancel]   [OK]         │
//    └──────────────────────────────────────────────────────┘
//
//  Changes are staged locally and written to HighlighterStore only on OK.
//

import AppKit

final class HighlightersWindowController: NSWindowController {

    // Working copy; committed to store on OK.
    private var rules: [HighlighterRule] = []
    private var selectedRow: Int = -1

    // MARK: - Controls

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton    = NSButton(title: "+", target: nil, action: nil)
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private let upButton     = NSButton(title: "↑", target: nil, action: nil)
    private let downButton   = NSButton(title: "↓", target: nil, action: nil)

    private let nameField      = NSTextField()
    private let patternField   = NSTextField()
    private let regexCheck     = NSButton(checkboxWithTitle: "Regex",       target: nil, action: nil)
    private let caseCheck      = NSButton(checkboxWithTitle: "Ignore case", target: nil, action: nil)
    private let matchOnlyCheck = NSButton(checkboxWithTitle: "Match only",  target: nil, action: nil)
    private let enabledCheck   = NSButton(checkboxWithTitle: "Enabled",     target: nil, action: nil)
    private let foreWell       = NSColorWell()
    private let backWell       = NSColorWell()

    // MARK: - Init

    init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        win.title = "Highlighters"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildUI()
        loadFromStore()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // ── Table ──
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule"))
        col.title = "Rule"
        col.isEditable = false
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        // ── Toolbar buttons ──
        for btn in [addButton, removeButton, upButton, downButton] {
            btn.bezelStyle = .smallSquare
            btn.font = .systemFont(ofSize: 11)
        }
        addButton.action    = #selector(addRule(_:))
        removeButton.action = #selector(removeRule(_:))
        upButton.action     = #selector(moveRuleUp(_:))
        downButton.action   = #selector(moveRuleDown(_:))
        for btn in [addButton, removeButton, upButton, downButton] { btn.target = self }

        let btnStack = NSStackView(views: [addButton, removeButton, upButton, downButton])
        btnStack.spacing = 2

        // ── Form fields ──
        nameField.placeholderString = "Display name"
        patternField.placeholderString = "Pattern"
        foreWell.frame = NSRect(x: 0, y: 0, width: 44, height: 22)
        backWell.frame = NSRect(x: 0, y: 0, width: 44, height: 22)

        // Label
        func label(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.alignment = .right
            return f
        }

        let nameLbl    = label("Name:")
        let patternLbl = label("Pattern:")
        let foreLbl    = label("Fore:")
        let backLbl    = label("Back:")

        // ── OK / Cancel ──
        let okBtn     = NSButton(title: "OK",     target: self, action: #selector(okClicked(_:)))
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        okBtn.keyEquivalent = "\r"

        // ── Layout ──
        let leftW: CGFloat = 60
        let formGrid = NSGridView(views: [
            [nameLbl,    nameField,    NSGridCell.emptyContentView, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [patternLbl, patternField, regexCheck, caseCheck, NSGridCell.emptyContentView],
            [foreLbl,    foreWell,     backLbl,    backWell,   NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, matchOnlyCheck, enabledCheck, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
        ])
        formGrid.column(at: 0).width = leftW
        formGrid.rowSpacing = 6
        formGrid.columnSpacing = 8

        let btnRow = NSStackView(views: [NSView(), cancelBtn, okBtn])
        btnRow.distribution = .fill
        btnRow.spacing = 8

        let divider = NSBox()
        divider.boxType = .separator

        let tableArea = NSStackView(views: [btnStack, scrollView])
        tableArea.orientation = .vertical
        tableArea.spacing = 4

        let mainStack = NSStackView(views: [tableArea, divider, formGrid, btnRow])
        mainStack.orientation = .vertical
        mainStack.spacing = 10
        mainStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: content.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])

        // Wire field changes.
        nameField.target = self;    nameField.action    = #selector(fieldEdited(_:))
        patternField.target = self; patternField.action = #selector(fieldEdited(_:))
        regexCheck.target = self;   regexCheck.action   = #selector(fieldEdited(_:))
        caseCheck.target = self;    caseCheck.action    = #selector(fieldEdited(_:))
        matchOnlyCheck.target = self; matchOnlyCheck.action = #selector(fieldEdited(_:))
        enabledCheck.target = self; enabledCheck.action = #selector(fieldEdited(_:))
        foreWell.target = self;     foreWell.action     = #selector(colorChanged(_:))
        backWell.target = self;     backWell.action     = #selector(colorChanged(_:))
    }

    // MARK: - Data loading

    private func loadFromStore() {
        rules = HighlighterStore.shared.rules
        tableView.reloadData()
        selectRow(rules.isEmpty ? -1 : 0)
    }

    private func selectRow(_ row: Int) {
        selectedRow = row
        if row >= 0 && row < rules.count {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            populateForm(from: rules[row])
            setFormEnabled(true)
        } else {
            tableView.deselectAll(nil)
            clearForm()
            setFormEnabled(false)
        }
        updateButtonStates()
    }

    private func populateForm(from rule: HighlighterRule) {
        nameField.stringValue    = rule.name
        patternField.stringValue = rule.pattern
        regexCheck.state         = rule.useRegex     ? .on : .off
        caseCheck.state          = rule.ignoreCase   ? .on : .off
        matchOnlyCheck.state     = rule.matchOnly    ? .on : .off
        enabledCheck.state       = rule.enabled      ? .on : .off
        foreWell.color           = rule.foreColor
        backWell.color           = rule.backColor
    }

    private func clearForm() {
        nameField.stringValue    = ""
        patternField.stringValue = ""
        regexCheck.state         = .off
        caseCheck.state          = .off
        matchOnlyCheck.state     = .off
        enabledCheck.state       = .on
        foreWell.color           = .labelColor
        backWell.color           = .yellow
    }

    private func setFormEnabled(_ on: Bool) {
        for v: NSControl in [nameField, patternField, regexCheck, caseCheck,
                              matchOnlyCheck, enabledCheck, foreWell, backWell] {
            v.isEnabled = on
        }
    }

    private func updateButtonStates() {
        removeButton.isEnabled = selectedRow >= 0
        upButton.isEnabled     = selectedRow > 0
        downButton.isEnabled   = selectedRow >= 0 && selectedRow < rules.count - 1
    }

    // MARK: - Actions

    @objc private func addRule(_ sender: Any?) {
        let rule = HighlighterRule(name: "New rule")
        rules.append(rule)
        tableView.reloadData()
        selectRow(rules.count - 1)
    }

    @objc private func removeRule(_ sender: Any?) {
        guard selectedRow >= 0, selectedRow < rules.count else { return }
        rules.remove(at: selectedRow)
        tableView.reloadData()
        selectRow(min(selectedRow, rules.count - 1))
    }

    @objc private func moveRuleUp(_ sender: Any?) {
        guard selectedRow > 0 else { return }
        rules.swapAt(selectedRow, selectedRow - 1)
        tableView.reloadData()
        selectRow(selectedRow - 1)
    }

    @objc private func moveRuleDown(_ sender: Any?) {
        guard selectedRow < rules.count - 1 else { return }
        rules.swapAt(selectedRow, selectedRow + 1)
        tableView.reloadData()
        selectRow(selectedRow + 1)
    }

    @objc private func fieldEdited(_ sender: Any?) {
        guard selectedRow >= 0, selectedRow < rules.count else { return }
        applyFormToRule(at: selectedRow)
        // Refresh the table label when name changes.
        tableView.reloadData(forRowIndexes: IndexSet(integer: selectedRow),
                             columnIndexes: IndexSet(integer: 0))
    }

    @objc private func colorChanged(_ sender: NSColorWell?) {
        guard selectedRow >= 0 else { return }
        applyFormToRule(at: selectedRow)
        tableView.reloadData(forRowIndexes: IndexSet(integer: selectedRow),
                             columnIndexes: IndexSet(integer: 0))
    }

    private func applyFormToRule(at index: Int) {
        rules[index].name        = nameField.stringValue
        rules[index].pattern     = patternField.stringValue
        rules[index].useRegex    = regexCheck.state == .on
        rules[index].ignoreCase  = caseCheck.state  == .on
        rules[index].matchOnly   = matchOnlyCheck.state == .on
        rules[index].enabled     = enabledCheck.state   == .on
        rules[index].foreColorHex = foreWell.color.toArgbHex()
        rules[index].backColorHex = backWell.color.toArgbHex()
    }

    @objc private func okClicked(_ sender: Any?) {
        if selectedRow >= 0 { applyFormToRule(at: selectedRow) }
        HighlighterStore.shared.setRules(rules)
        window?.orderOut(nil)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        window?.orderOut(nil)
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension HighlightersWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ruleCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            ])
        }
        let rule = rules[row]
        cell.textField?.stringValue = rule.name.isEmpty ? "(unnamed)" : rule.name
        cell.textField?.textColor   = rule.enabled ? .labelColor : .disabledControlTextColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedRow = row
        if row >= 0, row < rules.count {
            populateForm(from: rules[row])
            setFormEnabled(true)
        } else {
            clearForm()
            setFormEnabled(false)
        }
        updateButtonStates()
    }
}

// MARK: - NSColor helper (used by applyFormToRule)

private extension NSColor {
    func toArgbHex() -> String {
        guard let c = usingColorSpace(.deviceRGB) else { return "#FFEEEEEE" }
        let a = Int(c.alphaComponent * 255)
        let r = Int(c.redComponent   * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent  * 255)
        return String(format: "#%02X%02X%02X%02X", a, r, g, b)
    }
}
