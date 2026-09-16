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

.PHONY: all build test app run install clean logs reset-permissions icon

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
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(APP).entitlements \
		--options runtime \
		--timestamp=none \
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
