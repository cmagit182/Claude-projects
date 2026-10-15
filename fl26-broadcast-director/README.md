# Broadcast Director: a self-directing TV camera for Football Life 26

Camera mods for PES 2021 / FL26 (Fan View Essential, broadcast and stadium cam packs, sider's
own `camera.lua`) each give you **one fixed set of camera values** for every match.

A real broadcast doesn't work like that. Each ground has its own camera gantry, each competition
has its own TV look, and the director changes the shot as the game unfolds. Broadcast Director
brings that to the game's **Fan View** camera:

| | |
|---|---|
| **Presets** | Six built-in set-ups (Standard TV, Main Gantry, Low Broadcast, Close TV, Tactical Wide, Retro 90s), plus your own. Edit them live from the overlay. |
| **Per stadium / per competition** | Rules pick the preset automatically: stadium first, then competition, then your default. Press **[5]** to remember the current preset for this stadium, or **[6]** for this competition. |
| **Live direction** | Reads the live match through sider's `match.stats()`. The shot gradually tightens from the 80th minute of a close game, tightens a little in extra time, and switches to a lower, closer shot for penalty shoot-outs. After the match it returns to the preset. |
| **Smooth blending** | Every change eases in over about 0.8 s (configurable) instead of jumping. |
| **Hand-held drift** | Optional slow, very small movement (≤0.35 % zoom, ≤0.3 % height) during play, so the picture isn't locked off like a tripod. Off outside matches. |

## Install

1. Copy `modules/BroadcastDirector.lua` and `modules/BroadcastDirector.ini` to
   `<Football Life 26>\sider\modules\` (FL26 may use `SiderAddons\modules\`).
2. In `sider.ini`, **replace** any `camera.lua` / Fan View camera module line with:
   ```ini
   lua.module = "BroadcastDirector.lua"
   match-stats.enabled = 1        ; needed for live direction
   ```
   Don't run it alongside another Fan View camera module, or the two will overwrite each other.
3. In game: **Settings → Camera → Fan View**.

## Using it

Open the sider overlay during a match. It shows the active preset and why it was chosen (manual,
stadium, competition or default), the stadium and competition ids, any live direction currently
active (for example `closing minutes 60%`), and the preset values next to the live ones.

| Key | Action |
|---|---|
| `1` / `2` | Previous / next preset (for this match only) |
| `3` | Live direction on/off |
| `4` | Hand-held drift: off → subtle → normal → strong |
| `5` / `6` | Use the current preset for this **stadium** / **competition** (saved) |
| `9` / `0` | Choose zoom / height / angle |
| `-` / `+` | Adjust that value of the current preset (live) |
| `8` | Save presets to the ini |

A good workflow: start a match at a big stadium, cycle presets with `2`, fine-tune with `-`/`+`,
then press `5`. That ground will use that look from now on.

## Settings (`BroadcastDirector.ini`)

```ini
default = Standard TV
blend_seconds = 0.8
breathing = 0.5            ; 0 off, 0.5 subtle, 1 normal, 2 strong
director = on
tension_from = 80          ; minute when the closing-minutes framing starts
invert_zoom = off
preset.Sky Style = 26.1, 0.47, 1.08      ; zoom, height, angle (game default 25.6, 0.43, 1.0)
stadium.12 = Main Gantry
tournament.17 = Low Broadcast
```

## How it works

- **Memory.** It finds the Fan View camera block the same way sider's `camera.lua` does (game
  research by nesa24): a code-pattern search plus a RIP-relative offset. Zoom, height and angle
  are the floats at `+0x08`, `+0x0c` and `+0x24`. Nothing else is written.
- **Each frame:** target = preset × live-direction modifiers. The camera eases towards the target
  and settles exactly once the difference is invisible. Hand-held drift (two slow, unrelated sine
  waves per axis) is added during matches. Memory is only written when a value actually changes.
- **Live direction.** Uses `period` and `clock_minutes` from `match.stats()`. Closing-minutes
  tension builds linearly from `tension_from` to 90' when the score difference is 0 or 1, and
  from 110' to 120' in extra time.

## Tests

```sh
./run_tests.sh       # luajit or lua5.1
```

The 19 tests run against a **simulated game process**: real IEEE-754 floats, the same code pattern
and RIP-relative offset as the game, and a neighbouring value that must stay untouched. They
check that:
- the camera block address is found and only those three values change;
- stadium and competition rules apply and blend in;
- memory isn't written again once the camera has settled;
- the camera tightens for the closing minutes and the shoot-out, then returns to the preset;
- drift stays within its bounds and only runs during matches;
- manual presets reset at the next fixture;
- live tuning and saving rules persist to the ini;
- the module stays inactive, and says why, if the camera code isn't found;
- it runs with only the globals sider gives modules. This test caught a crash: sider modules
  have no `pcall`.

## Honest caveats

- **Untested in the game.** The memory locations come from sider 7's `camera.lua` for the PES 2021
  executable, which FL26 uses, but this module hasn't run in FL26 yet.
- **Preset numbers are a starting point.** They're my estimates around the game defaults. Tune
  them in the overlay and save.
- **Zoom direction.** If "tighter" moments come out wider on your setup, set `invert_zoom = on`.
- **Limited match data.** sider exposes the score, clock and period but not the ball position, so
  live direction reacts to match situations, not to individual plays.
