# HazeBuilder v0.1

HazeBuilder is a lightweight Android/Linux -> iOS build driver specialized for the Haze launcher.

It intentionally does **not** run Haze's `make all`, because that target starts with `clean` and throws away useful build products. Instead HazeBuilder keeps native CMake output, Java output, and Java runtimes independently reusable and only rebuilds what is needed.

## Current target

- Host: Android + Termux Debian/proot
- Target: arm64 iOS/iPadOS
- Project: Haze (`haze-desktop-mode` is supported)
- Signing: produces an IPA intended to be re-signed with KravaSigner/your normal signing workflow

Haze itself is primarily C/C++/Objective-C + Java, so this path does not require the experimental embedded Swift compiler engine.

## Quick start

From the xtool-iOS checkout:

```bash
cd /root/xtool-ios
git pull
bash HazeBuilder/hazebuilder.sh doctor
bash HazeBuilder/hazebuilder.sh build
```

Haze is auto-detected at `/root/haze`. To specify it explicitly:

```bash
bash HazeBuilder/hazebuilder.sh build --project /root/haze
```

The default build is Debug. For Release:

```bash
bash HazeBuilder/hazebuilder.sh build --release
```

Output:

```text
/root/haze/artifacts/HazeBuilder-debug.ipa
```

or:

```text
/root/haze/artifacts/HazeBuilder-release.ipa
```

## Useful commands

```bash
# Environment check only
bash HazeBuilder/hazebuilder.sh doctor

# See which artifacts already exist
bash HazeBuilder/hazebuilder.sh status

# Rebuild only native code
bash HazeBuilder/hazebuilder.sh native

# Rebuild only JavaApp
bash HazeBuilder/hazebuilder.sh java

# Reuse/create the iOS Java runtimes
bash HazeBuilder/hazebuilder.sh runtime

# Reassemble and zip IPA without recompiling native/Java/JRE
bash HazeBuilder/hazebuilder.sh package

# Force source rebuild but keep downloaded runtimes
bash HazeBuilder/hazebuilder.sh build --force

# Explicitly recreate Java runtimes
bash HazeBuilder/hazebuilder.sh build --refresh-runtime
```

## Copy IPA to Android Downloads

From Debian, if `/sdcard` is mounted:

```bash
cp /root/haze/artifacts/HazeBuilder-debug.ipa /sdcard/Download/
```

For a release build:

```bash
cp /root/haze/artifacts/HazeBuilder-release.ipa /sdcard/Download/
```

## Safety

`HazeBuilder clean` removes only its own cache under the xtool checkout. It does not delete `/root/haze`, `Natives/build`, Java runtimes, or Haze's normal artifact history.
