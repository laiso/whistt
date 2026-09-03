SHELL := /bin/zsh
.SHELLFLAGS := -eu -o pipefail -c

XCODE_DERIVED_DATA := .build/xcode
WHISTT_BINARY := $(XCODE_DERIVED_DATA)/Build/Products/Debug/Whistt.app/Contents/MacOS/Whistt

.PHONY: build debug test

build:
	xcodebuild \
		-workspace Whistt.xcworkspace \
		-scheme Whistt \
		-configuration Debug \
		-derivedDataPath $(XCODE_DERIVED_DATA) \
		build

debug: build
	@set -a; \
	[[ ! -f .env ]] || source .env; \
	set +a; \
	$(WHISTT_BINARY) 2>&1 | tee ./debug.log

test:
	swift test
