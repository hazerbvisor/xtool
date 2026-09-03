#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-debug}"
TRIPLE="${TRIPLE:-arm64-apple-ios}"
BUNDLE_ID="${BUNDLE_ID:-sh.xtool.mobile}"
DISPLAY_NAME="${DISPLAY_NAME:-xtool}"
MIN_IOS="${MIN_IOS:-16.0}"

# Default mobile distribution mode: keep the Darwin SDK bundled in the IPA as
# ONE opaque zip file. Signers therefore do not recursively inspect SDK dylibs,
# while xtool can unpack the archive into Application Support on first launch.
BUNDLE_RUNTIME_ARCHIVE="${BUNDLE_RUNTIME_ARCHIVE:-1}"
# Expanded embedding is retained only as a debugging option because some iOS
# signing tools try to sign every dylib they discover under the app bundle.
EMBED_RUNTIME_EXPANDED="${EMBED_RUNTIME_EXPANDED:-0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$TRIPLE/$CONFIGURATION"
EXECUTABLE="$BUILD_DIR/XToolMobileApp"
RUNTIME="$ROOT/.build/XToolMobileRuntime"
RUNTIME_ARCHIVE="$ROOT/.build/XToolMobileRuntime.zip"
STAGE="$ROOT/.build/mobile-package"
PAYLOAD="$STAGE/Payload"
APP="$PAYLOAD/XToolMobileApp.app"
IPA="$ROOT/.build/XToolMobileApp-unsigned.ipa"

if [[ ! -f "$EXECUTABLE" ]]; then
  echo "error: missing executable: $EXECUTABLE" >&2
  echo "Build it first with:" >&2
  echo "  swift build --product XToolMobileApp --swift-sdk $TRIPLE -c $CONFIGURATION" >&2
  exit 1
fi

rm -rf "$STAGE" "$IPA"
mkdir -p "$APP"
cp "$EXECUTABLE" "$APP/XToolMobileApp"
chmod 0755 "$APP/XToolMobileApp"

if [[ "$BUNDLE_RUNTIME_ARCHIVE" == "1" ]]; then
  if [[ -f "$RUNTIME_ARCHIVE" ]]; then
    echo "Bundling Darwin runtime as signer-safe MobileRuntime.zip..."
    cp "$RUNTIME_ARCHIVE" "$APP/MobileRuntime.zip"
  else
    echo "warning: $RUNTIME_ARCHIVE is missing" >&2
    echo "Run: bash scripts/prepare-mobile-runtime.sh" >&2
  fi
fi

if [[ "$EMBED_RUNTIME_EXPANDED" == "1" ]]; then
  if [[ -d "$RUNTIME/Developer/Platforms/iPhoneOS.platform" ]]; then
    echo "Embedding expanded Darwin runtime (experimental)..."
    cp -a "$RUNTIME" "$APP/MobileRuntime"
  else
    echo "warning: expanded runtime folder is missing" >&2
  fi
fi

cat > "$APP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>XToolMobileApp</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>XToolMobileApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>MinimumOSVersion</key>
    <string>${MIN_IOS}</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
</dict>
</plist>
EOF

if command -v zip >/dev/null 2>&1; then
  (
    cd "$STAGE"
    # The outer IPA zip may compress MobileRuntime.zip poorly because it is
    # already compressed, but leaving it nested prevents signers from walking
    # the SDK's dylib tree.
    zip -qry -y "$IPA" Payload
  )
elif command -v python3 >/dev/null 2>&1; then
  python3 - "$STAGE" "$IPA" <<'PY'
import os, sys, zipfile
stage, ipa = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(ipa, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(os.path.join(stage, 'Payload')):
        for name in files:
            path = os.path.join(root, name)
            zf.write(path, os.path.relpath(path, stage))
PY
else
  echo "error: need either 'zip' or 'python3' to create the IPA" >&2
  exit 1
fi

cat <<EOF
Created unsigned IPA:
  $IPA

Signing: intentionally unsigned; no provisioning profile included.
Bundled runtime archive: $BUNDLE_RUNTIME_ARCHIVE
Expanded runtime: $EMBED_RUNTIME_EXPANDED
EOF
