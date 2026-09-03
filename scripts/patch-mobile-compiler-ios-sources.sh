#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SRC_ROOT="$WORK_ROOT/src"
SWIFT_UUID="$SRC_ROOT/swift/cmake/modules/FindUUID.cmake"
SWIFT_BASIC="$SRC_ROOT/swift/lib/Basic/CMakeLists.txt"
CMARK_CMAKE="$SRC_ROOT/cmark/src/CMakeLists.txt"

[[ -f "$SWIFT_UUID" ]] || { echo "error: Swift FindUUID.cmake not found: $SWIFT_UUID" >&2; exit 1; }
[[ -f "$SWIFT_BASIC" ]] || { echo "error: Swift Basic CMakeLists.txt not found: $SWIFT_BASIC" >&2; exit 1; }
[[ -f "$CMARK_CMAKE" ]] || { echo "error: swift-cmark CMakeLists.txt not found: $CMARK_CMAKE" >&2; exit 1; }

python3 - "$SWIFT_UUID" "$SWIFT_BASIC" "$CMARK_CMAKE" <<'PY'
from pathlib import Path
import sys

uuid_file = Path(sys.argv[1])
basic_file = Path(sys.argv[2])
cmark_file = Path(sys.argv[3])

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
# iPhoneOS uses the same UUID implementation as Darwin, so bypass the Linux
# libuuid path entirely.
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

# On CMake's iOS platform an executable target is a bundle. swift-cmark's
# install rule predates that cross-host use and omits BUNDLE DESTINATION.
# We do not install cmark, but CMake validates install() syntax at configure.
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
