# Tournament Engine: modern competition formats for Football Life 26

Football Life 26 runs on the PES 2021 engine, which only knows the competition formats of 2020.
It can't run the **2024+ Champions League** (36-team "Swiss model" league phase, knockout
play-offs) or the **48-team World Cup 2026** (12 groups, 8 best third-placed teams, Round of 32).
Its competition editor can't build them either.

Tournament Engine is a sider Lua module that runs those competitions *around* the game:

- **Draw.** Real constraints are enforced:
  - Champions League: each club gets 2 opponents from every pot (1 home, 1 away), never a club
    from its own country, and at most 2 from one country.
  - World Cup: one team per pot in each group, confederation limits, and hosts placed in their
    groups.
- **Schedule.** It builds every matchday (8 league-phase matchdays where every club plays once),
  then the play-offs, Round of 16 and so on up to the final.
- **Your matches.** Set them up as normal exhibition matches. When you pick the two teams, the
  module recognises the fixture and sets the correct rules: no extra time in league games or first
  legs, extra time and penalties in single-match knockouts. At full time it reads the score from
  the scoreboard.
- **Everyone else's matches.** They are simulated from team ratings once you've played yours, so
  the table and bracket keep moving.
- **Ties.** Two-legged ties are decided on aggregate. The game can't know at kick-off whether a
  2nd leg will need extra time, so if it ends level on aggregate the module schedules a **decider**
  (extra time and penalties) and applies those rules when you play it.
- **Results.** You see them in game on the sider overlay and in an **HTML report** (tables,
  bracket, every result) that's rewritten after each match. Open it in a browser or on your phone.
- **Saving.** Progress persists between sessions. Press [5] twice for a new edition with a fresh
  draw.

Formats are data, not code. Write your own in a text file:

| `format` | Covers |
|---|---|
| `swiss` | Champions League / Europa League / Conference League league phase, any 4-pot size |
| `groups` | World Cup 2026 (12×4, 8 best thirds), Euro (6×4, 4 best thirds), classic 8×4 World Cup, Club World Cup 32 |
| `league` | Any round robin, single or double (e.g. a 20-team, 380-match league) |

## Install

1. Copy `modules/TournamentEngine.lua` **and** the `modules/TournamentEngine/` folder into
   `<Football Life 26>\sider\modules\`.
2. In `sider.ini`:
   ```ini
   match-stats.enabled = 1
   lua.module = "TournamentEngine.lua"
   ```
   `match-stats.enabled` turns on sider's scoreboard library, which the module uses to read results.
3. Pick the competition in `modules\TournamentEngine\TournamentEngine.ini`
   (`ucl-league-phase.txt` or `world-cup-2026.txt`). Set your team with
   `controlled = Arsenal` (or `controlled = all` to play every match yourself).
4. Start the game and open the sider overlay. Page 1 lists the fixtures to play next.

## Playing a fixture

1. Open the overlay and read your next fixture, e.g. `Olympiacos v *Arsenal - League phase - Matchday 1`.
2. Start an **exhibition match** with those two teams (home team on the left). The overlay
   confirms `-> result will be recorded`. If you picked them the wrong way round, it still works.
3. Play to full time. The result is recorded, the rest of the matchday is simulated, and the
   report is updated.

**Team ids.** sider identifies teams by numeric id. The module tries to read FL26's `Team.bin`
and match the names in your competition file. The first match you set up tells it which column
of the file holds the ids, and it saves that. If a team still isn't recognised, the overlay says
so: select the two teams in the exhibition menu and press **[4]**. The ids are linked and saved
for every later edition.

Overlay keys: `[1]` page (next fixtures, table/groups, knockout, results) · `[2]` scroll
· `[3]` twice: simulate your next match instead of playing it · `[4]` link selected teams
· `[5]` twice: new edition (fresh draw, ids kept).

## Writing a competition

```ini
name = Europa League 2026/27
format = swiss
seed = 1                    ; any text; the same seed always gives the same draw
direct = 8                  ; 1-8 straight to the Round of 16
playoff = 16                ; 9-24 knockout play-offs
knockout_legs = 2           ; the final is always one match
controlled = Aston Villa
team = Aston Villa | ENG | 1 | 82      ; Name | country | pot | rating (60-95)
team = Roma        | ITA | 1 | 80 | id=12345   ; optional explicit sider team id
...
```

For `groups`, pots define the group seeding: there are as many groups as teams per pot.
`advance_per_group` and `best_thirds` decide who qualifies, and `confed_limit = UEFA:2` caps
teams per group (the country column holds the confederation). Add `group=A` to pre-place a host.

Before playing, check a competition from the command line. This simulates every match:

```sh
luajit tools/preview.lua modules/TournamentEngine/world-cup-2026.txt report.html
```

## How it works

- **Deterministic.** The draw, schedule and simulated results are all derived from `seed`
  (plus the edition number). The save file only stores *your* results and the linked team ids.
  On load, the competition is rebuilt and your results replayed into it.
- **Draw.** A backtracking search over pot pairings. The schedule is an edge colouring with
  Kempe-chain repairs, so each club plays exactly once per matchday.
- **Simulation.** Poisson goals from the rating gap and home advantage. Knockouts that need a
  winner get extra time, then a seeded penalty shoot-out.
- **Tables.** Sorted by points, goal difference, goals scored, wins, away goals, then rating.
  Best third-placed teams are ranked the same way.
- **Seeding.** Play-offs pair 9 v 24 … 16 v 17. Seed *s* in the Round of 16 meets the winner of
  the play-off tie containing seed 17−*s*. Group-stage qualifiers are seeded winners first, then
  runners-up, then thirds, and teams from the same group are kept apart in the first knockout
  round. The bracket is a standard seeded bracket, not FIFA's or UEFA's fixed slot tables.
- **sider events used:** `set_teams`, `set_match_settings` (extra time and penalties),
  `set_match_time` (optional shorter deciders), `set_stadium` (optional final venue),
  `display_frame` with `match.stats()` (score), `livecpk_data_ready` (`Team.bin`),
  `context_reset`, `overlay_on`, `key_down`.

## Tests

```sh
./run_tests.sh      # luajit (sider's runtime) or lua5.1, about 1 second
```

The 28 tests check:
- **Swiss draw** rules on 150 random draws, and that each one schedules into exactly 8 clash-free
  matchdays.
- **Group draw** pot and confederation rules on 150 random draws.
- **Full competitions** run to a champion: 40 Champions League editions and 40 World Cup editions,
  checking seeding, play-off pairings and the ranking of third-placed teams.
- **Other formats:** Euro and 20-team double round-robin layouts.
- **Ties:** deciders after level aggregates and after drawn single-leg knockouts.
- **Saving:** a save/restore round-trip rebuilds an identical competition.
- **Through a mocked sider:** linking team ids, extra-time rules, reading results from the
  scoreboard, picking teams the wrong way round, quitting a match, restarting the game, playing
  a whole Champions League to the final, a new edition, auto-calibrating `Team.bin` names, and the
  overlay messages for errors.
- **sider's restricted environment:** the module is loaded with only the globals sider gives it.

**Limits.** `Team.bin` parsing uses the record layout from sider's `team_bin_reader` example. If
FL26's file differs, the fallback is linking with [4]. The scoreboard library is marked
experimental by sider, and the module hasn't yet been run inside FL26 itself.
