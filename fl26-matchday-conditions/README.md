# Matchday Conditions: a Football Life 26 mod

Football Life 26 runs on the PES 2021 engine. Without changes, almost every match is
played in **fine weather, in daylight, on a summer pitch**. This mod is a
[sider](https://github.com/juce/sider) Lua module. Before each match it picks the
**weather, kick-off time and pitch season** using a climate model, so the conditions
match the time of year and the region:

- A January match in a cold league can be a snowy night game on a frozen pitch.
- A July match in a Mediterranean league is usually a dry evening kick-off.
- A Brazilian league match (southern hemisphere) gets winter conditions in July.

## Features

| Feature | Details |
|---|---|
| 5 climate profiles | `temperate`, `cold`, `mediterranean`, `tropical`, `arid`, each with monthly rain, snow and night-match chances |
| Calendar-aware | Uses today's real date. You can also fix the month (for example to follow your Master League calendar) |
| Hemispheres | Southern leagues have their seasons shifted by six months |
| Per-competition climate | `tournament.<id> = cold` in the ini |
| No save-scumming | The same fixture on the same day always gets the same conditions. Restarting a match does not reroll the weather |
| In-game overlay | `[1]` turns the mod on or off · `[2]` rerolls the next match · `[3]` switches to the next profile |
| Logging | Each decision is written to `sider.log`, including the tournament id you need for overrides |

## Install

1. Copy `modules/MatchdayConditions.lua` and `modules/MatchdayConditions.ini` into
   `<Football Life 26>\sider\modules\`.
2. Open `sider.ini` and add this line next to the other `lua.module` lines:
   ```ini
   lua.module = "MatchdayConditions.lua"
   ```
3. Start the game. `sider.log` should contain `MatchdayConditions: v1.0.0 loaded`.
4. Optional: open the sider overlay (the default key is the backtick, `` ` ``) to see the
   last pick and use the hotkeys.

## Configure

Edit `MatchdayConditions.ini`. Every option is described there. Example for a
mixed save:

```ini
profile = temperate          ; default for everything
tournament.17 = cold         ; e.g. a Scandinavian league
tournament.25 = tropical     ; e.g. a Brazilian league...
tournament.25.hemisphere = south
```

To find a tournament id, play one match in that competition and look for
`tournament=<id>` in `sider.log`.

## How it works

The module registers sider's `set_conditions` event. It works out the climate month
(adjusted for hemisphere) and seeds a Park-Miller PRNG with a hash of
`home|away|tournament|date|reroll`. It then rolls snow, then rain, then fine weather,
and rolls separately for a night kick-off, using the profile's percentages for that month.
Snow can only fall in winter months, and a snowy match always gets a winter pitch.
The original options table is returned with only `weather`, `timeofday`, `season` and
`weather_effects` changed. The stadium and everything else are left alone.

## Tests

The selection logic is pure Lua and covered by a test suite. The suite also runs the
module end-to-end through a mocked sider context (`init` → `set_conditions` →
`overlay_on` → `key_down`):

```sh
./run_tests.sh      # requires luajit (sider's runtime) or lua5.1
```

The suite checks determinism, the hemisphere shift, that summer never gets snow, that
the observed rain, snow and night rates match the profiles (Monte-Carlo), ini parsing
and warnings, tournament overrides, and the hotkeys.
