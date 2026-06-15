# macos/engine — aggregate the klogg C++ engine into a single static library.
#
# This does NOT replace the top-level build. It is added by the top-level
# CMakeLists (when -DKLOGG_BUILD_MACOS_ENGINE=ON) and bundles the UI-free engine
# targets that the native AppKit app links through the Objective-C++ bridge.
#
# Engine modules (no Qt GUI dependency — only QtCore + Core5Compat):
#   klogg_logdata  (transitively pulls regex, settings, utils, logging, filewatch)
#
# Output: libklogg_engine.a (+ the transitive klogg_* static libs it depends on).
# The bridge (macos/KloggMac/Sources/KloggBridge) links these and exposes a pure
# Foundation surface to Swift. See macos/README.md for the end-to-end build.

# An OBJECT-aggregating interface keeps things simple: depend on klogg_logdata and
# let CMake's normal static-lib linking pull the rest. The bridge target links
# `klogg_engine` and inherits include dirs + Qt transitively via PUBLIC usage.
add_library(klogg_engine INTERFACE)

target_link_libraries(klogg_engine INTERFACE
    klogg_logdata
    klogg_regex
    klogg_settings
    klogg_utils
    klogg_logging
    klogg_filewatch
)

# Re-export the engine public headers the bridge needs to include.
target_include_directories(klogg_engine INTERFACE
    "${CMAKE_SOURCE_DIR}/src/logdata/include"
    "${CMAKE_SOURCE_DIR}/src/regex/include"
    "${CMAKE_SOURCE_DIR}/src/settings/include"
    "${CMAKE_SOURCE_DIR}/src/utils/include"
)
