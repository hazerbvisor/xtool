#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${DARWIN_SDK_ROOT:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}"
DEVELOPER="$SOURCE_ROOT/Developer"
TOOLCHAIN="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain"
OUT_ROOT="${1:-$PWD/.build/XToolMobileRuntime}"
OUT_DEVELOPER="$OUT_ROOT/Developer"
ARCHIVE="$OUT_ROOT.tar"
RUNTIME_REV="swift-sdk-v5-upstream-prebuilt-stdlib"
REQUIRED_HOST_SWIFT="6.3.2"

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

HOST_SWIFT_VERSION="$($HOST_SWIFTC --version 2>&1 | head -n 1 || true)"
if [[ "$HOST_SWIFT_VERSION" != *"Swift version $REQUIRED_HOST_SWIFT"* ]]; then
  echo "error: Xcode 26.5 mobile runtime currently requires host Swift $REQUIRED_HOST_SWIFT" >&2
  echo "active swiftc: $HOST_SWIFTC" >&2
  echo "reported:      ${HOST_SWIFT_VERSION:-unknown}" >&2
  echo "Select/install Swift $REQUIRED_HOST_SWIFT, then rerun the mobile alignment script." >&2
  exit 1
fi

# xcross binds an extracted Xcode SDK to the active Swift toolchain by replacing
# Xcode's builtin Clang headers with the headers from Swift's sibling Clang.
# Swift's frontend imports these headers while rebuilding textual SDK modules;
# mixing Apple/Xcode builtin headers with a swift.org frontend can produce the
# misleading "Please select a toolchain which matches the SDK" diagnostic.
#
# Xcode 26.5's SDK interfaces identify themselves as Apple Swift 6.3.2. The
# matching xcross configuration is upstream Swift 6.3.2 plus these rebound
# builtin headers, so keep the runtime and embedded frontend on that pair.
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

# Apple's prebuilt Swift.swiftmodule is serialized by the Apple distribution of
# Swift. The embedded XTool frontend is the upstream swift.org 6.3.2 release, so
# it can reject Apple's binary module and fall back to rebuilding the SDK's
# textual Swift.swiftinterface. That textual rebuild is exactly where the iPad
# frontend currently fails. Build a distribution-matched serialized stdlib once
# on the Linux host (where the same SDK/interface already compiles successfully)
# and bundle it for the in-process frontend to consume directly.
SDK_DIR="$OUT_DEVELOPER/Platforms/iPhoneOS.platform/Developer/SDKs"

# Xcode SDK layouts commonly contain a real iPhoneOS.sdk directory plus a
# versioned symlink such as iPhoneOS26.5.sdk -> iPhoneOS.sdk. Do not filter with
# `-type d` here: that drops the versioned symlink and leaves us with a basename
# that contains no version. Prefer an explicitly versioned entry when present.
IOS_SDK="$(find "$SDK_DIR" -maxdepth 1 -name 'iPhoneOS[0-9]*.sdk' -print 2>/dev/null | sort -V | tail -1 || true)"
if [[ -z "$IOS_SDK" ]]; then
  IOS_SDK="$SDK_DIR/iPhoneOS.sdk"
fi
if [[ ! -d "$IOS_SDK" ]]; then
  echo "error: copied iPhoneOS SDK not found in prepared runtime: $IOS_SDK" >&2
  exit 1
fi

SDK_STEM="$(basename "$IOS_SDK" .sdk)"
SDK_VERSION="${SDK_STEM#iPhoneOS}"

# Fallback for SDKs that expose only the unversioned iPhoneOS.sdk directory.
# SDKSettings.json is authoritative for the SDK version and avoids depending on
# a particular symlink naming convention.
if [[ -z "$SDK_VERSION" || "$SDK_VERSION" == "$SDK_STEM" ]]; then
  SDK_SETTINGS="$IOS_SDK/SDKSettings.json"
  if [[ -f "$SDK_SETTINGS" ]]; then
    SDK_VERSION="$(python3 - "$SDK_SETTINGS" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        value = json.load(f).get('Version', '')
    print(value or '')
except Exception:
    print('')
PY
)"
  fi
fi
if [[ -z "$SDK_VERSION" ]]; then
  echo "error: unable to derive iPhoneOS SDK version from $IOS_SDK" >&2
  exit 1
fi

echo "Selected iPhoneOS SDK: $IOS_SDK"
echo "Detected SDK version:  $SDK_VERSION"

BOUND_SWIFT_RESOURCES="$OUT_DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
BOUND_IPHONEOS_SWIFT="$BOUND_SWIFT_RESOURCES/iphoneos"
SWIFT_INTERFACE="$IOS_SDK/usr/lib/swift/Swift.swiftmodule/arm64e-apple-ios.swiftinterface"
XTOOL_PREBUILT_ROOT="$BOUND_IPHONEOS_SWIFT/xtool-prebuilt-modules/$SDK_VERSION"
XTOOL_SWIFT_MODULE_DIR="$XTOOL_PREBUILT_ROOT/Swift.swiftmodule"
XTOOL_SWIFT_MODULE="$XTOOL_SWIFT_MODULE_DIR/arm64e-apple-ios.swiftmodule"
HOST_MODULE_CACHE="$OUT_ROOT/.host-swift-module-cache"

if [[ ! -f "$SWIFT_INTERFACE" ]]; then
  echo "error: Swift SDK interface missing: $SWIFT_INTERFACE" >&2
  exit 1
fi

mkdir -p "$XTOOL_SWIFT_MODULE_DIR" "$HOST_MODULE_CACHE"

echo "Building upstream Swift $REQUIRED_HOST_SWIFT stdlib module for iPhoneOS $SDK_VERSION ..."
"$HOST_SWIFTC_REAL" -frontend \
  -build-module-from-parseable-interface \
  -sdk "$IOS_SDK" \
  -resource-dir "$BOUND_SWIFT_RESOURCES" \
  -I "$BOUND_IPHONEOS_SWIFT" \
  -I "$OUT_DEVELOPER/Platforms/iPhoneOS.platform/Developer/usr/lib" \
  -module-cache-path "$HOST_MODULE_CACHE" \
  -prebuilt-module-cache-path "$XTOOL_PREBUILT_ROOT" \
  -parse-stdlib \
  -diagnostic-style llvm \
  -disable-modules-validate-system-headers \
  -Xcc -isysroot \
  -Xcc "$IOS_SDK" \
  -Xcc -isystem \
  -Xcc "$BOUND_CLANG_INCLUDE" \
  -module-name Swift \
  "$SWIFT_INTERFACE" \
  -o "$XTOOL_SWIFT_MODULE"

rm -rf "$HOST_MODULE_CACHE"
if [[ ! -s "$XTOOL_SWIFT_MODULE" ]]; then
  echo "error: upstream Swift prebuilt stdlib module was not produced" >&2
  exit 1
fi

echo "Upstream Swift stdlib module:"
ls -lh "$XTOOL_SWIFT_MODULE"

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
  echo "$HOST_SWIFT_VERSION"
  echo
  echo "clang: $HOST_CLANG"
  "$HOST_CLANG" --version 2>/dev/null | head -n 1 || true
  echo "clang resource dir: $HOST_CLANG_RESOURCE"
  echo
  echo "xtool prebuilt Swift module: $XTOOL_SWIFT_MODULE"
} > "$OUT_ROOT/HostToolchainBinding.txt"

cat > "$OUT_ROOT/README.txt" <<'EOF'
XToolMobileRuntime

Prepared iPhoneOS SDK/runtime tree for xtool on iPadOS.
This bundle intentionally does not contain a runnable swift/swiftc/swift-frontend.
The compiler implementation is embedded into xtool and invoked in-process.
Swift SDK metadata is preserved so the mobile frontend can mirror the same
cross-SDK configuration used by the successful desktop/Linux xtool build.
The bundled Swift Clang builtin headers are rebound to the host Swift 6.3.2
compiler toolchain, matching the Xcode 26.5 cross-SDK preparation used by xcross.
A Swift.swiftmodule compiled from the Apple textual SDK interface by upstream
Swift 6.3.2 is bundled under iphoneos/xtool-prebuilt-modules so the iPad frontend
does not need to rebuild Apple's standard-library interface at runtime.
EOF

echo "Prepared runtime tree:"
du -sh "$OUT_ROOT"
echo "Runtime revision: $RUNTIME_REV"
echo "Bound swiftc: $HOST_SWIFTC_REAL"
echo "Bound version: $HOST_SWIFT_VERSION"
echo "Bound clang:  $HOST_CLANG"
echo "Bound headers: $HOST_CLANG_INCLUDE"
echo "XTool Swift module: $XTOOL_SWIFT_MODULE"
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
