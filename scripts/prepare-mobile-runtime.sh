#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
DEVELOPER="$SOURCE_ROOT/Developer"
TOOLCHAIN="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain"
OUT_ROOT="${1:-$PWD/.build/XToolMobileRuntime}"
OUT_DEVELOPER="$OUT_ROOT/Developer"
ARCHIVE="$OUT_ROOT.tar"

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

cp -a "$DEVELOPER/Platforms/iPhoneOS.platform" "$OUT_DEVELOPER/Platforms/"

cp -a "$TOOLCHAIN/usr/lib/swift/iphoneos" \
  "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"

if [[ -d "$TOOLCHAIN/usr/lib/swift/shims" ]]; then
  cp -a "$TOOLCHAIN/usr/lib/swift/shims" \
    "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"
fi

if [[ -d "$TOOLCHAIN/usr/lib/swift/clang" ]]; then
  cp -a "$TOOLCHAIN/usr/lib/swift/clang" \
    "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"
fi

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

if command -v tar >/dev/null 2>&1; then
  (
    cd "$(dirname "$OUT_ROOT")"
    # Apple SDKs contain individual filenames longer than classic USTAR's
    # 100-byte name field. PAX stores those paths in extended headers while
    # keeping the archive dependency-free and readable by xtool's tiny extractor.
    tar --format=pax \
      --pax-option=delete=atime,delete=ctime \
      -cf "$ARCHIVE" "$(basename "$OUT_ROOT")"
  )
  echo "Created PAX runtime archive:"
  ls -lh "$ARCHIVE"
else
  echo "error: tar is required to prepare the bundled runtime" >&2
  exit 1
fi
