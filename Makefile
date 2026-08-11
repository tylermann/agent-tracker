.PHONY: build test app install format lint clean

# Mirrors the module-cache overrides in scripts/env.sh.
SWIFT_ENV = env CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/module-cache SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/swiftpm-module-cache

build:
	$(SWIFT_ENV) swift build --disable-sandbox

test:
	$(SWIFT_ENV) swift test --disable-sandbox

app:
	./scripts/build-app.sh release

install:
	./scripts/install.sh

format:
	swift format --in-place --recursive Sources Tests Package.swift

lint:
	swift format lint --strict --recursive Sources Tests Package.swift

clean:
	rm -rf .build dist
