#!/bin/bash

# Build script for Life Just Happening macOS menu bar app
# Creates a proper .app bundle from the Swift Package build

set -e

APP_NAME="Life Just Happening"
BUNDLE_ID="com.yanniccharlon.lifejusthappening"
EXECUTABLE_NAME="LifeJustHappening"

# Build the Swift package
echo "Building Swift package..."
swift build -c release

# Create app bundle structure
APP_DIR="$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Creating app bundle structure..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
echo "Copying executable..."
cp ".build/release/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"

# Copy Info.plist
echo "Copying Info.plist..."
cp "Sources/LifeJustHappening/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# Copy entitlements (for reference, actual signing uses these)
cp "Sources/LifeJustHappening/Resources/LifeJustHappening.entitlements" "$CONTENTS_DIR/"

# Create PkgInfo
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Copy resources if they exist
if [ -d ".build/release/LifeJustHappening_LifeJustHappening.bundle" ]; then
    echo "Copying resources..."
    cp -R ".build/release/LifeJustHappening_LifeJustHappening.bundle/Contents/Resources/"* "$RESOURCES_DIR/" 2>/dev/null || true
fi

echo ""
echo "App bundle created: $APP_DIR"
echo ""
echo "To install:"
echo "  1. Move '$APP_DIR' to /Applications"
echo "  2. For development, you can run it directly: open '$APP_DIR'"
echo ""
echo "For distribution, sign the app with:"
echo "  codesign --deep --force --sign \"Developer ID Application: Your Name\" --entitlements \"$CONTENTS_DIR/LifeJustHappening.entitlements\" \"$APP_DIR\""
