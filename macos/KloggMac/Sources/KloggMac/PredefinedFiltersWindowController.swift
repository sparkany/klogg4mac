//
//  PredefinedFiltersWindowController.swift — NSPanel to manage named search filters.
//
//  Layout:
//    ┌──────────────────────────────────────────┐
//    │ [+] [-]    table: Name | Pattern         │
//    ├──────────────────────────────────────────┤
//    │ Name: ____________________________________│
//    │ Pattern: __________________________  □ Regex  □ Ignore case │
//    ├──────────────────────────────────────────┤
//    │                       [Cancel]   [OK]    │
//    └──────────────────────────────────────────┘
//

import AppKit

final class PredefinedFiltersWindowController: NSWindowController {

    private var filters: [PredefinedFilter] = []
    private var selectedRow: Int = -1

    // Controls
    private let tableView    = NSTableView()
    private let scrollView   = NSScrollView()
    private let addButton    = NSButton(title: "+", target: nil, action: nil)
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private let nameField    = NSTextField()
    private let patternField = NSTextField()
    private let regexCheck   = NSButton(checkboxWithTitle: "Regex",       target: nil, action: nil)
    private let caseCheck    = NSButton(checkboxWithTitle: "Ignore case", target: nil, action: nil)

    // MARK: - Init

    init() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        win.title = "Predefined Filters"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildUI()
        loadFromStore()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Table with two columns.
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 140
        let patternCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pattern"))
        patternCol.title = "Pattern"
        patternCol.width = 280
        tableView.addTableColumn(nameCol)
        tableView.addTableColumn(patternCol)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        addButton.bezelStyle    = .smallSquare
        removeButton.bezelStyle = .smallSquare
        addButton.action    = #selector(addFilter(_:));    addButton.target    = self
        removeButton.action = #selector(removeFilter(_:)); removeButton.target = self

        let btnRow = NSStackView(views: [addButton, removeButton])
        btnRow.spacing = 2

        nameField.placeholderString    = "Filter name"
        patternField.placeholderString = "Pattern"

        func label(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.alignment = .right
            return f
        }

        let formGrid = NSGridView(views: [
            [label("Name:"),    nameField,    NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Pattern:"), patternField, regexCheck, caseCheck],
        ])
        formGrid.column(at: 0).width = 60
        formGrid.rowSpacing  = 6
        formGrid.columnSpacing = 8

        let okBtn     = NSButton(title: "OK",     target: self, action: #selector(okClicked(_:)))
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        okBtn.keyEquivalent = "\r"

        let actionRow = NSStackView(views: [NSView(), cancelBtn, okBtn])
        actionRow.distribution = .fill
        actionRow.spacing = 8

        let divider = NSBox(); divider.boxType = .separator

        let tableArea = NSStackView(views: [btnRow, scrollView])
        tableArea.orientation = .vertical
        tableArea.spacing = 4

        let mainStack = NSStackView(views: [tableArea, divider, formGrid, actionRow])
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
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        for ctrl: NSControl in [nameField, patternField, regexCheck, caseCheck] {
            ctrl.target = self
            ctrl.action = #selector(fieldEdited(_:))
        }
    }

    private func loadFromStore() {
        filters = PredefinedFilterStore.shared.filters
        tableView.reloadData()
        selectRow(filters.isEmpty ? -1 : 0)
    }

    private func selectRow(_ row: Int) {
        selectedRow = row
        if row >= 0, row < filters.count {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            populateForm(from: filters[row])
            setFormEnabled(true)
        } else {
            tableView.deselectAll(nil)
            clearForm()
            setFormEnabled(false)
        }
        removeButton.isEnabled = row >= 0
    }

    private func populateForm(from f: PredefinedFilter) {
        nameField.stringValue    = f.name
        patternField.stringValue = f.pattern
        regexCheck.state         = f.useRegex   ? .on : .off
        caseCheck.state          = f.ignoreCase ? .on : .off
    }

    private func clearForm() {
        nameField.stringValue    = ""
        patternField.stringValue = ""
        regexCheck.state         = .on
        caseCheck.state          = .off
    }

    private func setFormEnabled(_ on: Bool) {
        for v: NSControl in [nameField, patternField, regexCheck, caseCheck] { v.isEnabled = on }
    }

    // MARK: - Actions

    @objc private func addFilter(_ sender: Any?) {
        filters.append(PredefinedFilter(name: "New filter"))
        tableView.reloadData()
        selectRow(filters.count - 1)
    }

    @objc private func removeFilter(_ sender: Any?) {
        guard selectedRow >= 0, selectedRow < filters.count else { return }
        filters.remove(at: selectedRow)
        tableView.reloadData()
        selectRow(min(selectedRow, filters.count - 1))
    }

    @objc private func fieldEdited(_ sender: Any?) {
        guard selectedRow >= 0, selectedRow < filters.count else { return }
        filters[selectedRow].name        = nameField.stringValue
        filters[selectedRow].pattern     = patternField.stringValue
        filters[selectedRow].useRegex    = regexCheck.state == .on
        filters[selectedRow].ignoreCase  = caseCheck.state  == .on
        tableView.reloadData(forRowIndexes: IndexSet(integer: selectedRow),
                             columnIndexes: IndexSet(integersIn: 0...1))
    }

    @objc private func okClicked(_ sender: Any?) {
        if selectedRow >= 0 { fieldEdited(nil) }
        PredefinedFilterStore.shared.setFilters(filters)
        window?.orderOut(nil)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        window?.orderOut(nil)
    }

    // MARK: - Self-test hooks (headless QA)

    /// Drive the editor's real add → edit → commit path and persist to the store.
    /// Returns the committed filter count.
    @discardableResult
    func selfTestAddFilter(name: String, pattern: String,
                           useRegex: Bool, ignoreCase: Bool) -> Int {
        window?.contentView?.layoutSubtreeIfNeeded()
        addFilter(nil)
        nameField.stringValue    = name
        patternField.stringValue = pattern
        regexCheck.state         = useRegex   ? .on : .off
        caseCheck.state          = ignoreCase ? .on : .off
        fieldEdited(nil)
        okClicked(nil)
        return PredefinedFilterStore.shared.filters.count
    }

    /// Delete the filter at `index` and commit; returns the new committed count.
    @discardableResult
    func selfTestDeleteFilter(at index: Int) -> Int {
        window?.contentView?.layoutSubtreeIfNeeded()
        loadFromStore()
        selectRow(index)
        removeFilter(nil)
        okClicked(nil)
        return PredefinedFilterStore.shared.filters.count
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension PredefinedFiltersWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { filters.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let colID = tableColumn?.identifier.rawValue ?? ""
        let id = NSUserInterfaceItemIdentifier("filterCell_\(colID)")
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
        let f = filters[row]
        cell.textField?.stringValue = colID == "name" ? f.name : f.pattern
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedRow = row
        if row >= 0, row < filters.count {
            populateForm(from: filters[row])
            setFormEnabled(true)
        } else {
            clearForm()
            setFormEnabled(false)
        }
        removeButton.isEnabled = row >= 0
    }
}
