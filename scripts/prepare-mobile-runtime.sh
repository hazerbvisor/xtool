#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
DEVELOPER="$SOURCE_ROOT/Developer"
TOOLCHAIN="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain"
OUT_ROOT="${1:-$PWD/.build/XToolMobileRuntime}"
OUT_DEVELOPER="$OUT_ROOT/Developer"
ARCHIVE="$OUT_ROOT.tar"
RUNTIME_REV="swift-sdk-v3-host-clang"

if [[ ! -d "$DEVELOPER/Platforms/iPhoneOS.platform" ]]; then
  echo "error: missing iPhoneOS.platform under $DEVELOPER" >&2
  exit 1
fi

if [[ ! -d "$TOOLCHAIN/usr/lib/swift/iphoneos" ]]; then
  echo "error: missing Swift iPhoneOS runtime under $TOOLCHAIN/usr/lib/swift/iphoneos" >&2
  exit 1
fi

HOST_SWIFTC="${XTOOL_HOST_SWIFTC:-$(command -v swiftc 2>/dev/null || true)}"
if [[ -z "$HOST_SWIFTC" || ! -x "$HOST_SWIFTC" ]]; then
  echo "error: host swiftc not found; the Darwin SDK must be bound to the Swift toolchain used to build XTool" >&2
  exit 1
fi

# xcross binds an extracted Xcode SDK to the active Swift toolchain by replacing
# Xcode's builtin Clang headers with the headers from Swift's sibling Clang.
# Swift's frontend imports these headers while rebuilding textual SDK modules;
# mixing Apple/Xcode builtin headers with a swift.org frontend can produce the
# misleading "Please select a toolchain which matches the SDK" diagnostic.
HOST_SWIFTC_REAL="$(readlink -f "$HOST_SWIFTC" 2>/dev/null || printf '%s' "$HOST_SWIFTC")"
HOST_SWIFT_BIN="$(dirname "$HOST_SWIFTC_REAL")"
HOST_CLANG="${XTOOL_HOST_CLANG:-$HOST_SWIFT_BIN/clang}"
if [[ ! -x "$HOST_CLANG" ]]; then
  echo "error: Swift-sibling clang not found at $HOST_CLANG" >&2
  echo "Set XTOOL_HOST_CLANG to the clang shipped with the same Swift toolchain as $HOST_SWIFTC_REAL" >&2
  exit 1
fi

HOST_CLANG_RESOURCE="$($HOST_CLANG -print-resource-dir 2>/dev/null || true)"
HOST_CLANG_INCLUDE="$HOST_CLANG_RESOURCE/include"
if [[ -z "$HOST_CLANG_RESOURCE" || ! -d "$HOST_CLANG_INCLUDE" ]]; then
  echo "error: unable to locate builtin headers from Swift-sibling clang: $HOST_CLANG" >&2
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

# Preserve the Darwin toolchain's Swift/Clang directory shape first, then bind
# its builtin include directory to the active swift.org toolchain below. The
# SDK commonly exposes swift/clang as a relative symlink into usr/lib/clang;
# dereference it here so the partially copied runtime never contains a dangling
# symlink that makes the later mkdir -p fail with "File exists".
if [[ -d "$TOOLCHAIN/usr/lib/swift/clang" ]]; then
  cp -aL "$TOOLCHAIN/usr/lib/swift/clang" \
    "$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/"
fi

BOUND_CLANG_INCLUDE="$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include"
rm -rf "$BOUND_CLANG_INCLUDE"
mkdir -p "$(dirname "$BOUND_CLANG_INCLUDE")"
cp -a "$HOST_CLANG_INCLUDE" "$BOUND_CLANG_INCLUDE"

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
{
  echo "swiftc: $HOST_SWIFTC_REAL"
  "$HOST_SWIFTC" --version 2>/dev/null || true
  echo
  echo "clang: $HOST_CLANG"
  "$HOST_CLANG" --version 2>/dev/null | head -n 1 || true
  echo "clang resource dir: $HOST_CLANG_RESOURCE"
} > "$OUT_ROOT/HostToolchainBinding.txt"

cat > "$OUT_ROOT/README.txt" <<'EOF'
XToolMobileRuntime

Prepared iPhoneOS SDK/runtime tree for xtool on iPadOS.
This bundle intentionally does not contain a runnable swift/swiftc/swift-frontend.
The compiler implementation is embedded into xtool and invoked in-process.
Swift SDK metadata is preserved so the mobile frontend can mirror the same
cross-SDK configuration used by the successful desktop/Linux xtool build.
The bundled Swift Clang builtin headers are rebound to the host swift.org
compiler toolchain, matching the cross-SDK preparation used by xcross.
EOF

echo "Prepared runtime tree:"
du -sh "$OUT_ROOT"
echo "Runtime revision: $RUNTIME_REV"
echo "Bound swiftc: $HOST_SWIFTC_REAL"
echo "Bound clang:  $HOST_CLANG"
echo "Bound headers: $HOST_CLANG_INCLUDE"
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
