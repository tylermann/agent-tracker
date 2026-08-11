#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
source "$SCRIPT_DIR/env.sh"
"$SCRIPT_DIR/build-app.sh" release

# Never replace the bundle underneath a running GUI process. Besides leaving old code resident,
# doing so can confuse macOS services that validate the running process against its on-disk code
# signature. SIGTERM lets the application shut down normally without an Automation permission.
if /usr/bin/pgrep -x AgentTracker >/dev/null; then
  echo "Stopping the running Agent Tracker app..."
  /usr/bin/pkill -TERM -x AgentTracker
  for _ in {1..50}; do
    if ! /usr/bin/pgrep -x AgentTracker >/dev/null; then
      break
    fi
    /bin/sleep 0.1
  done
  if /usr/bin/pgrep -x AgentTracker >/dev/null; then
    echo "Agent Tracker did not stop; refusing to replace its running bundle." >&2
    exit 1
  fi
fi

/usr/bin/ditto "$PROJECT_DIR/dist/$APP_BUNDLE_NAME" "/Applications/$APP_BUNDLE_NAME"
echo "Installed /Applications/$APP_BUNDLE_NAME"
/usr/bin/open "/Applications/$APP_BUNDLE_NAME"
echo "Opened Agent Tracker. Grant requested permissions, then choose Settings > Install or Repair."
