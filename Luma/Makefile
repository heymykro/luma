# Assembles Luma.app from the SPM build.
#   make app       release build -> build/Luma.app (stripped, ad-hoc signed)
#   make release   app + a zipped, checksummed release artifact
#   make check     self-check the Night Shift binding against the live OS
#   make clean
APP     := build/Luma.app
BINARY  := .build/release/Luma
VERSION   := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
# Sign with the local self-signed identity if it exists, else ad-hoc. Ad-hoc
# derives identity from the binary hash, so EVERY rebuild looks like a new app
# to macOS and drops the Accessibility grant; a stable cert fixes that for good.
SIGN    ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Luma Local" && echo "Luma Local" || echo "-")

.PHONY: app release check clean

app:
	swift build -c release -Xswiftc -Osize
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/Luma
	strip -S -x $(APP)/Contents/MacOS/Luma
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/icon.icns $(APP)/Contents/Resources/
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force --sign "$(SIGN)" -r='designated => identifier "$(BUNDLE_ID)"' $(APP)
	@du -sh $(APP)
	@echo "designated requirement: $$(codesign -d --requirements - $(APP) 2>&1 | tail -1)"

# Checksummed artifacts for a GitHub release. The drag-to-Applications .dmg is
# what the site links; the .zip stays for anyone scripting an install. Each
# ships twice: a versioned name for the record, and a stable name so
# releases/latest/download/Luma.dmg is a permanent URL serving the newest build.
release: app
	@rm -f build/Luma-$(VERSION).zip build/Luma.zip build/Luma-$(VERSION).dmg
	@cd build && ditto -c -k --keepParent Luma.app Luma-$(VERSION).zip
	@cd build && cp Luma-$(VERSION).zip Luma.zip
	@scripts/dmg.sh
	@cd build && cp Luma.dmg Luma-$(VERSION).dmg
	@cd build && shasum -a 256 Luma-$(VERSION).dmg Luma-$(VERSION).zip | tee Luma-$(VERSION).sha256
	@echo "release: build/Luma.dmg + build/Luma.zip (stable names) — v$(VERSION)"

# The script needs to be called main.swift for swiftc to allow top-level code,
# which is why it gets copied rather than compiled where it sits.
check:
	@T=$$(mktemp -d); cp scripts/check-nightshift.swift $$T/main.swift; \
	swiftc Sources/Luma/Engine/NightShift.swift Sources/Luma/Support/Commands.swift \
	       $$T/main.swift -o $$T/check && $$T/check; \
	R=$$?; rm -rf $$T; exit $$R

clean:
	rm -rf .build build
