#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SWIFT_COMPILER_SOURCES_CMAKE="$WORK_ROOT/src/swift/SwiftCompilerSources/CMakeLists.txt"

[[ -f "$SWIFT_COMPILER_SOURCES_CMAKE" ]] || {
  echo "error: SwiftCompilerSources CMakeLists.txt not found: $SWIFT_COMPILER_SOURCES_CMAKE" >&2
  exit 1
}

python3 - "$SWIFT_COMPILER_SOURCES_CMAKE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

anchor = '''  set(sdk_option ${SWIFT_COMPILER_SOURCES_SDK_FLAGS})
'''
patch = '''  set(sdk_option ${SWIFT_COMPILER_SOURCES_SDK_FLAGS})

  # XTool Mobile cross-build fix: SwiftCompilerSources is compiled by the
  # Linux-hosted swiftc but targets iPhoneOS. CMake's custom Swift compiler
  # source rule does not inherit CMAKE_Swift_FLAGS, so without an explicit
  # Darwin resource directory it falls back to the SDK Swift.swiftinterface
  # and cannot resolve SwiftShims. Derive the extracted Xcode toolchain from
  # the iPhoneOS SDK path and mirror the already-working Linux -> iOS frontend
  # resource/include setup.
  if(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND XTOOL_FRONTEND_LIBRARY_ONLY)
    get_filename_component(
      xtool_darwin_developer
      "${sdk_path}/../../../../.."
      ABSOLUTE
    )
    set(
      xtool_darwin_swift_resources
      "${xtool_darwin_developer}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
    )
    list(APPEND sdk_option
      "-resource-dir" "${xtool_darwin_swift_resources}"
      "-I" "${xtool_darwin_swift_resources}/iphoneos"
      "-I" "${sdk_path}/../../usr/lib"
      "-Xcc" "-isystem"
      "-Xcc" "${xtool_darwin_swift_resources}/clang/include"
    )
  endif()
'''

if patch in s:
    print('SwiftCompilerSources Darwin resource-dir fix: already applied')
elif anchor in s:
    p.write_text(s.replace(anchor, patch, 1))
    print('SwiftCompilerSources Darwin resource-dir fix: applied')
else:
    raise SystemExit('error: expected SwiftCompilerSources sdk_option anchor not found')
PY
