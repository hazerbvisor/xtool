#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="build"
CONFIG="debug"
FORCE=0
REFRESH_RUNTIME=0
PROJECT="${HAZE_PROJECT:-}"
DARWIN_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
CACHE_ROOT="${HAZE_BUILDER_CACHE:-$ROOT/.build/hazebuilder}"
JOBS="${HAZE_BUILDER_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

usage() {
  cat <<'USAGE'
HazeBuilder - lightweight Android/Linux -> iOS builder for Haze

Usage:
  bash HazeBuilder/hazebuilder.sh [command] [options]

Commands:
  doctor     Check the Android/Debian build environment
  status     Show project, SDK, cache and existing build artifacts
  native     Incrementally build Haze native C/C++/Objective-C code
  java       Build JavaApp only when project inputs changed
  runtime    Prepare/reuse iOS Java runtimes
  payload    Assemble Payload/Haze.app from existing build products
  package    Assemble Payload and create an unsigned IPA
  build      Incremental native + Java + runtime + package (default)
  clean      Remove HazeBuilder cache only; Haze source/builds are preserved

Options:
  --project PATH       Haze checkout (auto-detects /root/haze by default)
  --release            Release native build
  --debug              Debug native build (default)
  --jobs N             Parallel build jobs
  --force              Ignore HazeBuilder stamps and rebuild native/Java
  --refresh-runtime    Recreate Java runtime bundle
  -h, --help           Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    doctor|status|native|java|runtime|payload|package|build|clean)
      MODE="$1"; shift ;;
    --project)
      PROJECT="${2:?missing path after --project}"; shift 2 ;;
    --release)
      CONFIG="release"; shift ;;
    --debug)
      CONFIG="debug"; shift ;;
    --jobs)
      JOBS="${2:?missing number after --jobs}"; shift 2 ;;
    --force)
      FORCE=1; shift ;;
    --refresh-runtime)
      REFRESH_RUNTIME=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  for candidate in /root/haze "$HOME/haze" "$ROOT/../haze"; do
    if [[ -f "$candidate/Makefile" && -d "$candidate/Natives" ]]; then
      PROJECT="$candidate"
      break
    fi
  done
fi

section() { printf '\n=== %s ===\n' "$1"; }
die() { echo "error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ -n "$PROJECT" ]] || die "Haze project not found. Pass --project /root/haze"
PROJECT="$(cd "$PROJECT" && pwd)"
[[ -f "$PROJECT/Makefile" ]] || die "not a Haze checkout: $PROJECT"
[[ -d "$PROJECT/Natives" ]] || die "Haze Natives directory missing: $PROJECT/Natives"

IOS_SDK="${SDKPATH:-}"
if [[ -z "$IOS_SDK" && -d "$DARWIN_ROOT/Developer/Platforms/iPhoneOS.platform/Developer/SDKs" ]]; then
  IOS_SDK="$(find "$DARWIN_ROOT/Developer/Platforms/iPhoneOS.platform/Developer/SDKs" -maxdepth 1 \( -type d -o -type l \) -name 'iPhoneOS*.sdk' 2>/dev/null | sort -V | tail -1 || true)"
fi
[[ -n "$IOS_SDK" && -d "$IOS_SDK" ]] || die "iPhoneOS SDK not found. Set SDKPATH or DARWIN_SDK_ROOT"

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
(( JOBS > 0 )) || die "--jobs must be greater than zero"

RELEASE=0
[[ "$CONFIG" == "release" ]] && RELEASE=1

PROJECT_KEY="$(printf '%s' "$PROJECT" | sha256sum | cut -c1-12)"
STATE_DIR="$CACHE_ROOT/$PROJECT_KEY"
mkdir -p "$STATE_DIR"

WORKINGDIR="$PROJECT/Natives/build"
ARTIFACTS="$PROJECT/artifacts"
NATIVE_BIN="$WORKINGDIR/AngelAuraAmethyst.app/AngelAuraAmethyst"
JAVA_BUILD="$PROJECT/JavaApp/build"
RUNTIME_DIR="$ARTIFACTS/java_runtimes"
PAYLOAD_DIR="$ARTIFACTS/Payload"
IPA_OUT="$ARTIFACTS/HazeBuilder-${CONFIG}.ipa"

project_fingerprint() {
  {
    printf 'config=%s\nsdk=%s\n' "$CONFIG" "$IOS_SDK"
    if git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$PROJECT" rev-parse HEAD 2>/dev/null || true
      git -C "$PROJECT" diff --no-ext-diff --binary -- . ':(exclude)artifacts' ':(exclude)Natives/build' 2>/dev/null || true
      git -C "$PROJECT" status --porcelain=v1 --untracked-files=all -- . ':(exclude)artifacts' ':(exclude)Natives/build' 2>/dev/null || true
    else
      find "$PROJECT/Natives" "$PROJECT/JavaApp" -type f \
        ! -path '*/build/*' -printf '%p %s %T@\n' 2>/dev/null | sort
    fi
  } | sha256sum | awk '{print $1}'
}

STAMP="$(project_fingerprint)"

stamp_matches() {
  local name="$1"
  [[ "$FORCE" == 0 && -f "$STATE_DIR/$name.stamp" && "$(cat "$STATE_DIR/$name.stamp")" == "$STAMP" ]]
}

write_stamp() {
  printf '%s\n' "$STAMP" > "$STATE_DIR/$1.stamp"
}

make_haze() {
  make -C "$PROJECT" --no-print-directory \
    SDKPATH="$IOS_SDK" JOBS="$JOBS" RELEASE="$RELEASE" "$@"
}

doctor() {
  section "HazeBuilder doctor"
  printf 'project:       %s\n' "$PROJECT"
  printf 'branch:        %s\n' "$(git -C "$PROJECT" branch --show-current 2>/dev/null || echo unknown)"
  printf 'SDK:           %s\n' "$IOS_SDK"
  printf 'configuration: %s\n' "$CONFIG"
  printf 'jobs:          %s\n' "$JOBS"
  printf 'cache:         %s\n' "$STATE_DIR"

  local missing=0
  for tool in make cmake clang lld ldid zip javac python3; do
    if have "$tool"; then
      printf '  %-10s %s\n' "$tool" "$(command -v "$tool")"
    else
      printf '  %-10s MISSING\n' "$tool"
      missing=1
    fi
  done

  if [[ $missing -ne 0 ]]; then
    die "one or more required tools are missing"
  fi

  if ! javac -version 2>&1 | grep -q '1\.8\|8\.'; then
    echo "warning: Haze's current Makefile expects JDK 8; found: $(javac -version 2>&1)" >&2
  fi

  echo "doctor: READY"
}

build_native() {
  if stamp_matches native && [[ -x "$NATIVE_BIN" ]]; then
    section "native"
    echo "cache hit: native build unchanged"
    return
  fi
  section "native"
  make_haze native
  [[ -f "$NATIVE_BIN" ]] || die "native target completed but app executable was not found: $NATIVE_BIN"
  write_stamp native
}

build_java() {
  if stamp_matches java && compgen -G "$JAVA_BUILD/*.jar" >/dev/null; then
    section "java"
    echo "cache hit: JavaApp unchanged"
    return
  fi
  section "java"
  make_haze java
  compgen -G "$JAVA_BUILD/*.jar" >/dev/null || die "Java target completed but no JAR was produced in $JAVA_BUILD"
  write_stamp java
}

prepare_runtime() {
  section "runtime"
  if [[ "$REFRESH_RUNTIME" == 0 && -d "$RUNTIME_DIR" && -n "$(find "$RUNTIME_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "cache hit: reusing existing iOS Java runtimes"
    return
  fi

  # jre depends on native in the upstream Makefile. Native was already handled
  # by HazeBuilder, so mark it old to avoid compiling it again.
  make_haze --assume-old=native jre
  [[ -d "$RUNTIME_DIR" ]] || die "runtime target completed but $RUNTIME_DIR was not created"
}

assemble_payload() {
  section "payload"
  [[ -f "$NATIVE_BIN" ]] || die "native app missing; run HazeBuilder native/build first"
  compgen -G "$JAVA_BUILD/*.jar" >/dev/null || die "Java JARs missing; run HazeBuilder java/build first"
  [[ -d "$RUNTIME_DIR" ]] || die "Java runtimes missing; run HazeBuilder runtime/build first"

  # Reuse Haze's battle-tested payload recipe, but suppress its expensive
  # prerequisites because HazeBuilder has already produced/cached them.
  make_haze \
    --assume-old=native \
    --assume-old=dep_mg \
    --assume-old=java \
    --assume-old=jre \
    --assume-old=assets \
    payload

  [[ -d "$PAYLOAD_DIR/AngelAuraAmethyst.app" ]] || die "payload recipe did not create Payload/AngelAuraAmethyst.app"
}

package_ipa() {
  assemble_payload
  section "package"
  rm -f "$IPA_OUT"
  (
    cd "$ARTIFACTS"
    zip --symlinks -qry "$IPA_OUT" Payload
  )
  [[ -s "$IPA_OUT" ]] || die "IPA was not created"
  printf 'unsigned IPA: %s\n' "$IPA_OUT"
  du -h "$IPA_OUT" | awk '{print "size:         "$1}'
}

show_status() {
  section "HazeBuilder status"
  printf 'project:       %s\n' "$PROJECT"
  printf 'SDK:           %s\n' "$IOS_SDK"
  printf 'configuration: %s\n' "$CONFIG"
  printf 'fingerprint:   %.16s...\n' "$STAMP"
  printf 'native:        %s\n' "$([[ -f "$NATIVE_BIN" ]] && echo present || echo missing)"
  printf 'java jars:     %s\n' "$(compgen -G "$JAVA_BUILD/*.jar" >/dev/null && echo present || echo missing)"
  printf 'runtime:       %s\n' "$([[ -d "$RUNTIME_DIR" ]] && echo present || echo missing)"
  printf 'IPA:           %s\n' "$([[ -f "$IPA_OUT" ]] && echo "$IPA_OUT" || echo missing)"
  du -sh "$STATE_DIR" 2>/dev/null || true
}

case "$MODE" in
  doctor) doctor ;;
  status) show_status ;;
  native) doctor; build_native ;;
  java) doctor; build_java ;;
  runtime) doctor; prepare_runtime ;;
  payload) doctor; assemble_payload ;;
  package) doctor; package_ipa ;;
  build)
    doctor
    build_native
    build_java
    prepare_runtime
    package_ipa
    ;;
  clean)
    section "clean"
    rm -rf "$STATE_DIR"
    echo "removed HazeBuilder cache only: $STATE_DIR"
    echo "Haze source and Natives/build were not touched."
    ;;
esac
