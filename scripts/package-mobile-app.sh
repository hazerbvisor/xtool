#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${CONFIGURATION:-debug}"
TRIPLE="${TRIPLE:-arm64-apple-ios}"
BUNDLE_ID="${BUNDLE_ID:-sh.xtool.mobile}"
DISPLAY_NAME="${DISPLAY_NAME:-xtool}"
MIN_IOS="${MIN_IOS:-16.0}"
EMBED_RUNTIME="${EMBED_RUNTIME:-1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$TRIPLE/$CONFIGURATION"
EXECUTABLE="$BUILD_DIR/XToolMobileApp"
RUNTIME="$ROOT/.build/XToolMobileRuntime"
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

if [[ "$EMBED_RUNTIME" == "1" ]]; then
  if [[ -d "$RUNTIME/Developer/Platforms/iPhoneOS.platform" ]]; then
    echo "Embedding prepared iPhoneOS runtime into app bundle..."
    cp -a "$RUNTIME" "$APP/MobileRuntime"
  else
    echo "warning: .build/XToolMobileRuntime is missing; packaging without bundled runtime" >&2
    echo "Run: bash scripts/prepare-mobile-runtime.sh" >&2
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
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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

This IPA is intentionally NOT signed and contains NO provisioning profile.
Sign it on your iPad with your preferred signer before installing.
EOF
