# Common tasks. Run `make help` for the list.

VERSION := $(shell sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$$/\1/p' project.yml)
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Release/Hushhh.app
DMG := build/release/Hushhh-$(VERSION).dmg

.PHONY: help project build debug test install deploy publish clean

help:
	@echo "make build    Build a Release app (build/DerivedData)"
	@echo "make debug    Build a Debug app (build/DerivedData) for developer diagnostics"
	@echo "make test     Run the unit tests"
	@echo "make install  Build, copy to /Applications and relaunch Hushhh"
	@echo "make deploy   Build a signed, notarized DMG ($(DMG))"
	@echo "make publish  Upload the DMG to a GitHub release v$(VERSION) (runs deploy first if needed)"
	@echo "make clean    Remove build output"

project:
	@xcodegen generate >/dev/null

build: project
	xcodebuild -project Hushhh.xcodeproj -scheme Hushhh -configuration Release -derivedDataPath $(DERIVED) build -quiet

debug: project
	xcodebuild -project Hushhh.xcodeproj -scheme Hushhh -configuration Debug -derivedDataPath $(DERIVED) build -quiet

test: project
	xcodebuild -project Hushhh.xcodeproj -scheme HushhhTests -configuration Debug -derivedDataPath $(DERIVED) test -quiet

install: build
	@pkill -TERM -x Hushhh || true
	@sleep 1
	ditto $(APP) /Applications/Hushhh.app
	open /Applications/Hushhh.app

# Signed with Developer ID, notarized by Apple and stapled, in a drag-to-Applications DMG.
deploy:
	scripts/release.sh

$(DMG):
	scripts/release.sh

publish: $(DMG)
	gh release create v$(VERSION) $(DMG) --title "Hushhh $(VERSION)" --generate-notes

clean:
	rm -rf build Vendor/build-qvac
