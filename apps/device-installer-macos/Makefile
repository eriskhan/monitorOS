SHELL := /bin/bash

CONFIGURATION ?= release
ROOT := $(abspath ../..)
override VERSION := $(shell "$(ROOT)/scripts/version")
DIST := $(CURDIR)/dist
PKG_ROOT := $(DIST)/pkgroot
PACKAGE := $(DIST)/monitorOS.pkg
CONTROLLER_APP := $(PKG_ROOT)/Applications/monitorOS.app
UNINSTALLER_APP := $(PKG_ROOT)/Applications/Utilities/monitorOS/Remove monitorOS.app
CONTROLLER_BINARY := $(ROOT)/apps/controller-macos/.build/$(CONFIGURATION)/monitoros-controller
UNINSTALLER_BINARY := $(CURDIR)/.build/$(CONFIGURATION)/monitoros-uninstaller
HELPER_BINARY := $(ROOT)/apps/helper-macos/.build/$(CONFIGURATION)/monitoros-helper
AUDIO_DRIVER := $(ROOT)/apps/audio-driver-macos/build/monitorOSAudio.driver
APP_ICON := $(ROOT)/apps/controller-macos/Packaging/monitorOS.icns
UNINSTALLER_ARTWORK := $(CURDIR)/Resources/imac.svg
UNINSTALLER_ICON := $(CURDIR)/Packaging/monitorOS.icns
SCRIPTS := $(CURDIR)/Packaging/scripts
PACKAGE_ID := com.monitorOS.pkg
GIT_HEAD := $(shell git -C "$(ROOT)" rev-parse HEAD 2>/dev/null || printf 'unknown')

CODESIGN_IDENTITY ?= -
INSTALLER_IDENTITY ?=

ifeq ($(CODESIGN_IDENTITY),-)
CODESIGN_FLAGS :=
else
CODESIGN_FLAGS := --options runtime --timestamp
endif

.PHONY: all pkg build assemble clean verify

all: pkg

build:
	swift build -c "$(CONFIGURATION)" --package-path "$(ROOT)/apps/helper-macos"
	swift build -c "$(CONFIGURATION)" --package-path "$(ROOT)/apps/controller-macos"
	$(MAKE) -C "$(ROOT)/apps/audio-driver-macos" driver \
		CODESIGN_IDENTITY="$(CODESIGN_IDENTITY)" \
		CODESIGN_FLAGS="$(CODESIGN_FLAGS)"
	swift build -c "$(CONFIGURATION)" --package-path "$(CURDIR)"

assemble: build
	rm -rf "$(DIST)"
	mkdir -p \
		"$(CONTROLLER_APP)/Contents/MacOS" \
		"$(CONTROLLER_APP)/Contents/Helpers" \
		"$(CONTROLLER_APP)/Contents/Resources" \
		"$(UNINSTALLER_APP)/Contents/MacOS" \
		"$(UNINSTALLER_APP)/Contents/Resources" \
		"$(PKG_ROOT)/Library/Audio/Plug-Ins/HAL"

	install -m755 "$(CONTROLLER_BINARY)" "$(CONTROLLER_APP)/Contents/MacOS/monitoros-controller"
	install -m755 "$(HELPER_BINARY)" "$(CONTROLLER_APP)/Contents/Helpers/monitoros-helper"
	install -m644 "$(ROOT)/apps/controller-macos/Packaging/Info.plist" "$(CONTROLLER_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(VERSION)" "$(CONTROLLER_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $(VERSION)" "$(CONTROLLER_APP)/Contents/Info.plist"
	install -m644 "$(APP_ICON)" "$(CONTROLLER_APP)/Contents/Resources/monitorOS.icns"
	printf '%s\n' "$(GIT_HEAD)" > "$(CONTROLLER_APP)/Contents/Resources/git-head.txt"
	/usr/bin/codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_IDENTITY)" "$(CONTROLLER_APP)/Contents/Helpers/monitoros-helper"
	/usr/bin/codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_IDENTITY)" "$(CONTROLLER_APP)"
	/usr/bin/codesign --verify --deep --strict "$(CONTROLLER_APP)"

	install -m755 "$(UNINSTALLER_BINARY)" "$(UNINSTALLER_APP)/Contents/MacOS/monitoros-uninstaller"
	install -m644 Packaging/Info-uninstaller.plist "$(UNINSTALLER_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(VERSION)" "$(UNINSTALLER_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $(VERSION)" "$(UNINSTALLER_APP)/Contents/Info.plist"
	install -m644 "$(UNINSTALLER_ARTWORK)" "$(UNINSTALLER_APP)/Contents/Resources/imac.svg"
	install -m644 "$(UNINSTALLER_ICON)" "$(UNINSTALLER_APP)/Contents/Resources/monitorOS.icns"
	/usr/bin/codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_IDENTITY)" "$(UNINSTALLER_APP)"
	/usr/bin/codesign --verify --strict "$(UNINSTALLER_APP)"

	/usr/bin/ditto "$(AUDIO_DRIVER)" "$(PKG_ROOT)/Library/Audio/Plug-Ins/HAL/monitorOSAudio.driver"
	/usr/bin/codesign --verify --strict "$(PKG_ROOT)/Library/Audio/Plug-Ins/HAL/monitorOSAudio.driver"

pkg: assemble
	@if [[ -n "$(INSTALLER_IDENTITY)" && "$(CODESIGN_IDENTITY)" == "-" ]]; then \
		echo "INSTALLER_IDENTITY requires a Developer ID Application CODESIGN_IDENTITY." >&2; \
		exit 2; \
	fi
	@if [[ -n "$(INSTALLER_IDENTITY)" ]]; then \
		/usr/bin/pkgbuild \
			--root "$(PKG_ROOT)" \
			--scripts "$(SCRIPTS)" \
			--identifier "$(PACKAGE_ID)" \
			--version "$(VERSION)" \
			--install-location / \
			--ownership recommended \
			--sign "$(INSTALLER_IDENTITY)" \
			"$(PACKAGE)"; \
	else \
		/usr/bin/pkgbuild \
			--root "$(PKG_ROOT)" \
			--scripts "$(SCRIPTS)" \
			--identifier "$(PACKAGE_ID)" \
			--version "$(VERSION)" \
			--install-location / \
			--ownership recommended \
			"$(PACKAGE)"; \
	fi
	@echo "Built $(PACKAGE)"
	@if [[ "$(CODESIGN_IDENTITY)" == "-" ]]; then \
		echo "App components were ad-hoc signed for local development."; \
	else \
		echo "App components were signed with $(CODESIGN_IDENTITY)."; \
	fi

verify: pkg
	/usr/bin/plutil -lint "$(CONTROLLER_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(CONTROLLER_APP)/Contents/Info.plist" | grep -Fx 'com.monitorOS.controller'
	/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$(CONTROLLER_APP)/Contents/Info.plist" | grep -Fx 'monitorOS.icns'
	/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(CONTROLLER_APP)/Contents/Info.plist" | grep -Fx "$(VERSION)"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(CONTROLLER_APP)/Contents/Info.plist" | grep -Fx "$(VERSION)"
	@test -x "$(CONTROLLER_APP)/Contents/Helpers/monitoros-helper"
	@test -s "$(CONTROLLER_APP)/Contents/Resources/git-head.txt"
	/usr/bin/codesign --verify --deep --strict "$(CONTROLLER_APP)"

	/usr/bin/plutil -lint "$(UNINSTALLER_APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(UNINSTALLER_APP)/Contents/Info.plist" | grep -Fx 'com.monitorOS.uninstaller'
	/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$(UNINSTALLER_APP)/Contents/Info.plist" | grep -Fx 'monitorOS.icns'
	/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(UNINSTALLER_APP)/Contents/Info.plist" | grep -Fx "$(VERSION)"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(UNINSTALLER_APP)/Contents/Info.plist" | grep -Fx "$(VERSION)"
	/usr/bin/codesign --verify --strict "$(UNINSTALLER_APP)"

	@test -d "$(PKG_ROOT)/Library/Audio/Plug-Ins/HAL/monitorOSAudio.driver"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(PKG_ROOT)/Library/Audio/Plug-Ins/HAL/monitorOSAudio.driver/Contents/Info.plist" | grep -Fx "$(VERSION)"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(PKG_ROOT)/Library/Audio/Plug-Ins/HAL/monitorOSAudio.driver/Contents/Info.plist" | grep -Fx "$(VERSION)"
	/usr/bin/codesign --verify --strict "$(PKG_ROOT)/Library/Audio/Plug-Ins/HAL/monitorOSAudio.driver"
	/bin/sh -n "$(SCRIPTS)/preinstall"
	/bin/sh -n "$(SCRIPTS)/postinstall"
	/usr/sbin/pkgutil --payload-files "$(PACKAGE)" | grep -F 'Applications/monitorOS.app/Contents/MacOS/monitoros-controller'
	/usr/sbin/pkgutil --payload-files "$(PACKAGE)" | grep -F 'Applications/monitorOS.app/Contents/Helpers/monitoros-helper'
	/usr/sbin/pkgutil --payload-files "$(PACKAGE)" | grep -F 'Applications/Utilities/monitorOS/Remove monitorOS.app'
	/usr/sbin/pkgutil --payload-files "$(PACKAGE)" | grep -F 'Library/Audio/Plug-Ins/HAL/monitorOSAudio.driver'
	@if [[ -n "$(INSTALLER_IDENTITY)" ]]; then \
		/usr/sbin/pkgutil --check-signature "$(PACKAGE)"; \
	fi

clean:
	rm -rf "$(DIST)"
