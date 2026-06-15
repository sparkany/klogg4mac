// swift-tools-version:5.9
import PackageDescription

// KloggMac — native AppKit shell for klogg4mac.
//
// Phase 0 layout:
//   - KloggBridge : Objective-C++ facade over the C++ engine. Compiles in STUB
//                   mode today (no Qt needed) so the AppKit shell builds & runs.
//                   When the engine static lib is available, build with the real
//                   path (see macos/README.md) and drop -DKLOGG_BRIDGE_STUB.
//   - KloggMac    : AppKit (Swift) application: window, menus, log view PoC.
let package = Package(
    name: "KloggMac",
    platforms: [ .macOS(.v13) ],
    targets: [
        .target(
            name: "KloggBridge",
            // Stub mode: no engine/Qt dependency yet. Remove this define and add
            // the engine include path + linker flags to wire the real engine.
            cSettings: [ .define("KLOGG_BRIDGE_STUB") ],
            cxxSettings: [ .define("KLOGG_BRIDGE_STUB") ]
        ),
        .executableTarget(
            name: "KloggMac",
            dependencies: [ "KloggBridge" ]
            // The bridge exposes a pure Obj-C/Foundation surface, so Swift needs
            // no C++ interop here — that complexity stays inside KloggBridge.
        ),
    ],
    cxxLanguageStandard: .cxx17
)
