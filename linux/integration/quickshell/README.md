# Quickshell bar status (Omarchy shell)

Shows the Whistt daemon state in the Omarchy shell bar, next to the other
status widgets. This targets the Quickshell-based Omarchy shell (the
`omarchy.bar` plugin), not Waybar.

## What it shows

The module polls `whistt status` once a second and renders:

| Daemon state | Display | Tooltip |
| --- | --- | --- |
| `idle` | microphone icon, normal color | `Whistt: idle` |
| `recording` | filled circle + microphone icon, normal color | `Whistt: recording` |
| `finalizing` | filled circle + microphone icon, normal color | `Whistt: transcribing` |
| unreachable / timed out | microphone-off icon, urgent color | `Whistt: not running` |
| script missing / failed to launch | microphone-off icon, normal color | `Whistt: status unavailable` |

The icons are the same glyphs as the shell's built-in microphone widget.
The shell's command modules offer only two colors -- normal and the
urgent color (red) -- so red is reserved for the not-running state and
recording is marked with a filled circle instead. Because the poll
interval is one second, a state change appears in the bar within about a
second.

## Install

1. Copy the status script where the shell's documented example puts
   custom module scripts, and make it executable:

   ```sh
   mkdir -p ~/.config/omarchy/bar/scripts
   cp whistt-status ~/.config/omarchy/bar/scripts/
   chmod +x ~/.config/omarchy/bar/scripts/whistt-status
   ```

2. Add the entry from `module.json` to a section of `bar.layout` in
   `~/.config/omarchy/shell.json` (for example in `right`, just before
   `omarchy.audio`). Note that a user `shell.json` replaces the default
   file wholesale; there is no merge.

3. Restart the shell:

   ```sh
   omarchy-restart-shell
   ```

## Remove

Delete the `whistt` entry from `bar.layout` in
`~/.config/omarchy/shell.json`, remove
`~/.config/omarchy/bar/scripts/whistt-status`, and restart the shell.
