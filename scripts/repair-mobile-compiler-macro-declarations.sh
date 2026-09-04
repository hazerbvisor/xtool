#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="${XTOOL_COMPILER_WORK:-$ROOT/.build/mobile-compiler-engine}"
LANG_OPTIONS="$WORK_ROOT/src/swift/lib/Basic/LangOptions.cpp"
BUILD_ROOT="$WORK_ROOT/build-ios"
JOBS="${XTOOL_COMPILER_JOBS:-2}"

[[ -f "$LANG_OPTIONS" ]] || { echo "error: Swift LangOptions.cpp not found: $LANG_OPTIONS" >&2; exit 1; }
[[ -f "$BUILD_ROOT/build.ninja" ]] || { echo "error: existing compiler build not found: $BUILD_ROOT/build.ninja" >&2; exit 1; }

python3 - "$LANG_OPTIONS" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
old = '''  // Special case: remove macro support if the compiler wasn't built with a
  // host Swift.
#if !SWIFT_BUILD_SWIFT_SYNTAX
  disableFeature(Feature::Macros);
  disableFeature(Feature::FreestandingExpressionMacros);
  disableFeature(Feature::AttachedMacros);
  disableFeature(Feature::ExtensionMacros);
#endif
'''
new = '''  // XTool Mobile AOT compatibility: keep the macro language features enabled
  // even when the SwiftSyntax/plugin implementation is not linked. Apple SDK
  // Swift interfaces contain macro declarations that must be parsed/imported,
  // even for source files that never expand or execute a macro. Actual external
  // macro expansion still requires the SwiftSyntax/plugin implementation.
#if !SWIFT_BUILD_SWIFT_SYNTAX
  // Intentionally do not disable Feature::Macros or its declaration roles.
#endif
'''
if new in s:
    print('XTool SDK macro-declaration compatibility patch: already applied')
elif old in s:
    p.write_text(s.replace(old, new, 1))
    print('XTool SDK macro-declaration compatibility patch: applied')
else:
    raise SystemExit('error: expected Swift macro-disable block not found')
PY

echo
echo "=== incremental compiler rebuild ==="
echo "Preserving existing LLVM/Swift objects; Ninja will rebuild only affected targets."
echo "jobs: $JOBS"
XTOOL_COMPILER_JOBS="$JOBS" bash "$ROOT/scripts/run-mobile-compiler-engine.sh" build

echo
echo "SUCCESS: macro-declaration compatibility engine rebuilt incrementally."
echo "Next: bash scripts/build-xtool-mobile-one-shot.sh"
