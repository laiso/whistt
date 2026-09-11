#!/usr/bin/env bash
#
# Apply or remove the Whistt push-to-talk binding in the user's Hyprland config.
#
# Usage:
#   scripts/apply-binding.sh <HYPRLAND_KEY>     # apply, for example code:58
#   scripts/apply-binding.sh --remove           # roll back
#   scripts/apply-binding.sh --show             # print the managed block
#
# The managed lines are wrapped in markers, so applying again replaces them and
# removing deletes exactly them. The file is backed up before every change, and
# a change that breaks the configuration is rolled back automatically.
#
# This never edits packaged Omarchy defaults: only the user's own
# ~/.config/hypr/bindings.lua.

set -euo pipefail

bindings="${HYPRLAND_BINDINGS:-$HOME/.config/hypr/bindings.lua}"
begin_marker="-- >>> whistt push-to-talk (managed by linux/scripts/apply-binding.sh) >>>"
end_marker="-- <<< whistt push-to-talk (managed) <<<"

block() {
  cat <<EOF
$begin_marker
o.bind("$1", "Whistt push-to-talk (start)", "whistt record start")
o.bind("$1", "Whistt push-to-talk (stop)", "whistt record stop", { release = true })
$end_marker
EOF
}

strip_block() {
  python3 - "$bindings" "$begin_marker" "$end_marker" <<'PY'
import sys

path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = open(path).read()
except FileNotFoundError:
    sys.exit(0)

lines, out, inside = text.splitlines(keepends=True), [], False
for line in lines:
    stripped = line.rstrip("\n")
    if stripped == begin:
        inside = True
        continue
    if stripped == end:
        inside = False
        continue
    if not inside:
        out.append(line)
# Leave the file as it was before the block was appended.
open(path, "w").write("".join(out).rstrip("\n") + "\n")
PY
}

reload_and_validate() {
  hyprctl reload >/dev/null
  sleep 0.5
  local errors
  errors="$(hyprctl configerrors 2>&1 || true)"
  if [[ -n "${errors//[[:space:]]/}" ]]; then
    printf '%s\n' "$errors"
    return 1
  fi
  return 0
}

case "${1:-}" in
  --show)
    block "REPLACE_WITH_THE_MEASURED_KEY"
    exit 0
    ;;
  --remove)
    [[ -f "$bindings" ]] || { echo "no $bindings to edit"; exit 0; }
    backup="$bindings.bak.$(date +%s)"
    cp -a "$bindings" "$backup"
    strip_block
    if reload_and_validate; then
      echo "removed the Whistt binding; backup at $backup"
    else
      echo "configuration errors after removal; restoring $backup" >&2
      cp -a "$backup" "$bindings"
      hyprctl reload >/dev/null
      exit 1
    fi
    exit 0
    ;;
  "")
    echo "usage: $0 <HYPRLAND_KEY> | --remove | --show" >&2
    exit 2
    ;;
esac

key="$1"
if [[ "$key" == "REPLACE_WITH_THE_MEASURED_KEY" ]]; then
  echo "refusing to apply a placeholder key; measure the physical key first" >&2
  exit 2
fi

if ! command -v whistt >/dev/null; then
  echo "warning: 'whistt' is not on PATH, so the binding would do nothing." >&2
  echo "         install it first, for example:" >&2
  echo "           install -Dm755 linux/target/release/whistt ~/.local/bin/whistt" >&2
fi

mkdir -p "$(dirname "$bindings")"
[[ -f "$bindings" ]] || printf '%s\n' "-- Personal Hyprland bindings." > "$bindings"
backup="$bindings.bak.$(date +%s)"
cp -a "$bindings" "$backup"

strip_block
{
  cat "$bindings"
  echo
  block "$key"
} > "$bindings.new"
mv "$bindings.new" "$bindings"

if reload_and_validate; then
  echo "applied the Whistt binding on $key; backup at $backup"
  echo "verify the shape with: linux/scripts/check-binding.sh '$key'"
else
  echo "configuration errors after applying; restoring $backup" >&2
  cp -a "$backup" "$bindings"
  hyprctl reload >/dev/null
  exit 1
fi
