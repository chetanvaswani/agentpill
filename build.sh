#!/bin/bash
# Builds build/AgentPill.app.  `./build.sh install` also copies it to ~/Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AgentPill.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/AgentPill" Sources/main.swift -framework AppKit
clang -O2 -o "$APP/Contents/MacOS/pill-hook" Sources/hook.c
cp Info.plist "$APP/Contents/Info.plist"
# Sign with the stable local identity when it exists (see make-cert.sh), so macOS keeps the
# Accessibility permission across rebuilds. Otherwise fall back to ad-hoc, which resets it each time.
IDENTITY="${IDENTITY:-AgentPill Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    SIGN="$IDENTITY"
else
    SIGN="-"
    echo "note: no \"$IDENTITY\" certificate; signing ad-hoc (run ./make-cert.sh once to keep permissions)"
fi
codesign --force --sign "$SIGN" "$APP/Contents/MacOS/pill-hook"
codesign --force --sign "$SIGN" "$APP"

echo "Built $APP (signed: ${SIGN/-/ad-hoc})"

if [ "${1:-}" = "install" ]; then
    pkill -x AgentPill 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/AgentPill.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/AgentPill.app"
    echo "Installed and started ~/Applications/AgentPill.app"
fi
