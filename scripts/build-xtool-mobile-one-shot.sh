#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
BUILD_ROOT="$WORK_ROOT/build-ios"
ENGINE="$WORK_ROOT/package/libXToolCompilerEngine.dylib"
LOG="$ROOT/.build/xtool-mobile-one-shot.log"
CONFIGURATION="${CONFIGURATION:-debug}"
TRIPLE="${TRIPLE:-arm64-apple-ios}"
RUNTIME_ARCHIVE="$ROOT/.build/XToolMobileRuntime.tar"
IPA="$ROOT/.build/XToolMobileApp-unsigned.ipa"
IPA_ENGINE_PATH="Payload/XToolMobileApp.app/Frameworks/libXToolCompilerEngine.dylib"
COMPILER_CONFIG_REV="ios-rpath-clang-shared-off-v1"
COMPILER_CONFIG_STAMP="$WORK_ROOT/.xtool-compiler-config-rev"

mkdir -p "$ROOT/.build"

verify_ipa_engine() {
  [[ -f "$IPA" ]] || { echo "error: final IPA missing: $IPA" >&2; return 1; }
  python3 - "$IPA" "$IPA_ENGINE_PATH" <<'PY'
import sys, zipfile
ipa, required = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(ipa) as zf:
    names = set(zf.namelist())
    if required not in names:
        print(f"error: compiler engine is not inside final IPA: {required}", file=sys.stderr)
        sys.exit(1)
    info = zf.getinfo(required)
    print(f"verified IPA compiler engine: {required} ({info.file_size} bytes)")
PY
}

compiler_config_is_current() {
  [[ -f "$BUILD_ROOT/build.ninja" ]] || return 1
  [[ -f "$COMPILER_CONFIG_STAMP" ]] || return 1
  [[ "$(cat "$COMPILER_CONFIG_STAMP" 2>/dev/null || true)" == "$COMPILER_CONFIG_REV" ]] || return 1
  grep -q 'XToolCompilerEngine' "$BUILD_ROOT/build.ninja"
}

run_all() {
  cd "$ROOT"

  echo '=== XTool Mobile one-shot bootstrap ==='
  echo "compiler work: $WORK_ROOT"
  echo "engine:        $ENGINE"
  echo "app config:    $CONFIGURATION"
  echo "app triple:    $TRIPLE"
  echo

  if [[ -f "$ENGINE" ]]; then
    echo '=== compiler engine ==='
    echo 'cache hit: final compiler dylib already exists'
    file "$ENGINE" 2>/dev/null || true
    ls -lh "$ENGINE"
  else
    if compiler_config_is_current; then
      echo '=== compiler configure ==='
      echo 'cache hit: current CMake graph already contains XToolCompilerEngine'
    else
      echo '=== compiler configure ==='
      bash scripts/run-mobile-compiler-engine.sh configure
      printf '%s\n' "$COMPILER_CONFIG_REV" > "$COMPILER_CONFIG_STAMP"
    fi

    echo '=== compiler build ==='
    bash scripts/run-mobile-compiler-engine.sh build
  fi

  [[ -f "$ENGINE" ]] || {
    echo "error: compiler build phase ended without final engine: $ENGINE" >&2
    return 1
  }

  echo
  echo '=== XTool Mobile app build ==='
  swift build \
    --disable-automatic-resolution \
    --product XToolMobileApp \
    --swift-sdk "$TRIPLE" \
    -c "$CONFIGURATION"

  if [[ ! -f "$RUNTIME_ARCHIVE" ]]; then
    echo
    echo '=== bundled Darwin runtime ==='
    bash scripts/prepare-mobile-runtime.sh
  else
    echo
    echo '=== bundled Darwin runtime ==='
    echo "cache hit: $RUNTIME_ARCHIVE"
  fi

  echo
  echo '=== IPA package ==='
  CONFIGURATION="$CONFIGURATION" \
  TRIPLE="$TRIPLE" \
  COMPILER_ENGINE_DYLIB="$ENGINE" \
  REQUIRE_COMPILER_ENGINE=1 \
    bash scripts/package-mobile-app.sh

  echo
  echo '=== IPA verification ==='
  verify_ipa_engine

  echo
  echo '=== SUCCESS ==='
  echo "Compiler engine: $ENGINE"
  echo "Unsigned IPA:    $IPA"
}

set +e
(
  set -e
  run_all
) 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  echo >&2
  echo "XTool Mobile bootstrap failed (exit $status)." >&2
  echo "Send this one log:" >&2
  echo "  $LOG" >&2
else
  echo
  echo "Full build log: $LOG"
fi

exit "$status"
