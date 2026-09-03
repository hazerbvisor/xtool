#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SRC_ROOT="$WORK_ROOT/src"
SWIFT_TOP="$SRC_ROOT/swift/CMakeLists.txt"
SWIFT_UUID="$SRC_ROOT/swift/cmake/modules/FindUUID.cmake"
SWIFT_BASIC="$SRC_ROOT/swift/lib/Basic/CMakeLists.txt"
CMARK_CMAKE="$SRC_ROOT/cmark/src/CMakeLists.txt"

[[ -f "$SWIFT_TOP" ]] || { echo "error: Swift CMakeLists.txt not found: $SWIFT_TOP" >&2; exit 1; }
[[ -f "$SWIFT_UUID" ]] || { echo "error: Swift FindUUID.cmake not found: $SWIFT_UUID" >&2; exit 1; }
[[ -f "$SWIFT_BASIC" ]] || { echo "error: Swift Basic CMakeLists.txt not found: $SWIFT_BASIC" >&2; exit 1; }
[[ -f "$CMARK_CMAKE" ]] || { echo "error: swift-cmark CMakeLists.txt not found: $CMARK_CMAKE" >&2; exit 1; }

python3 - "$SWIFT_TOP" "$SWIFT_UUID" "$SWIFT_BASIC" "$CMARK_CMAKE" <<'PY'
from pathlib import Path
import sys

top_file = Path(sys.argv[1])
uuid_file = Path(sys.argv[2])
basic_file = Path(sys.argv[3])
cmark_file = Path(sys.argv[4])

# XTool needs Swift's compiler libraries and SwiftCompilerSources, but not the
# command-line compiler executables. Keeping SWIFT_INCLUDE_TOOLS=ON is important
# because it also enables generated compiler headers and lib/, so gate only the
# final tools/ and localization subdirectories with our private build switch.
s = top_file.read_text()
old_tools = '  add_subdirectory(tools)'
new_tools = '  if(NOT XTOOL_FRONTEND_LIBRARY_ONLY)\n    add_subdirectory(tools)\n  endif()'
if new_tools in s:
    print('Swift executable tools gate: already applied')
elif old_tools in s:
    s = s.replace(old_tools, new_tools, 1)
    print('Swift executable tools gate: applied')
else:
    raise SystemExit('error: expected Swift tools subdirectory line not found')

old_localization = '  if(SWIFT_NATIVE_SWIFT_TOOLS_PATH)\n'
new_localization = '  if(SWIFT_NATIVE_SWIFT_TOOLS_PATH AND NOT XTOOL_FRONTEND_LIBRARY_ONLY)\n'
# Only replace the localization guard after our newly gated tools block.
anchor = new_tools
idx = s.find(anchor)
if idx < 0:
    raise SystemExit('error: Swift tools gate anchor missing')
head, tail = s[:idx], s[idx:]
if new_localization in tail:
    print('Swift localization tools gate: already applied')
elif old_localization in tail:
    tail = tail.replace(old_localization, new_localization, 1)
    s = head + tail
    print('Swift localization tools gate: applied')
else:
    raise SystemExit('error: expected Swift localization guard not found')
top_file.write_text(s)

# Swift 6.3.2 treats only CMAKE_SYSTEM_NAME=Darwin as an Apple platform.
# CMake uses CMAKE_SYSTEM_NAME=iOS for an iPhoneOS cross build, but UUID is
# supplied by the Apple SDK/libSystem and does not require Linux libuuid.
s = uuid_file.read_text()
old = 'if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")'
new = 'if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" OR CMAKE_SYSTEM_NAME STREQUAL "iOS")'
if new in s:
    print('Swift UUID iOS guard: already applied')
elif old in s:
    uuid_file.write_text(s.replace(old, new, 1))
    print('Swift UUID iOS guard: applied')
else:
    raise SystemExit('error: expected Swift UUID platform check not found')

# Swift Basic has a second platform check before it even calls FindUUID.
s = basic_file.read_text()
old = 'if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")\n  set(UUID_INCLUDE "")'
new = 'if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" OR CMAKE_SYSTEM_NAME STREQUAL "iOS")\n  set(UUID_INCLUDE "")'
if new in s:
    print('Swift Basic UUID iOS guard: already applied')
elif old in s:
    basic_file.write_text(s.replace(old, new, 1))
    print('Swift Basic UUID iOS guard: applied')
else:
    raise SystemExit('error: expected Swift Basic UUID platform check not found')

# CMake models iOS executables as bundles. swift-cmark's install rule omits a
# bundle destination, even though we never install it during this build.
s = cmark_file.read_text()
needle = '  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}\n  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}'
replacement = '  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}\n  BUNDLE DESTINATION ${CMAKE_INSTALL_BINDIR}\n  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}'
if replacement in s:
    print('swift-cmark iOS bundle install rule: already applied')
elif needle in s:
    cmark_file.write_text(s.replace(needle, replacement, 1))
    print('swift-cmark iOS bundle install rule: applied')
else:
    raise SystemExit('error: expected swift-cmark install block not found')
PY
