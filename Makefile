.PHONY: help build _bundle app release run test lint clean install app-signed notarize release-signed

# CONFIG=debug|release - defaults to debug for fast local iteration.
CONFIG ?= debug
APP := SpyProtect.app
BUNDLE_ID := dev.wu3ty.SpyProtect

# Looked up dynamically from whatever keychain is active (rather than hardcoded), so this
# works whether the Developer ID Application certificate lives in a normal login Keychain
# (local use) or a throwaway keychain created just for a CI run (see release.yml).
SIGNING_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')

help:
	@echo "make build          - swift build (CONFIG=debug|release, default debug)"
	@echo "make app            - build and ad-hoc-sign $(APP) (CONFIG=debug|release)"
	@echo "make release        - shortcut for 'make app CONFIG=release'"
	@echo "make run            - build $(APP) (debug) and relaunch it"
	@echo "make test           - run unit tests"
	@echo "make lint           - run 'swift format lint'"
	@echo "make clean          - remove .build and $(APP)"
	@echo "make install        - build a release $(APP) and copy it to /Applications"
	@echo "make app-signed     - build and sign $(APP) with a Developer ID Application"
	@echo "                      certificate (must already be in the active keychain)"
	@echo "make notarize       - submit $(APP) to Apple for notarization and staple the"
	@echo "                      ticket (requires APPLE_TEAM_ID, APPLE_ID,"
	@echo "                      APPLE_APP_SPECIFIC_PASSWORD env vars)"
	@echo "make release-signed - app-signed (release) + notarize, in one step"

build:
	swift build -c $(CONFIG)

# Assembles $(APP)'s directory structure and contents, unsigned. Shared by both the
# ad-hoc `app` target (local dev) and the Developer ID `app-signed` target (releases) so
# the bundling steps aren't duplicated between them.
_bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/$(CONFIG)/SpyProtect $(APP)/Contents/MacOS/SpyProtect
	cp Info.plist $(APP)/Contents/Info.plist
	cp Resources/*.icns Resources/*.png $(APP)/Contents/Resources/

# Packages $(APP) with a stable bundle identifier, so macOS treats it as a real app (own
# entry in System Settings > Notifications, own TCC identity for
# CGSessionCopyCurrentDictionary/IOKit, etc.) instead of a bare unsigned executable.
app: _bundle
	# Ad-hoc sign so the bundle has a stable identity that TCC/Notification Center can
	# key permissions off of across relaunches. This is NOT a Developer ID signature -
	# Gatekeeper still flags downloaded builds as unidentified (see README).
	codesign --force --deep --sign - --identifier $(BUNDLE_ID) $(APP)
	@echo "Built $(APP) ($(CONFIG))"

release:
	$(MAKE) app CONFIG=release

# Signs $(APP) with a real Developer ID Application certificate instead of ad-hoc - the
# certificate must already be imported into the active keychain (see README). Hardened
# runtime (--options runtime) and a secure timestamp are both required by Apple for
# notarization to succeed.
app-signed: _bundle
	@if [ -z "$(SIGNING_IDENTITY)" ]; then \
		echo "No 'Developer ID Application' certificate found in the active keychain." >&2; \
		exit 1; \
	fi
	codesign --force --deep --options runtime --timestamp --sign "$(SIGNING_IDENTITY)" $(APP)
	@echo "Signed $(APP) with: $(SIGNING_IDENTITY)"

# Submits the already-signed $(APP) to Apple's notary service and staples the resulting
# ticket to it, so Gatekeeper can verify it offline (no network call needed at launch on
# the end user's machine). Requires APPLE_TEAM_ID, APPLE_ID, and
# APPLE_APP_SPECIFIC_PASSWORD in the environment.
notarize:
	@if [ -z "$(APPLE_TEAM_ID)" ] || [ -z "$(APPLE_ID)" ] || [ -z "$(APPLE_APP_SPECIFIC_PASSWORD)" ]; then \
		echo "APPLE_TEAM_ID, APPLE_ID, and APPLE_APP_SPECIFIC_PASSWORD must all be set." >&2; \
		exit 1; \
	fi
	ditto -c -k --sequesterRsrc --keepParent $(APP) notarize-submission.zip
	xcrun notarytool submit notarize-submission.zip \
		--apple-id "$(APPLE_ID)" --team-id "$(APPLE_TEAM_ID)" --password "$(APPLE_APP_SPECIFIC_PASSWORD)" \
		--wait
	xcrun stapler staple $(APP)
	rm -f notarize-submission.zip
	@echo "Notarized and stapled $(APP)"

release-signed:
	$(MAKE) app-signed CONFIG=release
	$(MAKE) notarize

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
