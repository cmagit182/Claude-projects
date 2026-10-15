# FormBook: results history, head-to-head and adaptive difficulty for Football Life 26

Football Life 26 (PES 2021 engine with sider 7) forgets every result as soon as a match
ends. Exhibition matches, cups and leagues share no history, there's no head-to-head
record, and the difficulty level stays at whatever you picked even when you win every
game 5-0.

FormBook is a sider Lua module that adds three things:

1. **Automatic results ledger.** It reads the live scoreboard through sider's `match`
   library and records each match that reaches full time: score, extra time, penalty
   shoot-out, competition, difficulty and date. Results go to
   `sider\modules\FormBook\results.csv`, which opens in Excel or Google Sheets.
   Matches you quit early are not recorded.
2. **Pre-match briefing.** Open the sider overlay before kick-off to see the all-time
   head-to-head between the two teams, the last meeting, and each side's last-5 form.
   This works in every mode, including friendlies.
3. **Adaptive difficulty (optional).** FormBook looks at your team's results at the current
   level. Three or more results averaging 2.4+ points per game move the AI up a level.
   0.8 or fewer points per game move it down. Each new level starts a fresh evaluation, so
   it doesn't swing up and down. Your team is detected automatically: it's the team in all
   of your recent matches, as in Master League or a league mode. You can also set it.

```
FormBook v1.0.0  [page 1/3]
Arsenal vs Chelsea  |  Premier League
Head-to-head (6): Arsenal 3  -  draws 1  -  2 Chelsea   goals 10-8
Last meeting 2026-10-12: Chelsea 1-2 Arsenal (aet)
Form: Arsenal WWDLW   |   Chelsea LDWWW
[1] next page   [2] adaptive difficulty OFF   [3] undo last result
```

Overlay pages: **1** briefing · **2** recent results · **3** adaptive difficulty status.
Keys: `[1]` next page, `[2]` adaptive difficulty on/off, `[3]` press twice to delete the last
recorded result.

## Install

1. Copy `modules/FormBook.lua` and `modules/FormBook.ini` into
   `<Football Life 26>\sider\modules\`.
2. In `sider.ini`, make sure match stats are on and add the module:
   ```ini
   match-stats.enabled = 1
   lua.module = "FormBook.lua"
   ```
   `match-stats.enabled` is sider's switch for the experimental `match` library, which
   FormBook uses to read the scoreboard. If it's off, the overlay shows a warning.
3. Play a match to full time. `sider.log` will show `recorded: ...`, and the CSV appears.
4. Optional: add team and competition names to `FormBook.ini` (`team.101 = Arsenal`).
   sider only exposes numeric ids, and you can find them in `results.csv`.

## How it works (sider 7.4 API)

| sider feature | Used for |
|---|---|
| `display_frame` | Polls `match.stats()` about 4 times a second (every 15 frames) |
| `match.stats()` | Score, shoot-out score, period and clock of the live match |
| `set_teams` | The fixture: team ids for the briefing and the result |
| `set_match_settings` | Reads and, with adaptive difficulty on, sets `difficulty` |
| `context_reset` | Back to the main menu: records a finished match, discards an unfinished one |
| `overlay_on` / `key_down` | Briefing UI and hotkeys. Overlay text is cached, not rebuilt every frame |
| `fs.make_dirs`, `io` | `modules\FormBook\results.csv` |

A result is recorded when the scoreboard disappears after the match reached full time
(90+ minutes in the 2nd half, 120+ in extra time, or a shoot-out). If the scoreboard
disappears and comes back for the same fixture, the match carries on. If a different
fixture starts instead, the unfinished match is thrown away.

## Tests

```sh
./run_tests.sh      # luajit (sider's runtime) or lua5.1
```

The 18 tests mock sider's context, `match.stats()` and `fs`, and simulate whole matches
frame by frame. They cover full time, extra time, penalties, matches quit early, a
scoreboard that disappears briefly, persistence across restarts, the overlay pages, undo,
and promotion and relegation of the difficulty level. One test loads the module with only
the globals sider gives modules, to catch any dependency sider doesn't provide.
