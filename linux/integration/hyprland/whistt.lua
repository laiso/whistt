-- Whistt push-to-talk binding for Omarchy / Hyprland.
--
-- This is a template. It is NOT applied automatically: Whistt never writes to
-- ~/.config/hypr on its own. Copy the two o.bind lines into
-- ~/.config/hypr/bindings.lua, set `whistt_key`, then run:
--
--   hyprctl reload && hyprctl configerrors
--
-- Rollback: delete the two lines and reload again.
--
-- Choosing `whistt_key` requires a measurement, not a guess. With
-- `kb_options = "ctrl:nocaps"` (this machine's ~/.config/hypr/input.lua) the
-- physical bottom-left key and the hardware Left Ctrl both produce the
-- Control_L keysym, so a keysym binding for "CTRL" would also fire on ordinary
-- Ctrl shortcuts. Measure first and record the result:
--
--   wev          # press the physical bottom-left key, read `key:` and `sym:`
--
--   key: 58 + sym: Control_L  -> physical Caps Lock remapped to Ctrl
--   key: 29 + sym: Control_L  -> hardware Left Ctrl
--   anything else             -> that key
--
-- If the measurement is 29 (hardware Ctrl), this key is unusable for
-- push-to-talk without breaking Ctrl shortcuts: pick another key by user
-- decision. If it is 58, note that keycode bindings (`code:58`) are documented
-- for Hyprland's legacy config but were NOT accepted by the Lua parser on
-- Hyprland 0.56.2 / Omarchy 4.0.3 (hl.bind("code:58", ...) registers nothing),
-- so separating it from Ctrl needs an evdev-layer remap such as keyd or
-- interception-tools. Both resolutions are user decisions; do not silently
-- change the keyboard layout.
--
-- The press binding does not repeat (the default) and the release binding uses
-- { release = true }, matching the shape of Omarchy's own F9/voxtype pair so
-- the two can coexist.

local whistt_key = "REPLACE_WITH_THE_MEASURED_KEY"

o.bind(whistt_key, "Whistt push-to-talk (start)", "whistt record start")
o.bind(whistt_key, "Whistt push-to-talk (stop)", "whistt record stop", { release = true })
