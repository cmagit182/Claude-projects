-- FormBook test suite. Runs under LuaJIT (sider's runtime) or Lua 5.1:
--   ./run_tests.sh
-- The sider runtime (ctx, match.stats, fs, log) is mocked so whole matches
-- can be simulated frame by frame.
local root = arg[1] or "."
local tmp = arg[2] or os.getenv("TMPDIR") or "/tmp"
package.path = root .. "/modules/?.lua;" .. package.path

local logs = {}
log = function(msg) logs[#logs + 1] = msg end

local m = require("FormBook")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("ok   " .. name)
  else failed = failed + 1; print("FAIL " .. name .. "\n     " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function R(h, a, hg, ag, extra)
  local r = { home_id = h, away_id = a, home_goals = hg, away_goals = ag, decided = "FT",
              tournament_id = 17, match_info = 1, date = "2026-10-15" }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

---------------------------------------------------------------------------
-- Pure logic
---------------------------------------------------------------------------
test("outcome handles home/away, draws and shoot-outs", function()
  eq(m.outcome(R(1, 2, 2, 0), 1), "W"); eq(m.outcome(R(1, 2, 2, 0), 2), "L")
  eq(m.outcome(R(1, 2, 1, 1), 2), "D"); eq(m.outcome(R(1, 2, 1, 1), 3), nil)
  local pens = R(1, 2, 1, 1, { decided = "PENS", home_pens = 3, away_pens = 4 })
  eq(m.outcome(pens, 1), "L"); eq(m.outcome(pens, 2), "W")
end)

test("head_to_head aggregates across venues", function()
  local res = { R(1, 2, 2, 0), R(2, 1, 1, 1), R(3, 1, 0, 5), R(2, 1, 3, 1, { date = "2026-10-20" }) }
  local h = m.head_to_head(res, 1, 2)
  eq(h.played, 3); eq(h.a_wins, 1); eq(h.b_wins, 1); eq(h.draws, 1)
  eq(h.a_goals, 4); eq(h.b_goals, 4); eq(h.last.date, "2026-10-20")
  eq(m.head_to_head(res, 2, 3).played, 0)
end)

test("form returns last n oldest-first, skipping other teams", function()
  local res = { R(1, 2, 0, 1), R(3, 4, 9, 9), R(1, 3, 2, 2), R(4, 1, 0, 3), R(1, 5, 1, 0) }
  eq(m.form(res, 1, 5), "LDWW"); eq(m.form(res, 1, 2), "WW"); eq(m.form(res, 9, 5), "")
end)

test("csv round-trip incl. empty pens and missing difficulty", function()
  local r = R(101, 202, 2, 2, { decided = "PENS", home_pens = 5, away_pens = 4, difficulty = 3 })
  local back = m.csv_to_result(m.result_to_csv(r))
  for _, k in ipairs({ "date", "tournament_id", "home_id", "away_id", "home_goals",
                       "away_goals", "home_pens", "away_pens", "decided", "difficulty" }) do
    eq(back[k], r[k], k)
  end
  local plain = m.csv_to_result(m.result_to_csv(R(1, 2, 0, 0)))
  eq(plain.home_pens, nil); eq(plain.difficulty, nil)
  local list = m.parse_results("date,tournament_id\n" .. m.result_to_csv(r) .. "\r\ngarbage\n\n" ..
    m.result_to_csv(R(1, 2, 3, 0)) .. "\n")
  eq(#list, 2)
end)

test("completion recognises FT, AET, PENS and boundary minutes", function()
  eq(m.completion({ period = 2, clock_minutes = 93 }), "FT")
  eq(m.completion({ period = 3, clock_minutes = 90 }), "FT")   -- whistle on 90:00, no added time
  eq(m.completion({ period = 2, clock_minutes = 70 }), nil)
  eq(m.completion({ period = 3, clock_minutes = 98 }), nil)    -- abandoned in extra time
  eq(m.completion({ period = 4, clock_minutes = 121 }), "AET")
  eq(m.completion({ period = 4, clock_minutes = 110 }), nil)
  eq(m.completion({ period = 5, clock_minutes = 120 }), "PENS")
  eq(m.completion(nil), nil)
end)

test("detect_my_team finds the career team", function()
  local res = { R(9, 8, 0, 0), R(1, 2, 0, 0), R(3, 1, 0, 0), R(1, 4, 0, 0), R(5, 1, 0, 0), R(1, 6, 0, 0) }
  eq(m.detect_my_team(res, 5, 3), 1)
  eq(m.detect_my_team({ R(1, 2, 0, 0), R(1, 3, 0, 0) }, 5, 3), nil, "too few")
  eq(m.detect_my_team({ R(1, 2, 0, 0), R(3, 4, 0, 0), R(1, 5, 0, 0) }, 5, 3), nil, "no common team")
  eq(m.detect_my_team({ R(7, 2, 0, 0), R(3, 2, 0, 0), R(2, 5, 0, 0) }, 5, 3), 2, "away side")
end)

test("adaptive difficulty: promote, demote, hold, clamp, streak per level", function()
  local cfg = m.parse_config("")
  local function at(d, hg, ag) return R(1, 2, hg, ag, { difficulty = d }) end
  -- three wins at Professional -> Top Player
  local lvl, info = m.next_difficulty({ at(3, 2, 0), at(3, 1, 0), at(3, 3, 1) }, 1, cfg, 3)
  eq(lvl, 4); eq(info.played, 3); eq(info.change, 1)
  -- only two results at the level: hold
  eq((m.next_difficulty({ at(3, 2, 0), at(3, 1, 0) }, 1, cfg, 3)), 3)
  -- results at the previous level don't count towards the new one
  eq((m.next_difficulty({ at(3, 1, 0), at(3, 1, 0), at(3, 1, 0), at(4, 0, 1), at(4, 1, 0) }, 1, cfg, 4)), 4)
  -- three losses -> step down
  eq((m.next_difficulty({ at(4, 0, 1), at(4, 0, 2), at(4, 1, 1) }, 1, cfg, 4)), 3)
  -- mixed (W D L: 1.33 ppg) -> hold
  eq((m.next_difficulty({ at(4, 1, 0), at(4, 1, 1), at(4, 0, 1) }, 1, cfg, 4)), 4)
  -- clamps
  eq((m.next_difficulty({ at(6, 5, 0), at(6, 5, 0), at(6, 5, 0) }, 1, cfg, 6)), 6)
  eq((m.next_difficulty({ at(2, 0, 5), at(2, 0, 5), at(2, 0, 5) }, 1, cfg, 2)), 2)
  -- no history -> fallback
  eq((m.next_difficulty({}, 1, cfg, 5)), 5)
  -- window: only last 5 at level count (3 old losses + 5 wins -> promote)
  local res = { at(3, 0, 1), at(3, 0, 1), at(3, 0, 1) }
  for _ = 1, 5 do res[#res + 1] = at(3, 2, 0) end
  eq((m.next_difficulty(res, 1, cfg, 3)), 4)
end)

test("parse_config: values, names, warnings, sanity fixes", function()
  local cfg, w = m.parse_config([[
; comment
adaptive = yes
my_team = 101
window = 4
promote_ppg = 2.5   ; inline comment
team.101 = Arsenal FC
tournament.17 = "Premier League"
]])
  eq(#w, 0, table.concat(w, ";"))
  eq(cfg.adaptive, true); eq(cfg.my_team, 101); eq(cfg.window, 4); eq(cfg.promote_ppg, 2.5)
  eq(cfg.team_names[101], "Arsenal FC"); eq(cfg.tournament_names[17], "Premier League")
  eq(cfg.tournament_names[65535], "Friendly")
  eq(m.DEFAULT_CONFIG.team_names[101], nil, "defaults untouched")
  local c2, w2 = m.parse_config("window = 99\nmy_team = me\nwhat = 1\nmin_difficulty = 6\nmax_difficulty = 1\ndemote_ppg = 2.9")
  eq(#w2, 5, table.concat(w2, ";"))
  eq(c2.window, 5); eq(c2.my_team, "auto")
  eq(c2.min_difficulty, 1); eq(c2.max_difficulty, 6)
  eq(c2.demote_ppg, 0.8)
end)

test("tracker: full time, resume after scoreboard blip, abandon", function()
  local t = m.new_tracker()
  local fx = { home_id = 1, away_id = 2, tournament_id = 17, difficulty = 3 }
  eq(m.track(t, { period = 1, clock_minutes = 10, home_score = 0, away_score = 0 }, fx), nil)
  eq(m.track(t, nil, fx), nil); eq(t.state, "suspended")       -- half-time blip
  m.track(t, { period = 2, clock_minutes = 60, home_score = 1, away_score = 0 }, fx)
  eq(t.state, "live")
  m.track(t, { period = 2, clock_minutes = 92, home_score = 2, away_score = 1 }, fx)
  local r = m.track(t, nil, fx)
  assert(r, "no result")
  eq(r.home_goals, 2); eq(r.away_goals, 1); eq(r.decided, "FT"); eq(r.difficulty, 3)
  eq(t.state, "idle")
  -- abandoned: suspended then a different fixture starts
  m.track(t, { period = 1, clock_minutes = 30, home_score = 0, away_score = 0 }, fx)
  m.track(t, nil, fx)
  m.track(t, { period = 1, clock_minutes = 1, home_score = 0, away_score = 0 }, { home_id = 5, away_id = 6 })
  eq(t.pending.home_id, 5)
end)

---------------------------------------------------------------------------
-- End-to-end with mocked sider
---------------------------------------------------------------------------
local sider_dir = tmp .. "/formbook-test-" .. os.time() .. "-" .. math.random(1e6) .. "/"
os.execute("mkdir -p '" .. sider_dir .. "modules'")
os.execute("cp '" .. root .. "/modules/FormBook.ini' '" .. sider_dir .. "modules/'")
fs = { make_dirs = function(p) os.execute("mkdir -p '" .. p .. "'") end }

local live_stats = nil
match = { stats = function() return live_stats end }

local handlers = {}
local ctx = { sider_dir = sider_dir, register = function(e, f) handlers[e] = f end }

local function frames(n) for _ = 1, n do handlers.display_frame(ctx) end end

-- Simulate a whole match: list of {period, minute, home, away[, pkh, pka]}
local function play(home, away, tournament, timeline, difficulty)
  ctx.home_team, ctx.away_team, ctx.tournament_id, ctx.match_info = home, away, tournament, 1
  handlers.set_teams(ctx, home, away)
  local opts = handlers.set_match_settings(ctx, { difficulty = difficulty or 3, extra_time = 0 })
  for _, s in ipairs(timeline) do
    live_stats = { period = s[1], clock_minutes = s[2], clock_seconds = 0,
                   home_score = s[3], away_score = s[4], pk_home_score = s[5] or 0, pk_away_score = s[6] or 0 }
    frames(30)
  end
  live_stats = nil
  frames(30)
  return opts
end

local function overlay() return handlers.overlay_on(ctx) end

test("e2e: init registers handlers and creates data dir", function()
  m.init(ctx)
  for _, e in ipairs({ "display_frame", "set_teams", "context_reset", "set_match_settings",
                       "overlay_on", "key_down" }) do assert(handlers[e], "missing " .. e) end
  eq(#m._state().results, 0)
  assert(m._state().csv_path:find("FormBook/results.csv", 1, true), m._state().csv_path)
end)

test("e2e: matches are recorded to CSV with FT/AET/PENS", function()
  play(101, 202, 17, { { 1, 20, 1, 0 }, { 2, 75, 1, 1 }, { 2, 94, 2, 1 } })
  play(202, 101, 17, { { 1, 30, 0, 0 }, { 2, 91, 1, 1 }, { 3, 100, 1, 1 }, { 4, 121, 1, 2 } })
  play(101, 303, 65535, { { 2, 90, 0, 0 }, { 4, 120, 0, 0 }, { 5, 120, 0, 0, 3, 2 }, { 5, 120, 0, 0, 4, 3 } })
  local res = m._state().results
  eq(#res, 3)
  eq(res[1].decided, "FT"); eq(res[2].decided, "AET"); eq(res[3].decided, "PENS")
  eq(res[3].home_pens, 4); eq(res[3].away_pens, 3); eq(res[1].difficulty, 3)
  local f = assert(io.open(m._state().csv_path)); local text = f:read("*a"); f:close()
  assert(text:match("^date,tournament_id"), "header")
  eq(#m.parse_results(text), 3, "csv rows")
end)

test("e2e: abandoned match is not recorded; context_reset flushes a finished one", function()
  play(101, 404, 17, { { 1, 10, 0, 3 } })                -- quit at 10'
  handlers.set_teams(ctx, 101, 505)                      -- next fixture -> abandon
  eq(#m._state().results, 3)
  -- finished match whose scoreboard disappearance wasn't polled yet
  ctx.home_team, ctx.away_team = 101, 505
  handlers.set_teams(ctx, 101, 505)
  live_stats = { period = 2, clock_minutes = 95, home_score = 3, away_score = 0 }
  frames(30)
  live_stats = nil
  handlers.context_reset(ctx)
  eq(#m._state().results, 4)
  eq(m._state().results[4].away_id, 505)
end)

test("e2e: data survives a restart (re-init reads CSV)", function()
  handlers = {}
  m.init(ctx)
  eq(#m._state().results, 4)
end)

test("e2e: overlay briefing shows h2h, last meeting, form and names", function()
  ctx.home_team, ctx.away_team, ctx.tournament_id = 101, 202, 17
  handlers.set_teams(ctx, 101, 202)
  local text = overlay()
  assert(text:find("Head%-to%-head %(2%)"), text)
  assert(text:find("Last meeting"), text)
  assert(text:find("aet"), text)
  assert(text:find("Form: Team 101 WWWW   |   Team 202 LL", 1, true), text)
  eq(overlay(), text, "cached text stable")
  handlers.key_down(ctx, 0x31)
  assert(overlay():find("Recent results %(4 recorded%)"), overlay())
  handlers.key_down(ctx, 0x31)
  assert(overlay():find("Adaptive difficulty: OFF"), overlay())
  assert(overlay():find("Your team: Team 101 %(auto%)"), overlay())
  handlers.key_down(ctx, 0x31)
  assert(overlay():find("page 1/3"))
  handlers.context_reset(ctx)
  assert(overlay():find("Recent results"), "menu shows recent results, not a stale briefing")
end)

test("e2e: undo needs two presses and rewrites the CSV", function()
  handlers.key_down(ctx, 0x33)
  eq(#m._state().results, 4); assert(overlay():find("PRESS AGAIN"))
  handlers.key_down(ctx, 0x31)                            -- any other key disarms
  handlers.key_down(ctx, 0x33); handlers.key_down(ctx, 0x33)
  eq(#m._state().results, 3)
  local f = assert(io.open(m._state().csv_path)); local text = f:read("*a"); f:close()
  eq(#m.parse_results(text), 3)
  assert(overlay():find("Deleted: Team 101 3%-0 Team 505"), overlay())
end)

test("e2e: adaptive difficulty steps up for the player's team only", function()
  handlers.key_down(ctx, 0x32)
  eq(m._state().cfg.adaptive, true)
  -- Team 101 already has three wins recorded at Professional (3), so the
  -- next match is promoted to Top Player (4). The streak then restarts:
  -- it takes three more wins at 4 before Super Star (5).
  local seen = {}
  for i = 1, 4 do
    local opts = play(101, 600 + i, 17, { { 2, 92, 3, 0 } }, 3)   -- menu says 3 each time
    assert(opts, "settings should be changed")
    seen[i] = opts.difficulty
  end
  eq(table.concat(seen, ","), "4,4,4,5")
  local res = m._state().results
  eq(res[#res].difficulty, 5, "recorded at the level actually played")
  -- three heavy defeats at 5 -> back down to 4
  for i = 1, 3 do play(101, 700 + i, 17, { { 2, 92, 0, 4 } }, 3) end
  eq(play(101, 800, 17, { { 2, 92, 1, 1 } }, 3).difficulty, 4)
  -- a match not involving my team is left alone
  ctx.home_team, ctx.away_team = 800, 801
  handlers.set_teams(ctx, 800, 801)
  eq(handlers.set_match_settings(ctx, { difficulty = 2 }), nil)
  local found = false
  for _, l in ipairs(logs) do if l:find("adaptive difficulty for Team 101") then found = true end end
  assert(found, "log line")
end)

test("e2e: missing match-stats library is reported on the overlay", function()
  local saved = match
  match = nil
  frames(30)
  assert(overlay():find("match%-stats%.enabled = 1"), overlay())
  match = saved
end)

test("module loads and runs inside sider's restricted environment", function()
  -- sider gives modules only these globals (scripting guide, section 6)
  local env = {}
  for _, k in ipairs({ "assert", "ipairs", "pairs", "tostring", "tonumber", "table", "string",
                       "math", "unpack", "type", "error", "io", "os", "_VERSION" }) do env[k] = _G[k] end
  env._G = env
  env.log, env.fs, env.match = log, fs, match
  local chunk = assert(loadfile(root .. "/modules/FormBook.lua"))
  setfenv(chunk, env)
  local mod = chunk()
  local h = {}
  mod.init({ sider_dir = sider_dir, register = function(e, f) h[e] = f end })
  for _ = 1, 30 do h.display_frame({}) end
  assert(h.overlay_on({}):find("FormBook"))
end)

os.execute("rm -rf '" .. sider_dir .. "'")
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
