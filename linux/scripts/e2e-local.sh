#!/usr/bin/env bash
#
# Tier 2 end-to-end test: the real capture path, the real OpenAI transcription
# API, and the real output adapter shape.
#
# The trigger is the CLI rather than a key, so no physical keyboard and no
# Hyprland binding are involved. Text goes to a stub `wtype`, so nothing is typed
# into the focused application and the clipboard is never touched.
#
# Microphone mode (you speak):
#   OPENAI_API_KEY=... scripts/e2e-local.sh
#
# Unattended mode (a speech file is played into a loopback device, so the test
# needs neither a speaker nor a human):
#   OPENAI_API_KEY=... WHISTT_E2E_AUDIO_FILE=speech.wav scripts/e2e-local.sh
#
# Optional: WHISTT_E2E_EXPECTED_TEXT=<substring> to require a phrase,
#           WHISTT_E2E_SECONDS=<n> to change the recording window,
#           WHISTT_MODEL=<model> to override the default model.
#
# Exits non-zero unless exactly one non-empty transcript is delivered.

set -euo pipefail

linux_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$linux_dir/.." && pwd)"
seconds="${WHISTT_E2E_SECONDS:-6}"
audio_file="${WHISTT_E2E_AUDIO_FILE:-}"
expected="${WHISTT_E2E_EXPECTED_TEXT:-}"

if [[ -z "${OPENAI_API_KEY:-}" && -f "$repo_root/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$repo_root/.env"
  set +a
fi
if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "OPENAI_API_KEY is required (in the environment or in .env)" >&2
  exit 2
fi
if [[ -n "$audio_file" && ! -f "$audio_file" ]]; then
  echo "WHISTT_E2E_AUDIO_FILE does not exist: $audio_file" >&2
  exit 2
fi

real_runtime="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set}"
runtime="$(mktemp -d)"
typed="$runtime/typed"
stub="$runtime/stub-bin"
mkdir -p "$typed" "$stub"

# The daemon gets its own private runtime directory for the control socket,
# while PipeWire keeps using the real one so audio stays reachable.
export XDG_RUNTIME_DIR="$runtime"
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-$real_runtime}"
export WHISTT_E2E_WTYPE_DIR="$typed"
export PATH="$stub:$PATH"
export WHISTT_LOG="${WHISTT_LOG:-debug}"

cat > "$stub/wtype" <<'STUB'
#!/bin/sh
# Stands in for the real wtype: keeps exactly what would have been typed.
cat > "$WHISTT_E2E_WTYPE_DIR/$(date +%s%N)"
STUB
printf '#!/bin/sh\nexit 0\n' > "$stub/wl-copy"
printf '#!/bin/sh\nexit 0\n' > "$stub/hyprctl"
chmod +x "$stub/wtype" "$stub/wl-copy" "$stub/hyprctl"

cleanup() {
  for pid in "${playback_pid:-}" "${loopback_pid:-}" "${daemon_pid:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  for pid in "${playback_pid:-}" "${loopback_pid:-}" "${daemon_pid:-}"; do
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$runtime"
}
trap cleanup EXIT

if [[ -n "$audio_file" ]]; then
  # A virtual sink/source pair: play into the sink, capture from the source.
  sink="whistt-e2e-sink-$$"
  source="whistt-e2e-mic-$$"
  pw-loopback -m '[FL, FR]' \
    --capture-props="node.name=$sink media.class=Audio/Sink" \
    --playback-props="node.name=$source media.class=Audio/Source" \
    >"$runtime/loopback.log" 2>&1 &
  loopback_pid=$!
  export WHISTT_DEVICE="${WHISTT_DEVICE:-$source}"
  sleep 1
  echo "loopback ready: play into $sink, capturing $source"
fi

echo "building linux/ ..."
cargo build --quiet --manifest-path "$linux_dir/Cargo.toml"
binary="$linux_dir/target/debug/whistt"

daemon_log="$runtime/daemon.log"
"$binary" daemon >"$daemon_log" 2>&1 &
daemon_pid=$!

socket="$runtime/whistt/daemon.sock"
for _ in $(seq 1 60); do
  [[ -S "$socket" ]] && break
  sleep 0.1
done
if [[ ! -S "$socket" ]]; then
  echo "FAIL: the daemon did not create $socket" >&2
  cat "$daemon_log" >&2
  exit 1
fi
echo "daemon listening on $socket (device: ${WHISTT_DEVICE:-default})"

if [[ -n "$audio_file" ]]; then
  echo "playing $audio_file into the loopback for about ${seconds} seconds"
else
  echo "Speak for about ${seconds} seconds."
fi

"$binary" record start

for _ in $(seq 1 200); do
  grep -q "provider session ready" "$daemon_log" 2>/dev/null && break
  sleep 0.05
done
if ! grep -q "provider session ready" "$daemon_log" 2>/dev/null; then
  echo "FAIL: the provider session never became ready" >&2
  cat "$daemon_log" >&2
  exit 1
fi
echo "provider session ready; recording"

if [[ -n "$audio_file" ]]; then
  pw-cat --playback --target "$sink" "$audio_file" >/dev/null 2>&1 &
  playback_pid=$!
  for _ in $(seq 1 $((seconds * 10))); do
    kill -0 "$playback_pid" 2>/dev/null || break
    sleep 0.1
  done
  # Capture a little past the end of the file, then release.
  sleep 0.5
else
  sleep "$seconds"
fi
"$binary" record stop

for _ in $(seq 1 200); do
  [[ -n "$(ls -A "$typed" 2>/dev/null)" ]] && break
  sleep 0.25
done

insertions="$(ls -A "$typed" 2>/dev/null | wc -l)"
if [[ "$insertions" -eq 0 ]]; then
  echo "FAIL: nothing was typed" >&2
  cat "$daemon_log" >&2
  exit 1
fi
if [[ "$insertions" -ne 1 ]]; then
  echo "FAIL: expected exactly one insertion, saw $insertions" >&2
  cat "$daemon_log" >&2
  exit 1
fi

file="$typed/$(ls -A "$typed" | head -1)"
bytes="$(wc -c < "$file")"
if [[ "$bytes" -eq 0 ]]; then
  echo "FAIL: the transcript was empty" >&2
  cat "$daemon_log" >&2
  exit 1
fi

status="$("$binary" status)"
echo
echo "--- transcript (bytes written to the stdin of stub wtype) ---"
cat "$file"
echo
echo "--- checks ---"
echo "insertions      : $insertions"
echo "bytes           : $bytes"
if [[ "$(tail -c 1 "$file" | od -An -tu1 | tr -d ' ')" == "10" ]]; then
  echo "trailing newline: yes (from the model, not appended by Whistt)"
else
  echo "trailing newline: no"
fi
echo "final state     : $status"
echo "commits         : $(grep -c 'turn committed' "$daemon_log" || true)"
echo "interim events  : $(grep -c 'interim transcript received' "$daemon_log" || true)"

if [[ "$status" != "idle" ]]; then
  echo "FAIL: the session did not return to idle" >&2
  exit 1
fi

# Acceptance item: audio appends must reach the provider before the release.
# The daemon logs the first socket write, so this is independent of when the
# provider chooses to emit interim results.
first_activity="$(grep -n "first audio append sent" "$daemon_log" | head -1 | cut -d: -f1)"
release_line="$(grep -n "capture stopping" "$daemon_log" | head -1 | cut -d: -f1)"
if [[ -z "$first_activity" || -z "$release_line" ]]; then
  echo "FAIL: could not order the first audio append against the release" >&2
  cat "$daemon_log" >&2
  exit 1
fi
if (( first_activity > release_line )); then
  echo "FAIL: the first append came after the release (line $first_activity > $release_line)" >&2
  exit 1
fi
echo "appends before release: yes (first append at line $first_activity, release at line $release_line)"

if [[ -n "$expected" ]]; then
  if ! grep -qiF -- "$expected" "$file"; then
    echo "FAIL: the transcript does not contain '$expected'" >&2
    exit 1
  fi
  echo "expected phrase : found"
fi

echo
echo "PASS: one finalized transcript, no automatic submission, session idle"
