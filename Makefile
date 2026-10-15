# NuonuoChuuby — terminal-first build, test and packaging.
#
# The app is assembled by hand: no Xcode project, no `xcodebuild`. `swift build`
# produces the executable, and `make app` assembles a `.app` skeleton whose
# Info.plist is patched with the version at package time and whose resource
# folder (`Contents/Resources/Assets.bundle`) is built by hand as well — SwiftPM's
# own resource bundle is not used. A development run hard-links the seeded assets
# instead of copying them (see DEV_ASSETS).
#
# Always launch the bundle with `make run` (or `open`). macOS ties automation
# decisions to the signature, so an ad-hoc rebuild loses them on every build —
# sign with the self-signed certificate instead (see SIGN_IDENTITY).

SHELL := /bin/sh

APP_NAME := NuonuoChuuby
DISPLAY_NAME := 糯糯啾比
BUNDLE_ID := com.balthild.NuonuoChuuby
CORE_TARGET := NuonuoChuubyCore

CONFIG ?= debug
FLAGS ?=

# Signing.
#
#   SIGN_IDENTITY=auto     (default) sign with the self-signed certificate whose
#                          Designated Requirement stays stable across rebuilds,
#                          so macOS keeps the automation grant. Fetched via
#                          SIGNING_SOURCE:
#                            op   (default) 1Password, the OP_ITEM_REF item below
#                            env            $SIGNING_P12_BASE64 + $SIGNING_P12_PASSWORD
#   SIGN_IDENTITY=-        ad-hoc. Nothing to set up, but grants are forgotten
#                          on every rebuild.
#   SIGN_IDENTITY=<name>   an identity already in a keychain.
#
# SIGN_OPTIONS is empty on purpose: hardened runtime has no team to pin under a
# self-signed certificate, and --timestamp wants Apple's TSA.
SIGN_IDENTITY ?= auto
SIGNING_SOURCE ?= op
OP_ITEM_REF ?= CalendarShouter Signing
SIGN_OPTIONS ?=

UPSTREAM_SUBMODULE := Vendor/JiuNuoDesktopPet

GIT_VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
VERSION ?= $(if $(GIT_VERSION),$(GIT_VERSION),0.0.0)
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

BUILD_DIR := .build
DIST_DIR := $(BUILD_DIR)/dist
APP_DIR := $(BUILD_DIR)/app
APP_BUNDLE := $(APP_DIR)/$(APP_NAME).app
# Recursive, not `:=`: `run`/`rerun` set CONFIG with a target-specific variable, and
# a simply-expanded BIN_DIR would freeze to `.build/debug` at parse time — so `app`
# would keep copying a stale binary while `build` compiled the release one.
BIN_DIR = $(BUILD_DIR)/$(CONFIG)

# The manifest (pinned commit + file list) is generated into a git-ignored Swift
# source and compiled in; the artwork is assembled into the .app by hand at
# `Contents/Resources/Assets.bundle/Assets`, which the program reads through
# `Bundle.main.resourceURL`. A development run (`run`/`rerun`) hard-links the
# submodule's assets into it instead of copying them. Off by default, so
# `make app`/`package` stay self-contained and fetch the artwork on first launch.
DEV_ASSETS ?=

MANIFEST_SWIFT := Sources/$(CORE_TARGET)/Asset/AssetManifest.swift
TEST_ASSETS_DIR := $(BUILD_DIR)/test-assets
INFO_PLIST := App/Info.plist
ICONSET_DIR := $(BUILD_DIR)/$(APP_NAME).iconset
ICNS := $(BUILD_DIR)/$(APP_NAME).icns

SWIFT := swift
PLIST_BUDDY := /usr/libexec/PlistBuddy

.DEFAULT_GOAL := help

.PHONY: help format lint manifest icon build test app sign signing-cert package run rerun dev reset-data clean release

help: ## Show this help.
	@printf '%s\n' "$(DISPLAY_NAME) $(VERSION) — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%s\t\033[0m %s\n", $$1, $$2}' | column -t -s $$'\t'

format: ## Format the sources in place (Swift via swift-format, JSON via dprint).
	dprint fmt

lint: ## Report formatting violations, changing nothing.
	dprint check

manifest: ## Regenerate the compiled-in asset manifest from the submodule.
	Tools/generate-asset-manifest.sh "$(UPSTREAM_SUBMODULE)" "$(MANIFEST_SWIFT)"

icon: ## Generate AppIcon.icns, drawing the artwork from source.
	@mkdir -p "$(BUILD_DIR)"
	$(SWIFT) Tools/GenerateAppIcon.swift "$(ICONSET_DIR)"
	iconutil --convert icns --output "$(ICNS)" "$(ICONSET_DIR)"

build: manifest ## Build the executable.
	$(SWIFT) build -c $(CONFIG) $(FLAGS)

test: manifest ## Run the test suite (assets hard-linked from the submodule).
	@Tools/link-assets.sh "$(UPSTREAM_SUBMODULE)" "$(TEST_ASSETS_DIR)"
	@NUONUO_ASSET_ROOT="$(TEST_ASSETS_DIR)" $(SWIFT) test -c $(CONFIG)

app: build icon ## Assemble the .app bundle.
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BIN_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@if [ "$(DEV_ASSETS)" = "1" ]; then \
		Tools/link-assets.sh "$(UPSTREAM_SUBMODULE)" \
			"$(APP_BUNDLE)/Contents/Resources/Assets.bundle/Assets"; \
	fi
	@if [ -f "$(ICNS)" ]; then cp "$(ICNS)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"; fi
	@cp LICENSE NOTICE "$(APP_BUNDLE)/Contents/Resources/"
	@cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@$(PLIST_BUDDY) -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP_BUNDLE)/Contents/Info.plist"
	@$(PLIST_BUDDY) -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(APP_BUNDLE)/Contents/Info.plist"
	@plutil -lint "$(APP_BUNDLE)/Contents/Info.plist"
	@printf '%s\n' "Assembled $(APP_BUNDLE)"

sign: app ## Codesign the app bundle (see SIGN_IDENTITY).
	@SIGN_IDENTITY='$(SIGN_IDENTITY)' SIGNING_SOURCE='$(SIGNING_SOURCE)' \
		SIGN_OPTIONS='$(SIGN_OPTIONS)' OP_ITEM_REF='$(OP_ITEM_REF)' \
		Tools/sign-app.sh "$(APP_BUNDLE)"
	@codesign --verify --verbose=2 "$(APP_BUNDLE)"

signing-cert: ## Create the self-signed certificate the app is signed with.
	Tools/create-signing-cert.sh "$(BUILD_DIR)/signing"

package: sign ## Produce a distributable zip in .build/dist.
	@mkdir -p "$(DIST_DIR)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(DIST_DIR)/$(APP_NAME)-$(VERSION).zip"
	@printf '%s\n' "Created $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip"

run: DEV_ASSETS := 1
run: CONFIG = release
run: FLAGS = -Xswiftc -g
run: sign ## Build, bundle and launch the app.
	open "$(APP_BUNDLE)"

rerun: APP_ARGS ?=
rerun: DEV_ASSETS := 1
rerun: CONFIG = release
rerun: FLAGS = -Xswiftc -g
rerun: sign ## Build, bundle and relaunch the app with arguments.
	@pkill -f "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" || true
	open -n "$(APP_BUNDLE)" --args $(APP_ARGS)

dev: ## Run without a bundle. Automation-based features do not work.
	$(SWIFT) run -c $(CONFIG)

reset-data: ## Forget the app's preferences and pet state.
	@pkill -f "$(APP_BUNDLE)/Contents/MacOS" 2>/dev/null || true
	@-defaults delete $(BUNDLE_ID)
	@-rm -rf "$$HOME/Library/Application Support/$(APP_NAME)"
	@printf '%s\n' "Preferences and state cleared."

clean: ## Remove all build products.
	rm -rf "$(BUILD_DIR)"
	@rm -f "$(MANIFEST_SWIFT)"

release: ## Clean release build: tested, then packaged WITHOUT the artwork.
	$(MAKE) clean
	$(MAKE) CONFIG=release test
	$(MAKE) CONFIG=release package
