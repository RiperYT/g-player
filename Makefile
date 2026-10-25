.PHONY: help build test l10n app run release publish wrapper icon clean

help: ## Show targets
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-10s %s\n", $$1, $$2}'

build: ## Debug build of the package
	swift build

test: ## Unit tests (no Wine needed)
	swift test

l10n: ## Check the Ukrainian translation against the code's strings
	scripts/l10n.sh

app: ## Build build/G-Player.app
	scripts/build-app.sh

run: app ## Build and open the app
	open build/G-Player.app

release: ## Disk image of the app in releases/v<VERSION>/
	scripts/release.sh

publish: ## release + create the GitHub release
	scripts/release.sh --publish

wrapper: ## Rebuild the Chromium helper wrapper (mingw-w64)
	scripts/build-wrapper.sh

icon: ## Redraw the app icon
	swift scripts/make-icon.swift build/AppIcon.icns

clean:
	rm -rf .build build
