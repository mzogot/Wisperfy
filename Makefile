APP       := Wisperfy
EXEC      := Wisperfy
BUNDLE_ID := com.wisperfy.app
CONFIG    ?= debug

# Build products and the staged .app live in ~/Library/Caches, never inside the project.
# Anything under ~/Documents may be file-provider synced, and a sync engine touching
# files mid-compile or stamping xattrs onto a freshly signed bundle breaks both.
STAGE     := $(HOME)/Library/Caches/WisperfyBuild
SCRATCH   := $(STAGE)/scratch
BINARY    := $(SCRATCH)/$(CONFIG)/$(EXEC)
BUNDLE    := $(STAGE)/$(APP).app
CONTENTS  := $(BUNDLE)/Contents

# macOS ties Accessibility and Microphone grants to the code signature. An ad-hoc
# signature changes on every build, which silently invalidates the grant while the
# toggle still shows as on. A Developer ID signature is stable, so grants stick.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

# A Developer ID signature meant for other machines needs a secure timestamp, or it
# stops verifying once the certificate expires and notarization rejects it outright.
# Dev builds skip it because it needs the network and adds a few seconds per build.
ifeq ($(CONFIG),release)
TIMESTAMP := --timestamp
else
TIMESTAMP := --timestamp=none
endif

# `make bump VERSION=x.y.z` passes the target version on the command line, which would
# override a plain VERSION variable. Keep the plist version under a name make cannot clobber.
VERSION_NEW := $(VERSION)
override VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo 0.0.0)
DMG     := $(STAGE)/$(APP)-$(VERSION).dmg

.PHONY: all build test app run install clean logs reset-permissions icon dmg notarize bump release

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

## Unit tests for the pure pieces (formatting, vocabulary, correction diffs).
test:
	swift test --scratch-path "$(SCRATCH)"

## Assemble a real .app bundle. TCC keys permissions on bundle identity and signature,
## so the bare SwiftPM binary cannot be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BINARY)" "$(CONTENTS)/MacOS/$(EXEC)"
	@# SwiftPM resource bundles of dependencies must travel with the binary.
	@for b in "$(SCRATCH)/$(CONFIG)"/*.bundle; do [ -d "$$b" ] && cp -R "$$b" "$(CONTENTS)/Resources/" || true; done
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@# Apache 2.0 (FluidAudio) asks that the license travel with the binary.
	@cp LICENSE THIRD_PARTY_NOTICES.md "$(CONTENTS)/Resources/"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(APP).entitlements \
		--options runtime \
		$(TIMESTAMP) \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Installing to /Applications keeps the path stable, which keeps permission grants stable.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@rm -rf "/Applications/$(APP).app"
	@cp -R "$(BUNDLE)" "/Applications/$(APP).app"
	@open "/Applications/$(APP).app"
	@echo "installed /Applications/$(APP).app"

## Shareable disk image: release build, timestamped signature, app + Applications shortcut.
## Without notarization other Macs show "Apple could not verify" on first open; the
## recipient must right-click > Open once, or approve it in System Settings > Privacy &
## Security. Run `make notarize` afterwards to remove that step (needs credentials, see below).
dmg:
	@$(MAKE) app CONFIG=release
	@rm -rf "$(STAGE)/dmgroot" "$(DMG)"
	@mkdir -p "$(STAGE)/dmgroot"
	@cp -R "$(BUNDLE)" "$(STAGE)/dmgroot/$(APP).app"
	@ln -s /Applications "$(STAGE)/dmgroot/Applications"
	@hdiutil create -quiet -volname "$(APP)" -srcfolder "$(STAGE)/dmgroot" -ov -format UDZO "$(DMG)"
	@rm -rf "$(STAGE)/dmgroot"
	@codesign --force --sign "$(SIGN_ID)" $(TIMESTAMP) "$(DMG)"
	@echo "wrote $(DMG)  [signed: $(SIGN_ID)]"

## Notarize and staple the DMG so Gatekeeper opens it without warnings on other Macs.
## Credentials come from .env.release.local (APPLE_ID, APPLE_PASSWORD = app-specific
## password from account.apple.com, APPLE_TEAM_ID). The file is gitignored.
notarize:
	@test -f "$(DMG)" || { echo "no $(DMG); run make dmg first"; exit 1; }
	@test -f .env.release.local || { echo "missing .env.release.local"; exit 1; }
	@set -a; . ./.env.release.local; set +a; \
	test -n "$$APPLE_ID" -a -n "$$APPLE_PASSWORD" -a -n "$$APPLE_TEAM_ID" \
		|| { echo "fill APPLE_ID, APPLE_PASSWORD and APPLE_TEAM_ID in .env.release.local"; exit 1; }; \
	xcrun notarytool submit "$(DMG)" --apple-id "$$APPLE_ID" --password "$$APPLE_PASSWORD" \
		--team-id "$$APPLE_TEAM_ID" --wait
	xcrun stapler staple "$(DMG)"
	@cp "$(DMG)" "$(HOME)/Desktop/"
	@echo "notarized and stapled $(DMG), copy on Desktop"

## Start a release: move CHANGELOG's Unreleased section under a new version heading and
## bump Info.plist. Review the diff, then commit ("release: x.y.z") and run `make release`.
##   make bump VERSION=0.2.0
bump:
	@test -n "$(VERSION_NEW)" || { echo "usage: make bump VERSION=x.y.z"; exit 1; }
	@echo "$(VERSION_NEW)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "VERSION must be x.y.z"; exit 1; }
	@! grep -q "^## \[$(VERSION_NEW)\]" CHANGELOG.md || { echo "CHANGELOG.md already has $(VERSION_NEW)"; exit 1; }
	@awk -v v="$(VERSION_NEW)" -v d="$$(date +%Y-%m-%d)" -v prev="$(VERSION)" '\
		/^## \[Unreleased\]/ { print; print ""; print "## [" v "] - " d; next } \
		/^\[Unreleased\]: / { sub(/v[0-9.]+\.\.\.HEAD/, "v" v "...HEAD"); print; \
		    print "[" v "]: https://github.com/mzogot/Wisperfy/compare/v" prev "...v" v; next } \
		{ print }' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
	@# sed, not PlistBuddy: PlistBuddy rewrites the whole file, sorting keys and dropping comments.
	@build=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist); \
	sed -i '' -e '/<key>CFBundleShortVersionString<\/key>/{n;s|<string>[^<]*</string>|<string>$(VERSION_NEW)</string>|;}' \
	          -e "/<key>CFBundleVersion<\/key>/{n;s|<string>[^<]*</string>|<string>$$((build + 1))</string>|;}" Resources/Info.plist
	@echo "bumped to $(VERSION_NEW); fill in the CHANGELOG section, commit, then: make release"

## Publish: checks that the changelog and version are in place, then dmg → notarize →
## tag → push → GitHub release with the changelog section as notes.
release:
	@test -z "$$(git status --porcelain)" || { echo "working tree not clean; commit first"; exit 1; }
	@grep -q "^## \[$(VERSION)\] - " CHANGELOG.md || { echo "CHANGELOG.md has no '## [$(VERSION)] - date' section; run make bump VERSION=..."; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || { echo "tag v$(VERSION) already exists"; exit 1; }
	@awk '/^## \[$(VERSION)\]/ { on=1; next } /^## \[|^\[[^ ]*\]: / { on=0 } on' CHANGELOG.md \
		| sed -e :a -e '/^\n*$$/{$$d;N;ba' -e '}' > "$(STAGE)/notes-$(VERSION).md"
	@test -s "$(STAGE)/notes-$(VERSION).md" || { echo "CHANGELOG section for $(VERSION) is empty"; exit 1; }
	@$(MAKE) dmg
	@$(MAKE) notarize
	@git tag -a "v$(VERSION)" -m "Wisperfy $(VERSION)"
	@git push origin HEAD "v$(VERSION)"
	@gh release create "v$(VERSION)" "$(DMG)" --title "Wisperfy $(VERSION)" --notes-file "$(STAGE)/notes-$(VERSION).md"
	@echo "released v$(VERSION)"

## Live log stream from the running app.
logs:
	/usr/bin/log stream --level info --predicate 'subsystem == "$(BUNDLE_ID)"'

## Only ever resets this app's rows. A bare `tccutil reset` wipes every app on the machine.
reset-permissions:
	tccutil reset Accessibility $(BUNDLE_ID)
	tccutil reset Microphone $(BUNDLE_ID)

## Regenerate Resources/AppIcon.icns from Resources/Icon/MakeIcon.swift (pure CoreGraphics,
## works with Command Line Tools alone). Edit the script, run this, commit both.
icon:
	@mkdir -p "$(STAGE)/icon/AppIcon.iconset"
	@swiftc -O Resources/Icon/MakeIcon.swift -o "$(STAGE)/icon/MakeIcon"
	@cd "$(STAGE)/icon" && ./MakeIcon
	@cp "$(STAGE)/icon/icon_1024.png" Resources/Icon/AppIcon-1024.png
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s "$(STAGE)/icon/icon_1024.png" --out "$(STAGE)/icon/AppIcon.iconset/icon_$${s}x$${s}.png" >/dev/null; \
		d=$$((s*2)); sips -z $$d $$d "$(STAGE)/icon/icon_1024.png" --out "$(STAGE)/icon/AppIcon.iconset/icon_$${s}x$${s}@2x.png" >/dev/null; \
	done
	@iconutil -c icns "$(STAGE)/icon/AppIcon.iconset" -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

clean:
	@rm -rf .build "$(STAGE)"
