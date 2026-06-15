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

The UI layer never sees a Qt type. The engine (logdata / regex / settings / …)
is linked as static libs; the Objective-C++ bridge owns the C++ objects and exposes
only Foundation types (NSString / NSRange / delegate callbacks) to Swift.

## Toolchain

- Xcode 26+ (Swift 6, arm64)
- CMake 3.5+, Ninja
- Qt 6 + Qt6Core5Compat — `brew install qt`
- Ragel — `brew install ragel` (needed to build the vectorscan regex backend)
- Boost — `brew install boost`
- pkg-config — `brew install pkg-config`
- vectorscan / TBB / uchardet / xxhash are fetched automatically by CPM at configure time

## Build — C++ engine static libraries

Must be done before the SwiftPM build:

```sh
cmake -S . -B build-arm64 -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBOOST_ROOT="$(brew --prefix boost)" \
  -DKLOGG_USE_HYPERSCAN=OFF -DKLOGG_USE_VECTORSCAN=ON \
  -DKLOGG_BUILD_TESTS=OFF -DKLOGG_USE_LTO=OFF -DWARNINGS_AS_ERRORS=OFF
cmake --build build-arm64 --target klogg_logdata
```

Static libs produced in `build-arm64/output/`:
- `libklogg_logdata.a`, `libklogg_regex.a`, `libklogg_settings.a`
- `libklogg_filewatch.a`, `libklogg_logging.a`, `libklogg_utils.a`
- `libklogg_crash_handler.a`, `libklogg_version.a`
- Third-party: `libmimalloc.a`, `libroaring.a`, `libsimdutf.a`, `libstreamvbyte.a`,
  `libuchardet.a`, `libxxhash.a`, `libefsw.a`, `libkdtoolbox.a`, `libwhereami.a`
- `build-arm64/appleclang_21.0_cxx17_64_release/libtbb.a`
- `build-arm64/_deps/vectorscan-build/lib/libhs.a`

## Build — native AppKit app (with real engine)

```sh
cd macos/KloggMac
swift build
swift run KloggMac      # opens a native window with real engine
```

The app opens; use **File → Open…** (Cmd+O) to open any log file.

> Note: `Package.swift` uses `unsafeFlags` to pass the include paths and static
> lib paths to SwiftPM's C++ compilation and link steps. This is required because
> SwiftPM has no native `systemIncludePaths` or `linkedLibrary(static:)` directive
> for framework search paths and system include dirs. This prevents the package from
> being used as a SwiftPM dependency — acceptable for an end-product application.

## Threading model (KloggBridge)

```
Cocoa main thread (NSRunLoop)
  ↕ performSelector:onThread:waitUntilDone:
KloggQtEventLoop thread (NSThread + QCoreApplication::exec())
  owns: LogData, QObject context
  receives: Qt queued-connection signals from worker threads
  dispatches: callbacks to Cocoa main queue via dispatch_async
```

- `LogData` lives on the Qt thread; signal delivery works without MOC in bridge code
  because we use the functor overload of `QObject::connect` with an explicit context.
- `PersistentInfo::ForcePortable = false` is defined in `KloggBridge.mm` (required
  once per binary; in klogg it was in `main.cpp`).
- `searchWithPattern` is a TODO stub (returns 0 matches immediately); LogFilteredData
  integration is tracked for Phase 3.

## Status

- [x] Native AppKit shell builds & runs (`swift run`)
- [x] Bridge facade contract defined (`KloggBridge.h`)
- [x] C++ engine builds clean on arm64 (logdata/regex/settings/utils/logging/filewatch + vectorscan)
- [x] Bridge wired to the real engine (Phase 1 complete)
- [ ] Phase 1: log view scroll/render parity with klogg (in progress, owned by `logview`)
- [ ] Phase 3: search — LogFilteredData integration

## Notes from bringing up the arm64 engine (Xcode 26 toolchain)

- `src/logdata/include/linetypes.h`: removed the deprecated space in user-defined
  literal operators (`operator"" _x` -> `operator""_x`) — C++23 deprecation.
- Build with `-DWARNINGS_AS_ERRORS=OFF`: klogg's very strict warning set + the newer
  Clang surfaces many benign deprecations across the engine; treating them as errors
  blocks the build. Modernizing the rest is tracked as later cleanup, not Phase 0.
- Required brew deps discovered: `qt`, `ragel`, `boost`, `pkg-config`.
- `PersistentInfo::ForcePortable` is a `static const bool` that must be defined in
  the final binary (not in any engine lib). We define it in `KloggBridge.mm`.
- `libklogg_settings.a` pulls in `QtWidgets` symbols (`QMessageBox`, `QFont`,
  `QApplication`, `QStyleFactory`) via `styles.cpp` and `issuereporter.cpp`, so
  `QtWidgets` and `QtGui` frameworks must also be linked even though our UI is native.
- SwiftPM manifest type-checker times out on a single large array literal; break
  include/link flags into named `[CXXSetting]` / `[LinkerSetting]` variables.
- Engine was built targeting macOS 26.0 (Xcode 26 toolchain default); set
  `platforms: [ .macOS("26.0") ]` in Package.swift to silence linker version warnings.
