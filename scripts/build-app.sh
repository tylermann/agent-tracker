#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
CONFIGURATION=${1:-release}
source "$SCRIPT_DIR/env.sh"

cd "$PROJECT_DIR"
swift_build -c "$CONFIGURATION"
BIN_DIR=$(swift_build -c "$CONFIGURATION" --show-bin-path)

APP_DIR="$PROJECT_DIR/dist/$APP_BUNDLE_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
CLI_APP_DIR="$HELPERS_DIR/Agent Tracker CLI.app"
CLI_CONTENTS_DIR="$CLI_APP_DIR/Contents"
CLI_MACOS_DIR="$CLI_CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
RESOURCE_BUNDLE="$BIN_DIR/AgentTracker_AgentTrackerApp.bundle"

/bin/mkdir -p "$MACOS_DIR"
/bin/cp "$BIN_DIR/AgentTracker" "$MACOS_DIR/AgentTracker"
/bin/mkdir -p "$CLI_MACOS_DIR"
/bin/cp "$BIN_DIR/agent-tracker" "$CLI_MACOS_DIR/agent-tracker"
/bin/cp "$PROJECT_DIR/Resources/CLI-Info.plist" "$CLI_CONTENTS_DIR/Info.plist"
# Preserve paths written by older integration installs without running the CLI binary from the
# main app's MacOS directory. A Mach-O helper there inherits the GUI bundle identity and poisons
# Launch Services when short-lived hooks exit.
/bin/cp "$PROJECT_DIR/scripts/agent-tracker-shim" "$MACOS_DIR/agent-tracker"
/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/mkdir -p "$RESOURCES_DIR"
/bin/cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
/bin/chmod 755 "$MACOS_DIR/AgentTracker" "$MACOS_DIR/agent-tracker" "$CLI_MACOS_DIR/agent-tracker"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
