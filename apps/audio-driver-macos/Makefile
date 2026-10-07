SHELL := /bin/bash

ROOT := $(abspath ../..)
override VERSION := $(shell "$(ROOT)/scripts/version")
BUILD := $(CURDIR)/build
DRIVER := $(BUILD)/monitorOSAudio.driver
BINARY := $(DRIVER)/Contents/MacOS/monitorOSAudio
SOURCE := $(CURDIR)/MonitorOSAudio.c
INFO := $(CURDIR)/Info.plist
CODESIGN_IDENTITY ?= -
CODESIGN_FLAGS ?=

.PHONY: all driver verify clean

all: driver

driver:
	rm -rf "$(DRIVER)"
	mkdir -p "$(DRIVER)/Contents/MacOS"
	install -m644 "$(INFO)" "$(DRIVER)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(VERSION)" "$(DRIVER)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $(VERSION)" "$(DRIVER)/Contents/Info.plist"
	xcrun clang -std=c11 -O2 -fblocks -mmacosx-version-min=13.0 \
		-bundle -framework CoreAudio -framework CoreFoundation \
		"$(SOURCE)" -o "$(BINARY)"
	/usr/bin/codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_IDENTITY)" "$(DRIVER)"

verify: driver
	/usr/bin/plutil -lint "$(DRIVER)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(DRIVER)/Contents/Info.plist" | grep -Fx 'com.monitorOS.audio'
	/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(DRIVER)/Contents/Info.plist" | grep -Fx "$(VERSION)"
	/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(DRIVER)/Contents/Info.plist" | grep -Fx "$(VERSION)"
	/usr/bin/codesign --verify --strict "$(DRIVER)"
	@test -x "$(BINARY)"

clean:
	rm -rf "$(BUILD)"
