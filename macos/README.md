# klogg4mac — native macOS (AppKit) port

Native AppKit re-implementation of klogg's UI on top of the existing, proven C++
engine. See [`docs/native-macos/ROADMAP.md`](../docs/native-macos/ROADMAP.md) for
the architecture, team design, and phased plan.

## Layout

```
macos/
  KloggMac/           SwiftPM package — the AppKit application
    Sources/
      KloggBridge/    Objective-C++ facade over the C++ engine (pure Obj-C surface)
      KloggMac/       AppKit (Swift): window, menus, custom log view
  engine/             CMake aggregation -> libklogg_engine.a (the UI-free engine)
```

## Architecture rule

The UI layer never sees a Qt type. The engine (logdata / regex / settings / …,
QtCore-only, no QtGui/QtWidgets) is bundled into `libklogg_engine.a`; the
Objective-C++ bridge owns the C++ objects and exposes only Foundation types
(NSString / NSRange / delegate callbacks) to Swift.

## Toolchain

- Xcode 26+ (Swift 6, arm64)
- CMake 3.5+, Ninja
- Qt 6 + Qt6Core5Compat — `brew install qt`
- Ragel — `brew install ragel` (needed to build the vectorscan regex backend)
- vectorscan / TBB / uchardet / xxhash are fetched automatically by CPM at configure time

## Build — native app shell (today, stub engine)

The AppKit shell builds and runs against a stub engine (synthetic content), so UI
work needs no Qt:

```sh
cd macos/KloggMac
swift build
swift run KloggMac      # opens a native window
```

The bridge compiles in stub mode via the `KLOGG_BRIDGE_STUB` define in
`Package.swift`.

## Build — C++ engine static library

```sh
cmake -S . -B build-arm64 -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DKLOGG_USE_HYPERSCAN=OFF -DKLOGG_USE_VECTORSCAN=ON \
  -DKLOGG_BUILD_TESTS=OFF -DKLOGG_USE_LTO=OFF
cmake --build build-arm64 --target klogg_logdata
```

> Notes
> - On Apple Silicon, Hyperscan is x86-only — use Vectorscan (`KLOGG_USE_VECTORSCAN=ON`).
> - `CMAKE_POLICY_VERSION_MINIMUM=3.5` is required with CMake 4.x because some
>   vendored modules still declare an old `cmake_minimum_required`.

## Wiring the real engine into the bridge (next step)

1. Build `libklogg_engine.a` (above).
2. Drop `KLOGG_BRIDGE_STUB`; add the engine include paths + link the static libs
   and Qt6Core/Qt6Core5Compat to the `KloggBridge` target.
3. Replace the stub body in `KloggBridge.mm` with real `LogData` / `LogFilteredData`
   calls (signals marshalled to the main queue).

## Status (Phase 0)

- [x] Native AppKit shell builds & runs (`swift run`)
- [x] Bridge facade contract defined (`KloggBridge.h`)
- [x] C++ engine builds clean on arm64 (logdata/regex/settings/utils/logging/filewatch + vectorscan)
- [ ] Bridge wired to the real engine
- [ ] Phase 1: log view scroll/render parity with klogg

### Notes from bringing up the arm64 engine (Xcode 26 toolchain)

- `src/logdata/include/linetypes.h`: removed the deprecated space in user-defined
  literal operators (`operator"" _x` -> `operator""_x`) — C++23 deprecation.
- Build with `-DWARNINGS_AS_ERRORS=OFF`: klogg's very strict warning set + the newer
  Clang surfaces many benign deprecations across the engine; treating them as errors
  blocks the build. Modernizing the rest is tracked as later cleanup, not Phase 0.
- Required brew deps discovered: `qt`, `ragel`, `boost`, `pkg-config`.
