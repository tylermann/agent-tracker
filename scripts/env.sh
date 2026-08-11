# Shared build configuration sourced by the scripts in this directory.
# Expects PROJECT_DIR to be set by the sourcing script.
# The module-cache overrides keep compiler caches inside .build; the Makefile's SWIFT_ENV
# variable mirrors them for direct `make build`/`make test` runs.
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
SWIFTPM_CACHE="$PROJECT_DIR/.build/swiftpm-module-cache"
APP_BUNDLE_NAME="Agent Tracker.app"

swift_build() {
  env CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
    swift build --disable-sandbox "$@"
}
