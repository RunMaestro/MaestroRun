VERSION := $(shell cat VERSION)
BUILD := build
APP := $(BUILD)/MaestroRun.app
BIN := $(APP)/Contents/MacOS/maestro-run
ZIP := $(BUILD)/MaestroRun-$(VERSION)-macos-universal.zip
MIN_MACOS := 11.0
CFLAGS := -O2 -Wall -Wextra -Werror -mmacosx-version-min=$(MIN_MACOS) -arch arm64 -arch x86_64 \
	-DMAESTRO_RUN_VERSION='"$(VERSION)"'

# "-" is an ad-hoc signature: enough to build and test, useless for TCC.
# A release passes the Developer ID identity (see .github/workflows/release.yml).
# Every build, this one included, is signed with the hardened runtime. Without
# it dyld honors DYLD_INSERT_LIBRARIES and the caller can load code into the
# launcher itself, which is the process that holds the grant.
IDENTITY ?= -
PREFIX ?= $(HOME)/Applications

.PHONY: all test sign verify dist install clean

all: $(BIN)

$(BIN): src/maestro-run.c resources/Info.plist.in VERSION Makefile
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	sed 's/@VERSION@/$(VERSION)/g' resources/Info.plist.in > $(APP)/Contents/Info.plist
	clang $(CFLAGS) -o $(BIN) src/maestro-run.c
	codesign --force --options runtime --sign - $(APP)

test: $(BIN)
	MAESTRO_RUN="$(abspath $(BIN))" tests/run.sh

# Hardened runtime and a secure timestamp are both required for notarization.
sign: $(BIN)
	codesign --force --options runtime --timestamp --sign "$(IDENTITY)" $(APP)

verify:
	codesign --verify --strict --verbose=2 $(APP)
	codesign --display --requirements - $(APP)

dist: $(BIN)
	rm -f $(ZIP) $(ZIP).sha256
	ditto -c -k --keepParent $(APP) $(ZIP)
	cd $(BUILD) && shasum -a 256 $(notdir $(ZIP)) > $(notdir $(ZIP)).sha256

# The grant follows the bundle identifier, not the path, so any location works.
install: $(BIN)
	mkdir -p "$(PREFIX)"
	rm -rf "$(PREFIX)/MaestroRun.app"
	ditto $(APP) "$(PREFIX)/MaestroRun.app"
	@echo "installed $(PREFIX)/MaestroRun.app"
	@echo "optional: ln -sf '$(PREFIX)/MaestroRun.app/Contents/MacOS/maestro-run' /usr/local/bin/maestro-run"

clean:
	rm -rf $(BUILD)
