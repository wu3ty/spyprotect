.PHONY: help build app release run test lint clean install

# CONFIG=debug|release - defaults to debug for fast local iteration.
CONFIG ?= debug
APP := SpyProtect.app
BUNDLE_ID := dev.stefanguericke.SpyProtect

help:
	@echo "make build     - swift build (CONFIG=debug|release, default debug)"
	@echo "make app       - build and package $(APP) (CONFIG=debug|release)"
	@echo "make release   - shortcut for 'make app CONFIG=release'"
	@echo "make run       - build $(APP) (debug) and relaunch it"
	@echo "make test      - run unit tests"
	@echo "make lint      - run 'swift format lint'"
	@echo "make clean     - remove .build and $(APP)"
	@echo "make install   - build a release $(APP) and copy it to /Applications"

build:
	swift build -c $(CONFIG)

# Packages $(APP) with a stable bundle identifier, so macOS treats it as a real app (own
# entry in System Settings > Notifications, own TCC identity for
# CGSessionCopyCurrentDictionary/IOKit, etc.) instead of a bare unsigned executable.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/$(CONFIG)/SpyProtect $(APP)/Contents/MacOS/SpyProtect
	cp Info.plist $(APP)/Contents/Info.plist
	cp Resources/*.icns Resources/*.png $(APP)/Contents/Resources/
	# Ad-hoc sign so the bundle has a stable identity that TCC/Notification Center can
	# key permissions off of across relaunches. This is NOT a Developer ID signature -
	# Gatekeeper still flags downloaded builds as unidentified (see README).
	codesign --force --deep --sign - --identifier $(BUNDLE_ID) $(APP)
	@echo "Built $(APP) ($(CONFIG))"

release:
	$(MAKE) app CONFIG=release

run: app
	-pkill -f "$(APP)/Contents/MacOS/SpyProtect"
	sleep 0.5
	open $(APP)

test:
	swift test

lint:
	swift format lint --recursive Sources Tests Package.swift

clean:
	rm -rf .build $(APP)

install:
	$(MAKE) app CONFIG=release
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "Installed to /Applications/$(APP)"
