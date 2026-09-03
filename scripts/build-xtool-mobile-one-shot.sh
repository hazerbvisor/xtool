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

mkdir -p "$ROOT/.build"

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
  else
    if [[ -f "$BUILD_ROOT/build.ninja" ]] && grep -q 'XToolCompilerEngine' "$BUILD_ROOT/build.ninja"; then
      echo '=== compiler configure ==='
      echo 'cache hit: CMake graph already contains XToolCompilerEngine'
    else
      echo '=== compiler configure ==='
      bash scripts/run-mobile-compiler-engine.sh configure
    fi

    echo '=== compiler build ==='
    bash scripts/run-mobile-compiler-engine.sh build
  fi

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
  CONFIGURATION="$CONFIGURATION" TRIPLE="$TRIPLE" \
    bash scripts/package-mobile-app.sh

  echo
  echo '=== SUCCESS ==='
  echo "Compiler engine: $ENGINE"
  echo "Unsigned IPA:    $ROOT/.build/XToolMobileApp-unsigned.ipa"
}

set +e
run_all 2>&1 | tee "$LOG"
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
