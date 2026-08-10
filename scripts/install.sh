#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
"$SCRIPT_DIR/build-app.sh" release
/usr/bin/ditto "$PROJECT_DIR/dist/Agent Tracker.app" "/Applications/Agent Tracker.app"
echo "Installed /Applications/Agent Tracker.app"
echo "Open it, grant the requested permissions, then choose Settings > Install or Repair."
