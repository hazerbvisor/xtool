#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-configure}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
SHIM_DIR="$WORK_ROOT/native-tools/bin"

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

printf 'Darwin cross-build shims:\n'
printf '  libtool:           %s\n' "$LIBTOOL"
printf '  install_name_tool: %s\n' "${INSTALL_NAME_TOOL:-not found (main script will validate)}"
printf '  PATH prefix:       %s\n' "$SHIM_DIR"
printf '  mode:              %s\n\n' "$MODE"

cd "$ROOT"
exec env PATH="$SHIM_DIR:$PATH" bash scripts/build-mobile-compiler-engine.sh "$MODE"
