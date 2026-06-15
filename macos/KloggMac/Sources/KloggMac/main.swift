//
//  main.swift — AppKit entry point for klogg4mac.
//
//  Phase-0 shell: brings up a real native window hosting the custom log view so we
//  can validate the AppKit foundation (and later, scroll/render performance) before
//  the C++ engine is linked. Run with `swift run` from macos/KloggMac.
//

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
