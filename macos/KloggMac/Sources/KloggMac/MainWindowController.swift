//
//  MainWindowController.swift — main window + central split (Phase 2 host).
//
//  Mirrors klogg's crawlerwidget layout: a vertical split with the main log view
//  on top and the filtered (search results) view below. Both are LogScrollView
//  instances backed by the engine. This is the skeleton the `shell`/`logview`/
//  `search` roles flesh out.
//

import AppKit
import KloggBridge

final class MainWindowController: NSWindowController, KloggEngineDelegate {

    private let engine = KloggEngine()
    private var mainView: LogScrollView!
    private var filteredView: LogScrollView!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = KloggEngine.isStub ? "klogg4mac (stub engine)" : "klogg4mac"
        window.center()
        super.init(window: window)
        engine.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func buildContent() {
        mainView = LogScrollView(engine: engine)
        filteredView = LogScrollView(engine: engine)

        let split = NSSplitView()
        split.isVertical = false          // stacked: main above, filtered below
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(mainView)
        split.addArrangedSubview(filteredView)

        let content = window!.contentView!
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    // MARK: - Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.engine.openFile(atPath: url.path)
        }
    }

    // MARK: - KloggEngineDelegate

    func kloggEngine(_ engine: Any, loadingFinished success: Bool) {
        mainView.reloadFromEngine()
    }
}
