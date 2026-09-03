#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
DEVELOPER="$SOURCE_ROOT/Developer"
TOOLCHAIN="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain"
OUT_ROOT="${1:-$PWD/.build/XToolMobileRuntime}"
OUT_DEVELOPER="$OUT_ROOT/Developer"
ARCHIVE="$OUT_ROOT.zip"

if [[ ! -d "$DEVELOPER/Platforms/iPhoneOS.platform" ]]; then
  echo "error: missing iPhoneOS.platform under $DEVELOPER" >&2
  exit 1
fi

if [[ ! -d "$TOOLCHAIN/usr/lib/swift/iphoneos" ]]; then
  echo "error: missing Swift iPhoneOS runtime under $TOOLCHAIN/usr/lib/swift/iphoneos" >&2
  exit 1
fi

rm -rf "$OUT_ROOT" "$ARCHIVE"
mkdir -p "$OUT_DEVELOPER/Platforms"
mkdir -p "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"

# Target platform SDK: frameworks, headers, module maps, and stubs for iPhoneOS.
cp -a "$DEVELOPER/Platforms/iPhoneOS.platform" "$OUT_DEVELOPER/Platforms/"

# Swift target runtime/modules needed for arm64-apple-ios compilation.
cp -a "$TOOLCHAIN/usr/lib/swift/iphoneos" \
  "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"

# Compiler shims are referenced by Swift's standard library/module interfaces.
if [[ -d "$TOOLCHAIN/usr/lib/swift/shims" ]]; then
  cp -a "$TOOLCHAIN/usr/lib/swift/shims" \
    "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"
fi

# Some Swift/Clang importer paths expect Swift's bundled clang support tree.
if [[ -d "$TOOLCHAIN/usr/lib/swift/clang" ]]; then
  cp -a "$TOOLCHAIN/usr/lib/swift/clang" \
    "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"
fi

# Copy the newest Clang resource directory (builtin headers such as stddef.h).
if [[ -d "$TOOLCHAIN/usr/lib/clang" ]]; then
  CLANG_RESOURCE="$(find "$TOOLCHAIN/usr/lib/clang" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1 || true)"
  if [[ -n "$CLANG_RESOURCE" ]]; then
    mkdir -p "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang"
    cp -a "$CLANG_RESOURCE" \
      "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/"
  fi
fi

cat > "$OUT_ROOT/README.txt" <<'EOF'
XToolMobileRuntime

Prepared iPhoneOS SDK/runtime tree for the xtool iPad prototype.
This bundle intentionally does not contain a runnable swift/swiftc/swift-frontend.
The mobile compiler implementation will be embedded in xtool and invoked in-process.
EOF

echo "Prepared runtime tree:"
du -sh "$OUT_ROOT"

if command -v zip >/dev/null 2>&1; then
  (
    cd "$(dirname "$OUT_ROOT")"
    zip -qry -y "$ARCHIVE" "$(basename "$OUT_ROOT")"
  )
  echo "Created archive:"
  ls -lh "$ARCHIVE"
else
  echo "warning: zip not installed; leaving prepared folder unarchived"
  echo "Install it with: apt-get install -y zip"
fi
