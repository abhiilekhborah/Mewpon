#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swift-cache}"
# --disable-sandbox only disables SwiftPM's build-script sandbox, not macOS security.
# There are no third-party packages or build plugins in this project.
swift build -c release --disable-sandbox -Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$PWD/scripts/app-intents-protocols.json"
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
APP_DIR="$PWD/build/Mewpon.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Mewpon" "$APP_DIR/Contents/MacOS/Mewpon.next"
mv -f "$APP_DIR/Contents/MacOS/Mewpon.next" "$APP_DIR/Contents/MacOS/Mewpon"
cp -R "$BIN_DIR/Mewpon_MewponDesktop.bundle" "$APP_DIR/Contents/Resources/"
cp AppInfo.plist "$APP_DIR/Contents/Info.plist"
cp Assets/Mewpon.icns "$APP_DIR/Contents/Resources/Mewpon.icns"
python3 "$PWD/scripts/bundle-speech.py"
python3 "$PWD/scripts/bundle-diarization.py"
# Embed a separately signed, lightweight shortcut listener managed by SMAppService.
HELPER_DIR="$APP_DIR/Contents/Library/LoginItems/MewponLauncher.app"
mkdir -p "$HELPER_DIR/Contents/MacOS"
cp "$BIN_DIR/MewponLauncher" "$HELPER_DIR/Contents/MacOS/MewponLauncher.next"
mv -f "$HELPER_DIR/Contents/MacOS/MewponLauncher.next" "$HELPER_DIR/Contents/MacOS/MewponLauncher"
cp LauncherInfo.plist "$HELPER_DIR/Contents/Info.plist"

# SwiftPM does not run Xcode's App Intents metadata phase automatically.
find "$PWD/Sources/MewponDesktop" -name '*.swift' > "$PWD/.build/intent-sources.txt"
find "$BIN_DIR/MewponDesktop.build" -name '*.swiftconstvalues' > "$PWD/.build/intent-constants.txt"
xcrun appintentsmetadataprocessor --module-name MewponDesktop --output "$APP_DIR/Contents/Resources" --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 --source-file-list "$PWD/.build/intent-sources.txt" --swift-const-vals-list "$PWD/.build/intent-constants.txt"
test -f "$APP_DIR/Contents/Resources/Metadata.appintents/extract.actionsdata"
# App Intents IPC requires a stable development identity on this machine.
# Prefer an explicit identity; auto-select only when there is exactly one.
SIGNING_IDENTITY="${MEWPON_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2}')"
    if [[ -n "$IDENTITIES" && "$(printf '%s\n' "$IDENTITIES" | wc -l | tr -d ' ')" == 1 ]]; then
        SIGNING_IDENTITY="$IDENTITIES"
    fi
fi
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>' > "$PWD/.build/Mewpon.entitlements"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    printf '%s\n' 'Warning: ad-hoc signing; select MEWPON_SIGNING_IDENTITY for reliable Shortcuts execution.' >&2
fi
if [[ -d "$APP_DIR/Contents/Resources/Speech/lib" ]]; then
    while IFS= read -r speech_binary; do codesign --force --sign "$SIGNING_IDENTITY" "$speech_binary"; done < <(find "$APP_DIR/Contents/Resources/Speech/lib" -type f)
    codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/Resources/Speech/whisper-cli"
fi
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$PWD/.build/Mewpon.entitlements" "$HELPER_DIR"
if [[ -d "$APP_DIR/Contents/Resources/Diarization/lib" ]]; then
    while IFS= read -r diarization_binary; do codesign --force --sign "$SIGNING_IDENTITY" "$diarization_binary"; done < <(find "$APP_DIR/Contents/Resources/Diarization/lib" -type f)
    codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/Resources/Diarization/mewpon-diarizer"
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" --entitlements "$PWD/.build/Mewpon.entitlements" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
