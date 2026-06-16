// swift-tools-version:5.9
import PackageDescription
import Foundation

// KloggMac -- native AppKit shell for klogg4mac.
//
// KloggBridge now links the real klogg C++ engine (LogData / AbstractLogData)
// via static libraries built in build-arm64/. Run the CMake build first:
//
//   cmake -S . -B build-arm64 -G Ninja \
//     -DCMAKE_BUILD_TYPE=Release \
//     -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" \
//     -DCMAKE_OSX_ARCHITECTURES=arm64 \
//     -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
//     -DBOOST_ROOT="$(brew --prefix boost)" \
//     -DKLOGG_USE_HYPERSCAN=OFF -DKLOGG_USE_VECTORSCAN=ON \
//     -DKLOGG_BUILD_TESTS=OFF -DKLOGG_USE_LTO=OFF -DWARNINGS_AS_ERRORS=OFF
//   cmake --build build-arm64 --target klogg_logdata
//
// NOTE: unsafeFlags are required because SwiftPM has no native way to express
// framework search paths or -isystem include paths for C++ targets. This
// prevents the package from being used as a SwiftPM dependency, which is
// acceptable here -- this is an end-product application, not a library.

// Derive the repository root from this file's location (macos/KloggMac/).
let _repoRoot = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .path
let _buildDir  = _repoRoot + "/build-arm64"
let _outputDir = _buildDir + "/output"
let _depsDir   = _buildDir + "/_deps"
let _qtRoot    = "/opt/homebrew/opt/qt"

// Break up include flags into named arrays so the type-checker doesn't time out.
let _engineIncludes: [CXXSetting] = [
    .unsafeFlags([
        "-I", _repoRoot + "/src/logdata/include",
        "-I", _repoRoot + "/src/settings/include",
        "-I", _repoRoot + "/src/utils/include",
        "-I", _repoRoot + "/src/logging/include",
        "-I", _repoRoot + "/src/regex/include",
        "-I", _repoRoot + "/src/filewatch/include",
        "-I", _repoRoot + "/src/crash_handler/include",
        "-I", _repoRoot + "/src/klogg_version/include",
        "-I", _buildDir  + "/generated",
    ]),
]

let _depIncludes: [CXXSetting] = [
    .unsafeFlags([
        "-isystem", _depsDir + "/type_safe-src/include",
        "-isystem", _depsDir + "/type_safe-src/external/debug_assert",
        "-isystem", _depsDir + "/mimalloc-src/include",
        "-isystem", _depsDir + "/tbb-src/include",
        "-isystem", _depsDir + "/robin_hood-src/src/include",
        "-isystem", _depsDir + "/exprtk-src",
        "-isystem", _depsDir + "/efsw-src/include",
        "-isystem", _depsDir + "/efsw-src/src",
        "-isystem", _depsDir + "/croaring-src/include",
        "-isystem", _depsDir + "/croaring-src/cpp",
        "-isystem", _depsDir + "/uchardet-src/src",
        "-isystem", _depsDir + "/simdutf-src/include",
        "-isystem", _depsDir + "/streamvbyte-src/include",
        "-isystem", _depsDir + "/xxhash-src",
        "-isystem", _depsDir + "/vectorscan-src/src",
        "-isystem", _depsDir + "/vectorscan-build",
        "-isystem", _depsDir + "/kdtoolbox-src/qt/KDSignalThrottler/src",
    ]),
]

// liblzma (xz) ships its header only under Homebrew; zlib/bzlib are in the macOS SDK.
let _compressionIncludes: [CXXSetting] = [
    .unsafeFlags([
        "-isystem", "/opt/homebrew/opt/xz/include",
    ]),
]

let _qtIncludes: [CXXSetting] = [
    .unsafeFlags([
        "-F",       _qtRoot + "/lib",
        "-isystem", _qtRoot + "/lib/QtCore.framework/Headers",
        "-isystem", _qtRoot + "/lib/QtCore5Compat.framework/Headers",
        "-isystem", _qtRoot + "/lib/QtGui.framework/Headers",
        "-isystem", _qtRoot + "/lib/QtWidgets.framework/Headers",
        "-isystem", _qtRoot + "/lib/QtNetwork.framework/Headers",
        "-isystem", _qtRoot + "/lib/QtConcurrent.framework/Headers",
        "-isystem", _qtRoot + "/share/qt/mkspecs/macx-clang",
        "-isystem", _qtRoot + "/include",
    ]),
]

let _kloggLibs: [LinkerSetting] = [
    .unsafeFlags([
        _outputDir + "/libklogg_logdata.a",
        _outputDir + "/libklogg_regex.a",
        _outputDir + "/libklogg_settings.a",
        _outputDir + "/libklogg_filewatch.a",
        _outputDir + "/libklogg_logging.a",
        _outputDir + "/libklogg_utils.a",
        _outputDir + "/libklogg_crash_handler.a",
        _outputDir + "/libklogg_version.a",
    ]),
]

let _depLibs: [LinkerSetting] = [
    .unsafeFlags([
        _outputDir + "/libmimalloc.a",
        _outputDir + "/libroaring.a",
        _outputDir + "/libsimdutf.a",
        _outputDir + "/libstreamvbyte.a",
        _outputDir + "/libuchardet.a",
        _outputDir + "/libxxhash.a",
        _outputDir + "/libefsw.a",
        _outputDir + "/libkdtoolbox.a",
        _outputDir + "/libwhereami.a",
        _buildDir  + "/appleclang_21.0_cxx17_64_release/libtbb.a",
        _depsDir   + "/vectorscan-build/lib/libhs.a",
    ]),
]

let _qtLibs: [LinkerSetting] = [
    .unsafeFlags([
        "-F",         _qtRoot + "/lib",
        "-framework", "QtCore",
        "-framework", "QtCore5Compat",
        "-framework", "QtGui",
        "-framework", "QtWidgets",
        "-framework", "QtNetwork",
        "-framework", "QtConcurrent",
        "-framework", "Foundation",
        "-framework", "CoreFoundation",
        "-L", "/opt/homebrew/opt/xz/lib",
        "-lz",
        "-lbz2",
        "-llzma",
        "-liconv",
        "-lc++",
    ]),
]

let package = Package(
    name: "KloggMac",
    // Engine libs target macOS 26; match so the linker doesn't warn.
    platforms: [ .macOS("26.0") ],
    targets: [
        .target(
            name: "KloggBridge",
            cSettings: [
                // Must match the define used when building the engine static libs.
                .define("QT_NO_KEYWORDS"),
            ],
            cxxSettings: [.define("QT_NO_KEYWORDS")]
                + _engineIncludes
                + _depIncludes
                + _compressionIncludes
                + _qtIncludes,
            linkerSettings: _kloggLibs + _depLibs + _qtLibs
        ),
        .executableTarget(
            name: "KloggMac",
            dependencies: [ "KloggBridge" ]
            // The bridge exposes a pure Obj-C/Foundation surface; Swift needs
            // no C++ interop here -- all complexity stays inside KloggBridge.mm.
        ),
    ],
    cxxLanguageStandard: .cxx17
)
