#!/bin/zsh
set -eu -o pipefail

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is required" >&2
  exit 2
fi

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: $0 /path/to/pcm16le-24khz-mono.raw-or.wav" >&2
  exit 2
fi

audio_fixture="$1"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

for model in gpt-transcribe gpt-live-transcribe; do
  output_file="$temporary_directory/$model.log"
  echo "Testing $model"
  if ! WHISTT_MODEL="$model" \
      PROBE_MODE=api-intent \
      PROBE_ACTION=realtime-text-only \
      PROBE_REQUIRE_FINAL=1 \
      PROBE_WAIT="${PROBE_WAIT:-15}" \
      swift run realtime-probe "$audio_fixture" >"$output_file" 2>&1; then
    sed -E 's/(Bearer |openai-insecure-api-key\.)[^ ]+/\1<redacted>/g' "$output_file" >&2
    exit 1
  fi

  grep -q '\[probe\] -> session.update' "$output_file"
  grep -q '\[probe\] -> input_audio_buffer.commit' "$output_file"
  grep -Eq 'input_audio_transcription.completed|audio_transcript.done|conversation.item.done|response.text.done' "$output_file"

  if [[ -n "${WHISTT_E2E_EXPECTED_TEXT:-}" ]]; then
    grep -Fqi "$WHISTT_E2E_EXPECTED_TEXT" "$output_file"
  fi
done

echo "OpenAI transcription E2E tests passed"
