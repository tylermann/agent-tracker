.PHONY: build test app install

SWIFT_ENV = env CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/module-cache SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/swiftpm-module-cache

build:
	$(SWIFT_ENV) swift build --disable-sandbox

test:
	$(SWIFT_ENV) swift test --disable-sandbox

app:
	./scripts/build-app.sh release

install:
	./scripts/install.sh
