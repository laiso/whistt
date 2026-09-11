-- Whistt push-to-talk binding for Omarchy / Hyprland.
--
-- This is a template; Whistt never edits ~/.config/hypr on its own. Apply with:
--
--   linux/scripts/apply-binding.sh <KEY> [RELEASE_MODIFIER]
--   linux/scripts/check-binding.sh <KEY>
--   linux/scripts/apply-binding.sh --remove        # rollback
--
-- Choosing the key requires a measurement, not a guess, because
-- kb_options = "ctrl:nocaps" collapses several physical keys onto one keysym:
--
--   wev          # press the key, read `key:` (xkb keycode = evdev + 8) and `sym:`
--
-- Measured on the reference machine (Topre Realforce Compact, kb_layout = "jp",
-- kb_options = "ctrl:nocaps"):
--
--   physical bottom-left key    evdev 29 = KEY_LEFTCTRL    sym Control_L
--   physical right Ctrl         evdev 97 = KEY_RIGHTCTRL   sym Control_R
--   physical Caps Lock (Eisu)   evdev 58 = KEY_CAPSLOCK    sym Control_L (via ctrl:nocaps)
--
-- The bottom-left key is unusable for push-to-talk: it is the same physical key
-- as every left-Ctrl shortcut, and the Caps Lock key collapses onto the same
-- Control_L keysym. Separating them needs an evdev remapper (keyd,
-- interception-tools) or a layout change, because keycode bindings are
-- documented for Hyprland's legacy config but are not accepted by the Lua
-- parser on Hyprland 0.56.2 / Omarchy 4.0.3: hl.bind("code:58", ...) executes
-- but registers no bind with a keycode.
--
-- Right Ctrl is distinguishable (Control_R is a different keysym from
-- Control_L), collides with no existing Omarchy binding, and needs neither an
-- evdev remapper nor a layout change. Its cost is that the physical right Ctrl
-- stops reaching applications as Ctrl while the binding is active. Left Ctrl,
-- Caps Lock, and the Omarchy F9 / voxtype bindings are unaffected.
--
-- A lone modifier key needs its own modifier named in the RELEASE bind. Hyprland
-- resolves a key event against the modifier state from before that key's own
-- modifier change, so while Control_R is being released Control is still
-- depressed and a modmask-0 release bind never matches: the session then runs
-- until the recording limit instead of stopping on release. This is what
-- Hyprland's "binding mods" documentation means by bindr=ALT,Alt_L,...; the
-- press bind correctly stays at modmask 0.
--
-- The press binding does not repeat (the default) and the release binding uses
-- { release = true }, matching the shape of Omarchy's own F9 / voxtype pair.

local whistt_key = "Control_R"
local whistt_release_key = "CTRL + " .. whistt_key

o.bind(whistt_key, "Whistt push-to-talk (start)", "whistt record start")
o.bind(whistt_release_key, "Whistt push-to-talk (stop)", "whistt record stop", { release = true })
