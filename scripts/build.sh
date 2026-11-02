#!/bin/bash
# Builds build/Ikkunointi.app (and build/ikkunointictl) and code-signs it.
# Signs with the "Ikkunointi Local Signing" identity when present so the Accessibility
# grant survives rebuilds (create it once with scripts/create-signing-cert.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
IDENTITY="${IKKUNOINTI_SIGNING_IDENTITY:-Ikkunointi Local Signing}"
APP="build/Ikkunointi.app"

swift build -c "$CONFIGURATION" --product Ikkunointi
swift build -c "$CONFIGURATION" --product ikkunointictl
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Ikkunointi" "$APP/Contents/MacOS/Ikkunointi"
cp "$BIN/ikkunointictl" "$APP/Contents/MacOS/ikkunointictl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" \
    && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
cp "$BIN/ikkunointictl" build/ikkunointictl

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    SIGN="$IDENTITY"
else
    SIGN="-"
    echo "warning: no '$IDENTITY' certificate; ad-hoc signing (Accessibility must be re-granted after each rebuild)" >&2
fi
codesign --force --sign "$SIGN" --identifier dev.ikkunointi.ikkunointictl build/ikkunointictl
codesign --force --sign "$SIGN" --identifier dev.ikkunointi.ikkunointictl "$APP/Contents/MacOS/ikkunointictl"
codesign --force --sign "$SIGN" "$APP"
echo "Built $APP (signed: $SIGN)"
