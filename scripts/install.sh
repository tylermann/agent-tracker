#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
source "$SCRIPT_DIR/env.sh"
"$SCRIPT_DIR/build-app.sh" release
/usr/bin/ditto "$PROJECT_DIR/dist/$APP_BUNDLE_NAME" "/Applications/$APP_BUNDLE_NAME"
echo "Installed /Applications/$APP_BUNDLE_NAME"
echo "Open it, grant the requested permissions, then choose Settings > Install or Repair."
