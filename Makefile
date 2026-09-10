PREFIX ?= /usr/local
APP_NAME := QuickSave
BUNDLE_ID := com.wangxiaoyu.quicksave
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: all clean install uninstall launch codesign

all: $(APP_BUNDLE)

$(APP_BUNDLE): Sources/main.swift Resources/Info.plist
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	swiftc -O \
		-target arm64-apple-macos13.0 \
		-framework AppKit -framework ApplicationServices -framework Carbon \
		-framework ServiceManagement -framework UserNotifications \
		Sources/main.swift -o $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	codesign --force --sign - $(APP_BUNDLE) 2>/dev/null || true
	@echo "Built $(APP_BUNDLE)"

codesign: $(APP_BUNDLE)
	codesign --force --sign - $(APP_BUNDLE)

launch: $(APP_BUNDLE)
	open $(APP_BUNDLE)

install: $(APP_BUNDLE)
	mkdir -p $(PREFIX)/bin
	cp -R $(APP_BUNDLE) $(PREFIX)/bin/
	@echo "Installed to $(PREFIX)/bin/$(APP_NAME).app"

uninstall:
	rm -rf $(PREFIX)/bin/$(APP_NAME).app

clean:
	rm -rf $(BUILD_DIR)
