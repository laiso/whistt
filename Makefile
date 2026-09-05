SHELL := /bin/zsh
.SHELLFLAGS := -eu -o pipefail -c

XCODE_DERIVED_DATA := .build/xcode
WHISTT_BINARY := $(XCODE_DERIVED_DATA)/Build/Products/Debug/Whistt.app/Contents/MacOS/Whistt

.PHONY: build debug test test-e2e-openai test-release-scripts

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
	export WHISTT_PREFER_ENV_API_KEYS=1; \
	set +a; \
	$(WHISTT_BINARY) 2>&1 | tee ./debug.log

test:
	swift test

test-e2e-openai:
	@test -n "$${WHISTT_E2E_AUDIO_FILE:-}" || { echo "WHISTT_E2E_AUDIO_FILE is required" >&2; exit 2; }
	./Tests/E2E/run-openai-transcription.sh "$${WHISTT_E2E_AUDIO_FILE}"

test-release-scripts:
	./Tests/ReleaseScripts/run.sh
