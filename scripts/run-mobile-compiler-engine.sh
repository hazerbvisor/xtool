#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-configure}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SHIM_DIR="$WORK_ROOT/native-tools/bin"
PATCHED_DRIVER="$WORK_ROOT/build-mobile-compiler-engine.patched.sh"

mkdir -p "$SHIM_DIR"

find_tool() {
  local exact="$1"
  local pattern="$2"
  local candidate=""

  for candidate in \
    "/opt/swift/usr/bin/$exact" \
    "/usr/bin/$exact" \
    "/data/data/com.termux/files/usr/bin/$exact" \
    "$(command -v "$exact" 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  candidate="$(find /opt/swift/usr/bin /usr/bin /data/data/com.termux/files/usr/bin \
    -maxdepth 1 \( -type f -o -type l \) -name "$pattern" 2>/dev/null \
    | sort -V | tail -1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  return 1
}

LIBTOOL="$(find_tool llvm-libtool-darwin 'llvm-libtool-darwin*' || true)"
if [[ -z "$LIBTOOL" ]]; then
  cat >&2 <<'EOF'
error: Darwin-compatible libtool not found.
Swift's arm64-apple-ios static-library step requires llvm-libtool-darwin.

Inside Debian, install LLVM tools with:
  apt update
  apt install -y llvm

Then rerun this command.
EOF
  exit 1
fi

ln -sfn "$LIBTOOL" "$SHIM_DIR/libtool"
ln -sfn "$LIBTOOL" "$SHIM_DIR/llvm-libtool-darwin"

INSTALL_NAME_TOOL="$(find_tool llvm-install-name-tool 'llvm-install-name-tool*' || true)"
if [[ -n "$INSTALL_NAME_TOOL" ]]; then
  ln -sfn "$INSTALL_NAME_TOOL" "$SHIM_DIR/install_name_tool"
  ln -sfn "$INSTALL_NAME_TOOL" "$SHIM_DIR/llvm-install-name-tool"
fi

# Keep commonly needed host tools reachable from the same shim directory.
for name in llvm-tblgen clang-tblgen llvm-ar llvm-ranlib llvm-config llvm-profdata; do
  tool="$(find_tool "$name" "$name*" || true)"
  if [[ -n "$tool" ]]; then
    ln -sfn "$tool" "$SHIM_DIR/$name"
  fi
done

# CMake 3.25's Swift try-compile inherits CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY.
# Its sanity source contains top-level `print("CMake")`, which Swift correctly rejects
# when CMake also passes -emit-library. We already proved this swiftc can target iOS
# during the xtool bootstrap build, so mark the cross compiler as working and skip
# that invalid sanity test. Keep the tracked build script clean by patching a temp copy.
python3 - "$ROOT/scripts/build-mobile-compiler-engine.sh" "$PATCHED_DRIVER" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
needle = '    -DCMAKE_Swift_COMPILER_TARGET="$TARGET" \\\n'
replacement = needle + '    -DCMAKE_Swift_COMPILER_WORKS=TRUE \\\n    -DCMAKE_Swift_COMPILER_FORCED=TRUE \\\n'
if needle not in src:
    raise SystemExit('error: could not locate CMAKE_Swift_COMPILER_TARGET in build driver')
Path(sys.argv[2]).write_text(src.replace(needle, replacement, 1))
PY
chmod +x "$PATCHED_DRIVER"

printf 'Darwin cross-build shims:\n'
printf '  libtool:           %s\n' "$LIBTOOL"
printf '  install_name_tool: %s\n' "${INSTALL_NAME_TOOL:-not found (main script will validate)}"
printf '  PATH prefix:       %s\n' "$SHIM_DIR"
printf '  Swift check:       forced valid for cross-compile\n'
printf '  mode:              %s\n\n' "$MODE"

cd "$ROOT"
exec env PATH="$SHIM_DIR:$PATH" bash "$PATCHED_DRIVER" "$MODE"
