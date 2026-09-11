#!/usr/bin/env bash
#
# Verify an applied Whistt push-to-talk binding without pressing a key.
#
# Usage:  scripts/check-binding.sh <HYPRLAND_KEY>
#         scripts/check-binding.sh code:58
#
# Press/release behaviour itself still needs a human finger; everything that can
# be checked from Hyprland's own state is checked here. Run it again after a
# press to confirm Caps Lock was not latched.

set -euo pipefail

key="${1:-}"
if [[ -z "$key" ]]; then
  echo "usage: $0 <HYPRLAND_KEY>   (for example: code:58)" >&2
  exit 2
fi

fail=0
note() { printf '%-46s %s\n' "$1" "$2"; }

# 1. The configuration must parse.
errors="$(hyprctl configerrors 2>&1 || true)"
if [[ -n "${errors//[[:space:]]/}" ]]; then
  note "hyprctl configerrors" "FAIL"
  printf '%s\n' "$errors"
  fail=1
else
  note "hyprctl configerrors" "clean"
fi

# 2. The press/release pair must exist with the right flags and descriptions.
if ! python3 - "$key" <<'PY'
import json
import subprocess
import sys

key = sys.argv[1]
ours_descriptions = {"Whistt push-to-talk (start)", "Whistt push-to-talk (stop)"}

try:
    binds = json.loads(subprocess.check_output(["hyprctl", "binds", "-j"]))
except Exception as error:  # noqa: BLE001 - reported to the user below
    print(f"{'binding on ' + key:46} FAIL")
    print(f"  - could not read binds: {error}")
    sys.exit(1)

on_key = [b for b in binds if b.get("key") == key]
problems = []

if len(on_key) != 2:
    problems.append(f"expected exactly 2 binds on {key!r}, found {len(on_key)}")

press = [b for b in on_key if not b.get("release")]
release = [b for b in on_key if b.get("release")]
if len(press) != 1:
    problems.append(f"expected exactly one press binding, found {len(press)}")
if len(release) != 1:
    problems.append(f"expected exactly one release binding, found {len(release)}")

for bind in on_key:
    if bind.get("repeat"):
        problems.append(f"{bind.get('description')!r} repeats; push-to-talk must not repeat")
    if bind.get("non_consuming"):
        problems.append(f"{bind.get('description')!r} is non-consuming")

# A key that is itself a modifier needs the modifier named in the release bind.
# Hyprland resolves a key event against the modifier state from before that key's
# own modifier change, so a modmask-0 release bind for Control_R never matches
# and the session runs until the recording limit instead of stopping.
if len(press) == 1 and len(release) == 1 and key.endswith(("_L", "_R")):
    if release[0].get("modmask") == press[0].get("modmask"):
        problems.append(
            f"{key!r} is a modifier but the release bind has modmask "
            f"{release[0].get('modmask')} like the press bind; re-apply with a "
            f"RELEASE_MODIFIER, for example: apply-binding.sh {key} CTRL"
        )

found = {b.get("description", "") for b in on_key}
for want in sorted(ours_descriptions):
    if want not in found:
        problems.append(f"missing description {want!r}")

foreign = [
    b.get("description", "(no description)")
    for b in on_key
    if b.get("description", "") not in ours_descriptions
]
if foreign:
    problems.append("collision with another action: " + ", ".join(sorted(foreign)))

print(f"{'binding on ' + key:46} {'ok' if not problems else 'FAIL'}")
for bind in on_key:
    kind = "release" if bind.get("release") else "press"
    print(f"  {kind:8} modmask={bind.get('modmask')} repeat={bind.get('repeat')} {bind.get('description')!r}")
for problem in problems:
    print(f"  - {problem}")
sys.exit(1 if problems else 0)
PY
then
  fail=1
fi

# 3. Caps Lock must not be latched on any keyboard.
caps="$(hyprctl devices | grep -i capslock | awk '{print $2}' | sort -u | tr '\n' ' ')"
if [[ "$caps" == "no " ]]; then
  note "keyboard capsLock" "all 'no'"
else
  note "keyboard capsLock" "UNEXPECTED: $caps"
  fail=1
fi

# 4. The daemon, if running, must answer.
if [[ -S "${XDG_RUNTIME_DIR:-/nonexistent}/whistt/daemon.sock" ]]; then
  status="$(whistt status 2>&1 || true)"
  note "whistt status" "${status:-no output}"
else
  note "whistt daemon" "not running (start it with 'whistt daemon')"
fi

if [[ "$fail" -eq 0 ]]; then
  echo
  echo "All automatable binding checks passed."
else
  echo
  echo "Some checks failed; see above." >&2
fi
exit "$fail"
