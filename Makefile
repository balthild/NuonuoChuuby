# NuonuoChuuby — terminal-first build, test and packaging.
#
# The app is assembled by hand: no Xcode project, no `xcodebuild`. `swift build`
# produces the executable, and `make app` assembles a `.app` skeleton whose
# Info.plist is generated from `App/Info.plist.template` by `envsubst` and whose
# resource folder (`Contents/Resources/Assets.bundle`) is built by hand as well —
# SwiftPM's own resource bundle is not used. A development run hard-links the
# seeded assets instead of copying them (see DEV_ASSETS).
#
# Always launch the bundle with `make rerun` (or `open`). macOS ties automation
# decisions to the signature, so an ad-hoc rebuild loses them on every build —
# sign with the self-signed certificate instead (see SIGN_IDENTITY).

SHELL = /bin/sh

APP_NAME = NuonuoChuuby
APP_SUFFIX ?=

BUNDLE_ID = com.balthild.NuonuoChuuby$(APP_SUFFIX)
BUNDLE_FILENAME = $(APP_NAME)$(APP_SUFFIX)

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
OP_ITEM_REF ?= NuonuoChuuby-Signing
SIGN_OPTIONS ?=

SVU_PKG := 'nixpkgs\#svu'
SVU_OUT := $(shell nix run $(SVU_PKG) -- --tag.prefix="" current)
SEMVER ?= $(if $(SVU_OUT),$(SVU_OUT),0.0.0)
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

BUILD_DIR := .build
DIST_DIR := $(BUILD_DIR)/dist
APP_DIR := $(BUILD_DIR)/app
BIN_DIR = $(BUILD_DIR)/$(CONFIG)

BUNDLE = $(APP_DIR)/$(BUNDLE_FILENAME).app
PACKAGE = $(DIST_DIR)/$(APP_NAME)-v$(SEMVER).dmg

# The manifest (pinned commit + file list) is generated into a git-ignored Swift
# source and compiled in; the artwork is assembled into the .app by hand at
# `Contents/Resources/Assets.bundle/Assets`, which the program reads through
# `Bundle.main.resourceURL`. A development run (`run`/`rerun`) hard-links the
# submodule's assets into it instead of copying them. Off by default, so
# `make app`/`package` stay self-contained and fetch the artwork on first launch.
DEV_ASSETS ?=

UPSTREAM_SUBMODULE := Vendor/JiuNuoDesktopPet
MANIFEST_SWIFT := Sources/NuonuoChuubyCore/Asset/AssetManifest.swift
TEST_ASSETS_DIR := $(BUILD_DIR)/test-assets

# Substituted by `envsubst` with BUNDLE_ID/SEMVER/BUILD_NUMBER when the bundle is
# assembled; the variable list is passed explicitly so a stray `$` in the
# template cannot be eaten.
INFO_PLIST_TEMPLATE := App/Info.plist.template

# The icon is a single 1024×1024 PNG that `icon` rescales into the iconset
# `iconutil` requires. ICON_VARIANTS is the exact (pixels, filename) mapping it
# insists on; the largest one is the source left untouched.
ICON_SOURCE := Resources/$(APP_NAME).png
ICONSET_DIR := $(BUILD_DIR)/$(APP_NAME).iconset
ICNS := $(BUILD_DIR)/$(APP_NAME).icns
ICON_VARIANTS := \
	16:icon_16x16 32:icon_16x16@2x \
	32:icon_32x32 64:icon_32x32@2x \
	128:icon_128x128 256:icon_128x128@2x \
	256:icon_256x256 512:icon_256x256@2x \
	512:icon_512x512 1024:icon_512x512@2x

.DEFAULT_GOAL := help

.PHONY: help format lint manifest icon build test app sign signing-cert package rerun dev reset-data clean release

help: ## Show this help.
	@printf '%s\n' "$(APP_NAME) $(SEMVER) — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%s\t\033[0m %s\n", $$1, $$2}' | column -t -s $$'\t'

format: ## Format the sources in place (Swift via swift-format, JSON via dprint).
	dprint fmt

lint: ## Report formatting violations, changing nothing.
	dprint check

manifest: ## Regenerate the compiled-in asset manifest from the submodule.
	Tools/generate-asset-manifest.sh "$(UPSTREAM_SUBMODULE)" "$(MANIFEST_SWIFT)"

icon: ## Generate AppIcon.icns from the PNG in Resources.
	@test -f "$(ICON_SOURCE)" || { printf '%s\n' "no icon source: $(ICON_SOURCE)"; exit 1; }
	@rm -rf "$(ICONSET_DIR)"
	@mkdir -p "$(ICONSET_DIR)"
	@for spec in $(ICON_VARIANTS); do \
		pixels=$${spec%%:*}; name=$${spec#*:}; \
		sips -z $$pixels $$pixels --out "$(ICONSET_DIR)/$$name.png" "$(ICON_SOURCE)" >/dev/null; \
	done
	iconutil --convert icns --output "$(ICNS)" "$(ICONSET_DIR)"

build: manifest ## Build the executable.
	swift build -c $(CONFIG) $(FLAGS)

test: manifest ## Run the test suite (assets hard-linked from the submodule).
	@Tools/link-assets.sh "$(UPSTREAM_SUBMODULE)" "$(TEST_ASSETS_DIR)"
	@NUONUO_ASSET_ROOT="$(TEST_ASSETS_DIR)" swift test -c $(CONFIG)

app: build icon ## Assemble the .app bundle.
	@printf '%s\n' "Assembling $(BUNDLE)"
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"

	cp "$(BIN_DIR)/$(APP_NAME)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"

	@if [ "$(DEV_ASSETS)" = "1" ]; then \
		echo "Linking development assets..." \
		Tools/link-assets.sh "$(UPSTREAM_SUBMODULE)" \
			"$(BUNDLE)/Contents/Resources/Assets.bundle/Assets"; \
	fi

	@printf '%s\n' "Copying resources..."
	@if [ -f "$(ICNS)" ]; then cp "$(ICNS)" "$(BUNDLE)/Contents/Resources/AppIcon.icns"; fi
	@cp LICENSE NOTICE "$(BUNDLE)/Contents/Resources/"

	@env \
		BUNDLE_ID='$(BUNDLE_ID)' \
		SEMVER='$(SEMVER)' \
		BUILD_NUMBER='$(BUILD_NUMBER)' \
		nix shell nixpkgs#gettext -c \
		envsubst '$${BUNDLE_ID} $${SEMVER} $${BUILD_NUMBER}' \
		< "$(INFO_PLIST_TEMPLATE)" \
		> "$(BUNDLE)/Contents/Info.plist"

	@if grep -q '\$${' "$(BUNDLE)/Contents/Info.plist"; then \
		printf '%s\n' "Info.plist keeps a literal placeholder: check the envsubst variable list"; \
		exit 1; \
	fi
	@plutil -lint "$(BUNDLE)/Contents/Info.plist"

	@printf '%s\n' "Assembled $(BUNDLE)"

sign: app ## Codesign the app bundle (see SIGN_IDENTITY).
	@echo "Signing $(BUNDLE)"
	@SIGN_IDENTITY='$(SIGN_IDENTITY)' SIGNING_SOURCE='$(SIGNING_SOURCE)' \
		SIGN_OPTIONS='$(SIGN_OPTIONS)' OP_ITEM_REF='$(OP_ITEM_REF)' \
		Tools/sign-app.sh "$(BUNDLE)"
	@codesign --verify --verbose=2 "$(BUNDLE)"

signing-cert: ## Create the self-signed certificate the app is signed with.
	Tools/create-signing-cert.sh "$(BUILD_DIR)/signing"

package: sign ## Produce a distributable disk image in .build/dist.
	@mkdir -p "$(DIST_DIR)"

	swift Tools/dmg-background.swift "$(DIST_DIR)/dmg-background.png"

	@printf '%s\n' "Creating $(PACKAGE)..."
	@nix run 'github:balthild/mkdmg#mkdmg-bin' -- \
		--volname '$(BUNDLE_FILENAME)' \
		--background '$(DIST_DIR)/dmg-background.png' \
		--window-size 600,400 \
		--window-position 400,400 \
		--icon '$(BUNDLE_FILENAME).app':150,190 \
		--app-drop-link 450,190 \
		--output '$(PACKAGE)' \
		'$(BUNDLE)'
	@printf '%s\n' "Created $(PACKAGE)"

rerun: APP_ARGS ?=
rerun: DEV_ASSETS := 1
rerun: CONFIG = release
rerun: FLAGS = -Xswiftc -g
rerun: APP_SUFFIX = -Dev
rerun: sign ## Build, bundle and relaunch the app with arguments.
	pkill -f "Contents/MacOS/$(APP_NAME)" || true
	open -n "$(BUNDLE)" --args $(APP_ARGS)

dev: ## Run without a bundle. Automation-based features do not work.
	swift run -c $(CONFIG)

reset-data: ## Forget the app's settings and pet state.
	pkill -f "Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	rm -rf "$$HOME/Library/Application Support/$(APP_NAME)"
	@printf '%s\n' "Settings and state cleared."

clean: ## Remove all build products.
	rm -rf "$(BUILD_DIR)"
	rm -f "$(MANIFEST_SWIFT)"

release: KIND ?= please-specify
release: ## Clean release build: tested, packaged WITHOUT the artwork, and upload to GitHub.
	Tools/release.sh "$(KIND)"
