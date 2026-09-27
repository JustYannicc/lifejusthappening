#!/bin/bash
# Builds lifejusthappening.app from the Swift package.
#
# Signing decides whether macOS remembers permissions (camera, location, Input Monitoring)
# and Keychain access across rebuilds. It uses, in order:
#   1. $CODESIGN_IDENTITY if set
#   2. the first valid code-signing identity in your keychain (even a self-signed one works)
#   3. ad-hoc, which macOS treats as a brand-new app on every build (permissions reset)

set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="lifejusthappening.app"
EXECUTABLE_NAME="LifeJustHappening"
CONTENTS_DIR="$APP_DIR/Contents"
# Sentry DSN for feedback + crash reports. A DSN is a public client key, so the project's
# lives here as the default; SENTRY_DSN_MAC overrides it, SENTRY_DSN_MAC="" turns Sentry off.
DEFAULT_DSN="https://7b9a42688cabcb6d87a601201359e222@o4511700034584576.ingest.de.sentry.io/4512159141199952"
SENTRY_DSN="${SENTRY_DSN_MAC-$DEFAULT_DSN}"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning | awk -F '"' '/[0-9]+\)/ {print $2; exit}')
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "warning: no code-signing identity found, signing ad-hoc. Permissions will reset on every rebuild."
fi

echo "Building..."
swift build -c release

echo "Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp ".build/release/$EXECUTABLE_NAME" "$CONTENTS_DIR/MacOS/$EXECUTABLE_NAME"
cp "Sources/LifeJustHappening/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SentryDSN string $SENTRY_DSN" "$CONTENTS_DIR/Info.plist"
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

BUNDLE=".build/release/LifeJustHappening_LifeJustHappening.bundle"
if [ -d "$BUNDLE" ]; then
    cp -R "$BUNDLE" "$CONTENTS_DIR/Resources/"
fi

echo "Signing with identity: $IDENTITY"
codesign --force --deep --options runtime \
    --entitlements "Sources/LifeJustHappening/Resources/LifeJustHappening.entitlements" \
    --sign "$IDENTITY" "$APP_DIR"

echo ""
echo "Sentry: $([ -n "$SENTRY_DSN" ] && echo on || echo off)"
echo "Built $APP_DIR. Move it to /Applications, then open it."
