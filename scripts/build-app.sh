#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
CONFIGURATION=${1:-release}
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
SWIFTPM_CACHE="$PROJECT_DIR/.build/swiftpm-module-cache"

cd "$PROJECT_DIR"
env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
    swift build --disable-sandbox -c "$CONFIGURATION"
BIN_DIR=$(env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
    swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path)

APP_DIR="$PROJECT_DIR/dist/Agent Tracker.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

/bin/mkdir -p "$MACOS_DIR"
/bin/cp "$BIN_DIR/AgentTracker" "$MACOS_DIR/AgentTracker"
/bin/cp "$BIN_DIR/agent-tracker" "$MACOS_DIR/agent-tracker"
/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/chmod 755 "$MACOS_DIR/AgentTracker" "$MACOS_DIR/agent-tracker"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
