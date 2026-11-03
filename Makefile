# Format and lint everything: Go with golangci-lint (pinned in tools/go.mod,
# nothing to install), Swift with swift-format (comes with Xcode).

DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR

GOLANGCI := go tool -modfile=tools/go.mod golangci-lint
# Generated Swift (scripts/gen_*.py, HealthUIStringsDump) is left as generated.
SWIFT_FILES = $(shell find ios/Rendu ios/RenduTests -name '*.swift' \
	! -name DisplayNames.swift ! -name TypeCatalogData.swift ! -name HealthUIStrings.swift)
SWIFT_FLAGS := --configuration ios/.swift-format --parallel

.PHONY: icon fmt lint test schema

fmt:
	$(GOLANGCI) fmt
	@xcrun swift-format format $(SWIFT_FLAGS) --in-place $(SWIFT_FILES)

lint:
	$(GOLANGCI) run
	@xcrun swift-format lint $(SWIFT_FLAGS) --strict $(SWIFT_FILES)

test:
	go vet ./...
	go test ./...

# Apple's definitions (types, enums, metadata keys) from the iOS SDK, for
# GET /v1/schema. Run after an Xcode / SDK upgrade, on macOS at least as new.
schema:
	python3 -I ios/scripts/gen_healthkit_schema.py
	python3 -I ios/scripts/audit_healthkit.py

# README logo, rendered from the app icon (ios/Rendu/AppIcon.icon, an Icon
# Composer document) the way iOS draws it.
ICTOOL = /Applications/Xcode-beta.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool
icon:
	"$(ICTOOL)" ios/Rendu/AppIcon.icon --export-image --output-file docs/images/logo.png --platform iOS --rendition Default --width 256 --height 256 --scale 2
	"$(ICTOOL)" ios/Rendu/AppIcon.icon --export-image --output-file docs/images/logo-dark.png --platform iOS --rendition Dark --width 256 --height 256 --scale 2
