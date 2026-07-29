#!/bin/bash
# Build notepad-aaf (native Swift) and package it as a double-clickable .app.
#
# Local use (default) — ad-hoc signed, runs on THIS Mac only:
#     ./build-app.sh
#
# Distribution to another Mac — requires a "Developer ID Application" cert and
# a notarytool keychain profile (see DISTRIBUTING.md):
#     SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=aaf ./build-app.sh
#
# Env knobs:
#   UNIVERSAL=0        build arm64-only (faster; default is universal arm64+x86_64)
#   SIGN_ID="-"        signing identity; "-" means ad-hoc (default, local only)
#   NOTARY_PROFILE=""  notarytool keychain profile; when set, notarize + staple
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL="${UNIVERSAL:-1}"
SIGN_ID="${SIGN_ID:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

APP="notepad-aaf.app"
ZIP="notepad-aaf.zip"

if [ "$UNIVERSAL" = "1" ]; then
    echo "Building universal release binary (arm64 + x86_64)…"
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/notepad-aaf"
else
    echo "Building release binary (arm64 only)…"
    swift build -c release
    BIN=".build/release/notepad-aaf"
fi

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/notepad-aaf"

# App icon: (re)generate AppIcon.icns from the AAF logo, then bundle it.
if [ -f Resources/aaf-logo.png ]; then
    echo "Generating app icon…"
    swift make-icon.swift
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
    rm -rf Resources/AppIcon.iconset
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>notepad-aaf</string>
    <key>CFBundleDisplayName</key>        <string>notepad-aaf</string>
    <key>CFBundleIdentifier</key>         <string>com.aaf.notepad-native</string>
    <key>CFBundleExecutable</key>         <string>notepad-aaf</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundleIconName</key>           <string>AppIcon</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
</dict>
</plist>
PLIST

if [ "$SIGN_ID" = "-" ]; then
    # Ad-hoc: fine on this Mac, but Gatekeeper will reject it on any other Mac.
    codesign --force --sign - "$APP" 2>/dev/null || true
    echo "Built $APP (ad-hoc signed — local use only)"
    echo "Run it with:  open $APP"
else
    # Real signature: hardened runtime + secure timestamp are both required for
    # notarization to succeed.
    echo "Signing with: $SIGN_ID"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"

    # Always ship a ditto zip — it preserves the signature and bundle structure.
    ditto -c -k --keepParent "$APP" "$ZIP"

    if [ -n "$NOTARY_PROFILE" ]; then
        echo "Submitting for notarization (this can take a few minutes)…"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the ticket stapled
        echo "Notarized + stapled."
        spctl -a -vvv "$APP" || true
    else
        echo "Signed but NOT notarized — Gatekeeper will still warn on other Macs."
        echo "Set NOTARY_PROFILE=<profile> to notarize."
    fi
    echo "Built $APP and $ZIP"
fi
