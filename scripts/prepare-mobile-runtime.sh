#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
DEVELOPER="$SOURCE_ROOT/Developer"
TOOLCHAIN="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain"
OUT_ROOT="${1:-$PWD/.build/XToolMobileRuntime}"
OUT_DEVELOPER="$OUT_ROOT/Developer"
ARCHIVE="$OUT_ROOT.tar"
RUNTIME_REV="swift-sdk-v2"

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

# Keep the entire iPhoneOS platform. In addition to the .sdk sysroot, Swift's
# cross-SDK metadata points at Platform/Developer/usr/lib for target include
# and library search paths.
cp -a "$DEVELOPER/Platforms/iPhoneOS.platform" "$OUT_DEVELOPER/Platforms/"

# Canonical target Swift resources used by -resource-dir.
cp -a "$TOOLCHAIN/usr/lib/swift/iphoneos" \
  "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"

if [[ -d "$TOOLCHAIN/usr/lib/swift/shims" ]]; then
  cp -a "$TOOLCHAIN/usr/lib/swift/shims" \
    "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"
fi

# This is particularly important for normal Foundation/UIKit imports. The
# builtin headers must be the Swift-sibling headers that the Darwin Swift SDK
# was prepared against, not whatever Clang happens to exist on the device.
if [[ -d "$TOOLCHAIN/usr/lib/swift/clang" ]]; then
  cp -a "$TOOLCHAIN/usr/lib/swift/clang" \
    "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"
fi

# Preserve the original Clang resource tree too; later ObjC/C++ and linker
# stages can use it without another SDK bootstrap.
if [[ -d "$TOOLCHAIN/usr/lib/clang" ]]; then
  CLANG_RESOURCE="$(find "$TOOLCHAIN/usr/lib/clang" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1 || true)"
  if [[ -n "$CLANG_RESOURCE" ]]; then
    mkdir -p "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang"
    cp -a "$CLANG_RESOURCE" \
      "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/"
  fi
fi

# SwiftPM's successful Linux -> iOS build is driven by these files. Keep them
# in the mobile runtime so the in-process frontend can resolve the same SDK,
# Swift resource, include and library paths instead of guessing them.
for metadata in info.json swift-sdk.json toolset.json darwin-sdk-version.txt; do
  if [[ -f "$SOURCE_ROOT/$metadata" ]]; then
    cp "$SOURCE_ROOT/$metadata" "$OUT_ROOT/$metadata"
  fi
done

printf '%s\n' "$RUNTIME_REV" > "$OUT_ROOT/XToolRuntimeRevision.txt"
if command -v swiftc >/dev/null 2>&1; then
  swiftc --version | head -n 1 > "$OUT_ROOT/HostSwiftVersion.txt" || true
fi

cat > "$OUT_ROOT/README.txt" <<'EOF'
XToolMobileRuntime

Prepared iPhoneOS SDK/runtime tree for xtool on iPadOS.
This bundle intentionally does not contain a runnable swift/swiftc/swift-frontend.
The compiler implementation is embedded into xtool and invoked in-process.
Swift SDK metadata is preserved so the mobile frontend can mirror the same
cross-SDK configuration used by the successful desktop/Linux xtool build.
EOF

echo "Prepared runtime tree:"
du -sh "$OUT_ROOT"
echo "Runtime revision: $RUNTIME_REV"
[[ -f "$OUT_ROOT/swift-sdk.json" ]] && echo "Swift SDK metadata: included" || echo "Swift SDK metadata: legacy fallback"

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
