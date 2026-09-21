# displaytint

Software white-point tint + soft dimming for every display, so the MacBook
panel and an external monitor land on exactly the same white point.
~300 lines of Swift, no dependencies.

## Use

    displaytint list                    # what's connected
    displaytint set 5000                # tint everything to 5000K
    displaytint set 5000 0.9            # ... and dim to 90% linear brightness
    displaytint off                     # pause (survives until next wake/reconfig)
    displaytint on                      # resume
    displaytint status                  # config + live gamma-table readback

Config lives at `~/.config/displaytint/config.json`. The daemon notices edits
within ~3 seconds, so editing the file is enough — no reload needed.

Per-display overrides (key = case-insensitive substring of the display name,
or `"builtin"` for the MacBook panel):

    {
      "enabled": true,
      "temperature": 5000,
      "brightness": 1.0,
      "displays": {
        "ProArt": { "brightness": 0.95 }
      }
    }

## Daemon

A LaunchAgent (`~/Library/LaunchAgents/dev.nlincke.displaytint.plist`) runs
`displaytint daemon` at login and keeps it alive. It re-applies the tint
after sleep/wake and display reconfigurations, because macOS wipes gamma
tables on those events, and re-reads the config whenever the file changes.

    launchctl kickstart -k gui/$(id -u)/dev.nlincke.displaytint   # restart
    tail -f ~/Library/Logs/displaytint.log

## How it works

The gamma table scales each channel's encoded output (`out = gain × v`).
Temperature gains are sRGB-encoded blackbody colors applied in the encoded
domain; brightness is a linear-light factor encoded with 1/2.2 before
applying. OSD/EDID is never touched, so hardware controls keep working.

**macOS 26 gotcha (verified empirically):** WindowServer now attributes
gamma-table writes to the owning process and reverts them to the system
table the moment that process exits. A one-shot CLI apply therefore sticks
only while it runs — the daemon is what makes the tint persist. `set`/`on`/
`off` still work while the daemon runs: they update the config file and the
daemon re-applies within ~3s.

## Notes for a stable two-display match

- Keep Night Shift off — it fights the tint (the daemon re-applies over it,
  but they will flicker against each other on schedule changes).
- Turn off True Tone and "Automatically adjust brightness" on the MacBook;
  both silently move the built-in white point and luminance.
- Set each panel's hardware brightness first (OSD / F1-F2 keys). The software
  `brightness` multiplier is for fine matching below that — gamma dimming
  slightly reduces contrast, so it's a comfort tool, not a calibration tool.
- Set the monitor's OSD to a neutral base: 6500K, contrast 80, standard/user
  picture mode. The software tint on top is what both displays share.
