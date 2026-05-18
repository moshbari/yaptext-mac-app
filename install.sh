#!/bin/bash

# ============================================================
#  YapTextMac — One-Paste Installer
#  Just paste this entire script into Terminal and press Enter.
#  It will build and install YapTextMac on your Desktop.
# ============================================================

set -e

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           🎙️  YapTextMac Installer  🎙️                 ║"
echo "║     Voice Dictation powered by OpenAI Whisper           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# --------------------------------------------------
# 1. Check for Xcode Command Line Tools
# --------------------------------------------------
echo "🔍 Step 1/6: Checking for Xcode tools..."

if ! xcode-select -p &>/dev/null; then
    echo ""
    echo "⚠️  Xcode Command Line Tools not found."
    echo "   A popup will appear — click 'Install' and wait for it to finish."
    echo "   Then run this script again."
    echo ""
    xcode-select --install
    exit 1
fi

if ! command -v swiftc &>/dev/null; then
    echo ""
    echo "⚠️  Swift compiler not found."
    echo "   You need Xcode installed from the App Store."
    echo "   1. Open App Store → search 'Xcode' → Install"
    echo "   2. Open Xcode once and accept the license"
    echo "   3. Run this script again"
    echo ""
    exit 1
fi

echo "   ✅ Xcode tools found!"

# --------------------------------------------------
# 2. Create temporary build directory
# --------------------------------------------------
echo "📁 Step 2/6: Setting up build folder..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$HOME/.yaptextmac-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/YapTextMac.app/Contents/MacOS"
mkdir -p "$BUILD_DIR/YapTextMac.app/Contents/Resources"

echo "   ✅ Build folder ready!"

# --------------------------------------------------
# 3. Copy source files
# --------------------------------------------------
echo "📝 Step 3/6: Preparing source code..."

SOURCE_DIR="$SCRIPT_DIR/YapTextMac"
if [ ! -d "$SOURCE_DIR" ]; then
    echo "⚠️  Cannot find YapTextMac source folder."
    echo "   Make sure you run this script from the repo root."
    exit 1
fi

echo "   ✅ Source code ready!"

# --------------------------------------------------
# 4. Write Info.plist
# --------------------------------------------------
echo "📋 Step 4/6: Creating app bundle..."

cp "$SOURCE_DIR/Info.plist" "$BUILD_DIR/YapTextMac.app/Contents/Info.plist"

# App icon — Info.plist references AppIcon.icns in Resources/
if [ -f "$SOURCE_DIR/AppIcon.icns" ]; then
    cp "$SOURCE_DIR/AppIcon.icns" "$BUILD_DIR/YapTextMac.app/Contents/Resources/AppIcon.icns"
fi

echo "   ✅ App bundle created!"

# --------------------------------------------------
# 5. Compile
# --------------------------------------------------
echo "🔨 Step 5/6: Compiling (this takes 15-30 seconds)..."

swiftc \
    -o "$BUILD_DIR/YapTextMac.app/Contents/MacOS/YapTextMac" \
    -target "$(uname -m)-apple-macosx13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework Carbon \
    -framework ApplicationServices \
    -framework Security \
    -parse-as-library \
    -O \
    "$SOURCE_DIR/TranscriptionManager.swift" \
    "$SOURCE_DIR/SarvamService.swift" \
    "$SOURCE_DIR/PolishService.swift" \
    "$SOURCE_DIR/HistoryManager.swift" \
    "$SOURCE_DIR/HistoryWindow.swift" \
    "$SOURCE_DIR/PendingRecordingsManager.swift" \
    "$SOURCE_DIR/MainView.swift" \
    "$SOURCE_DIR/AppDelegate.swift" \
    "$SOURCE_DIR/YapTextMacApp.swift" \
    2>&1

if [ $? -ne 0 ]; then
    echo ""
    echo "❌ Compilation failed. This usually means:"
    echo "   1. Xcode is not fully installed (open Xcode once to finish setup)"
    echo "   2. Your macOS version is too old (need 13.0+)"
    echo ""
    exit 1
fi

echo "   ✅ Compilation successful!"

# --------------------------------------------------
# 6. Install to /Applications (fallback to Desktop)
# --------------------------------------------------
echo "📦 Step 6/6: Installing..."

# Prefer /Applications, fall back to Desktop if not writable
if [ -w "/Applications" ]; then
    DEST="/Applications/YapTextMac.app"
    INSTALL_LOCATION="/Applications"
else
    DEST="$HOME/Desktop/YapTextMac.app"
    INSTALL_LOCATION="Desktop"
    echo "   ℹ️  /Applications is not writable — installing to Desktop instead."
fi

# If the app is currently running, the binary is locked. Try to quit it first.
osascript -e 'tell application "YapTextMac" to quit' 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$BUILD_DIR/YapTextMac.app" "$DEST"

rm -rf "$BUILD_DIR"

# --------------------------------------------------
#  Code signing — ad-hoc
# --------------------------------------------------
# We tried a self-signed cert in a dedicated keychain (commit history has
# the details) to keep the cdhash stable and persist AX across rebuilds.
# TCC rejected the grant — toggling YapTextMac ON in Settings recorded the
# row but AXIsProcessTrusted() kept returning false. Reverted to ad-hoc.
# Cost: user re-grants AX after each install. Benefit: it actually works.
#
# Clean up any leftover from the cert experiment so it can't interfere.
LEGACY_CERT_KEYCHAIN="$HOME/Library/Application Support/YapTextMac/codesign.keychain-db"
if [ -f "$LEGACY_CERT_KEYCHAIN" ]; then
    security delete-keychain "$LEGACY_CERT_KEYCHAIN" >/dev/null 2>&1 || true
    rm -f "$LEGACY_CERT_KEYCHAIN"
fi

codesign --force --deep --sign - "$DEST" 2>/dev/null

# Every rebuild gives the ad-hoc binary a new cdhash, which invalidates
# the previous AX grant. Wipe the stale row so the next launch gives the
# user a fresh, working grant flow instead of a half-broken stale one.
tccutil reset Accessibility com.moshbari.yaptextmac >/dev/null 2>&1 || true
tccutil reset PostEvent com.moshbari.yaptextmac >/dev/null 2>&1 || true

echo "   ✅ Installed to $INSTALL_LOCATION!"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                  🎉 ALL DONE! 🎉                       ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  YapTextMac.app is installed!                            ║"
echo "║  Location: $INSTALL_LOCATION"
echo "║                                                          ║"
echo "║  TO START:                                               ║"
echo "║  1. Open Finder → Applications → YapTextMac.app          ║"
echo "║  2. Click the 🎙️ mic icon in your menu bar               ║"
echo "║  3. Click the gear ⚙️ → paste your OpenAI + Sarvam keys  ║"
echo "║  4. Dictate using one of the shortcuts:                  ║"
echo "║     • ⌘⇧D = English  (OpenAI Whisper)                   ║"
echo "║     • ⌘⇧E = Bengali  (Sarvam)                           ║"
echo "║     • ⌘⇧P = Banglish (Sarvam translit)                  ║"
echo "║                                                          ║"
echo "║  FIRST TIME: macOS may say 'unidentified developer'.     ║"
echo "║  Fix: Right-click the app → Open → click 'Open'          ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

read -p "🚀 Launch YapTextMac now? (y/n): " LAUNCH
if [[ "$LAUNCH" == "y" || "$LAUNCH" == "Y" ]]; then
    open "$DEST"
    echo "   ✅ Launched! Look for the mic icon in your menu bar."
    echo ""
    echo "🔐 IMPORTANT: Accessibility must be re-granted (the rebuild invalidated"
    echo "   the previous grant). I'm opening System Settings → Accessibility."
    echo ""
    echo "   In that pane:"
    echo "   1. If you see an existing 'YapTextMac' entry, REMOVE it with the '−' button."
    echo "   2. Click the '+' button, navigate to /Applications, pick YapTextMac.app."
    echo "   3. Toggle YapTextMac ON."
    echo "   4. Auto-paste will work from your next dictation onward."
    sleep 1
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
fi
