-- Tournament Engine test suite (LuaJIT / Lua 5.1):  ./run_tests.sh
local root = arg[1] or "."
local tmp = arg[2] or "/tmp"
package.path = root .. "/modules/?.lua;" .. package.path

local logs = {}
log = function(msg) logs[#logs + 1] = msg end
local m = require("TournamentEngine")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("ok   " .. name)
  else failed = failed + 1; print("FAIL " .. name .. "\n     " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function read(path) local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s end

local COMP_DIR = root .. "/modules/TournamentEngine/"
local UCL = read(COMP_DIR .. "ucl-league-phase.txt")
local WC = read(COMP_DIR .. "world-cup-2026.txt")

local function load(text, overrides)
  for k, v in pairs(overrides or {}) do
    if text:find("\n" .. k .. " =") then
      text = text:gsub("\n" .. k .. " = [^\n]*", "\n" .. k .. " = " .. v)
    else
      text = k .. " = " .. v .. "\n" .. text
    end
  end
  local comp, errors, warnings = m.parse_competition(text)
  assert(#errors == 0, table.concat(errors, "; "))
  return comp, warnings
end

---------------------------------------------------------------------------
-- Building blocks
---------------------------------------------------------------------------
test("seed_order keeps top seeds apart", function()
  eq(table.concat(m.seed_order(8), ","), "1,8,4,5,2,7,3,6")
  eq(table.concat(m.seed_order(4), ","), "1,4,2,3")
  eq(#m.seed_order(16), 16)
end)

test("name_key folds accents and punctuation", function()
  eq(m.name_key("Bayern München"), "bayernmunchen")
  eq(m.name_key("Bodø/Glimt"), "bodoglimt")
  eq(m.name_key("Atlético Madrid"), "atleticomadrid")
  eq(m.name_key("Qarabağ"), "qarabag")
  eq(m.name_key("Curaçao"), "curacao")
end)

test("round robin: every pair meets once per leg, nobody plays twice a round", function()
  for _, n in ipairs({ 4, 5, 18, 20 }) do
    local list = {}
    for i = 1, n do list[i] = i end
    for legs = 1, 2 do
      local rounds = m.round_robin(list, legs)
      local meet = {}
      for _, games in ipairs(rounds) do
        local busy = {}
        for _, g in ipairs(games) do
          assert(not busy[g.home] and not busy[g.away], "double booking")
          busy[g.home], busy[g.away] = true, true
          local k = math.min(g.home, g.away) .. "-" .. math.max(g.home, g.away)
          meet[k] = (meet[k] or 0) + 1
        end
      end
      local pairs_ = 0
      for _, c in pairs(meet) do eq(c, legs); pairs_ = pairs_ + 1 end
      eq(pairs_, n * (n - 1) / 2)
      eq(#rounds, (n % 2 == 0 and n - 1 or n) * legs)
    end
  end
end)

test("swiss draw: UEFA rules hold for 150 different seeds", function()
  local comp = load(UCL)
  for seed = 1, 150 do
    local rng = m.rng("t" .. seed)
    local matches = assert(m.swiss_draw(comp, rng))
    eq(#matches, 144)
    local per = {}
    for i = 1, 36 do per[i] = { n = 0, home = {}, away = {}, opp = {}, country = {} } end
    for _, mt in ipairs(matches) do
      local h, a = comp.teams[mt.home], comp.teams[mt.away]
      assert(h.country ~= a.country, "same country " .. h.name .. " v " .. a.name)
      for _, side in ipairs({ { mt.home, mt.away, "home" }, { mt.away, mt.home, "away" } }) do
        local p = per[side[1]]
        local o = comp.teams[side[2]]
        p.n = p.n + 1
        assert(not p.opp[side[2]], "same opponent twice")
        p.opp[side[2]] = true
        p[side[3]][o.pot] = (p[side[3]][o.pot] or 0) + 1
        p.country[o.country] = (p.country[o.country] or 0) + 1
      end
    end
    for i = 1, 36 do
      eq(per[i].n, 8, "matches")
      for pot = 1, 4 do
        eq(per[i].home[pot], 1, comp.teams[i].name .. " home vs pot " .. pot)
        eq(per[i].away[pot], 1, comp.teams[i].name .. " away vs pot " .. pot)
      end
      for c, k in pairs(per[i].country) do assert(k <= 2, comp.teams[i].name .. " meets 3 from " .. c) end
    end
    -- schedule: 8 matchdays, each club once per matchday
    local rounds = m.schedule(matches, 36, 8, rng)
    eq(#rounds, 8, "matchdays (seed " .. seed .. ")")
    for _, games in ipairs(rounds) do
      eq(#games, 18)
      local busy = {}
      for _, g in ipairs(games) do
        assert(not busy[g.home] and not busy[g.away]); busy[g.home], busy[g.away] = true, true
      end
    end
  end
end)

test("group draw: one per pot, confederation limits, hosts fixed (150 seeds)", function()
  local comp = load(WC)
  for seed = 1, 150 do
    local groups = assert(m.group_draw(comp, m.rng("g" .. seed)))
    eq(#groups, 12)
    for g, members in ipairs(groups) do
      eq(#members, 4)
      local pots, conf = {}, {}
      for _, i in ipairs(members) do
        local t = comp.teams[i]
        assert(not pots[t.pot], "two teams from one pot")
        pots[t.pot] = true
        conf[t.country] = (conf[t.country] or 0) + 1
        if t.fixed_group then eq(t.fixed_group, g, t.name .. " group") end
      end
      for c, k in pairs(conf) do assert(k <= (c == "UEFA" and 2 or 1), "confed " .. c .. " x" .. k) end
    end
  end
end)

test("simulation: deterministic, knockouts always produce a winner, ratings matter", function()
  local comp = load(UCL)
  local fx = { key = "X", home = 1, away = 36, needs_winner = true }
  local a, b = m.simulate(comp, fx), m.simulate(comp, fx)
  eq(a.home_goals, b.home_goals); eq(a.away_goals, b.away_goals)
  local strong, weak, n = 0, 0, 3000
  for i = 1, n do
    local r = m.simulate(comp, { key = "K" .. i, home = 1, away = 36, needs_winner = true })
    local hw = r.home_goals > r.away_goals or (r.home_goals == r.away_goals and r.home_pens > r.away_pens)
    assert(r.home_goals ~= r.away_goals or (r.home_pens and r.home_pens ~= r.away_pens), "no winner")
    if hw then strong = strong + 1 else weak = weak + 1 end
  end
  assert(strong / n > 0.75, "PSG (90) should beat Kairat (64) most of the time: " .. strong / n)
  -- league matches between equals: plausible draw rate and goals
  local draws, goals = 0, 0
  for i = 1, n do
    local r = m.simulate(comp, { key = "L" .. i, home = 2, away = 1 })
    if r.home_goals == r.away_goals then draws = draws + 1 end
    goals = goals + r.home_goals + r.away_goals
  end
  assert(draws / n > 0.18 and draws / n < 0.34, "draw rate " .. draws / n)
  assert(goals / n > 2.2 and goals / n < 3.4, "goals per game " .. goals / n)
end)

---------------------------------------------------------------------------
-- Whole competitions
---------------------------------------------------------------------------
test("UCL format runs to a champion with the right structure (40 editions)", function()
  for seed = 1, 40 do
    local comp = load(UCL, { seed = "s" .. seed, controlled = "none" })
    comp.controlled = {}
    local st = m.new_state(comp)
    eq(st.error, nil); eq(st.phase, "done")
    eq(st.ko[1].name, "Knockout play-offs"); eq(#st.ko[1].ties, 8)
    eq(st.ko[2].name, "Round of 16"); eq(st.ko[5].name, "Final")
    -- play-off pairs: 9 v 24 ... 16 v 17
    for _, tie in ipairs(st.ko[1].ties) do eq(st.seed_of[tie.a] + st.seed_of[tie.b], 33) end
    -- R16: each top-8 seed s meets the winner of the tie whose top seed is 17-s
    for _, tie in ipairs(st.ko[2].ties) do
      local s = st.seed_of[tie.a]
      assert(s <= 8, "R16 'a' must be a top-8 seed")
      local ob = st.seed_of[tie.b]
      assert(ob == 17 - s or ob == 16 + s, string.format("seed %d drew seed %d", s, ob))
    end
    -- league phase: every club 8 matches, 4 home
    local cnt, home = {}, {}
    for _, fx in ipairs(st.fixtures) do
      if fx.phase == "league" then
        cnt[fx.home] = (cnt[fx.home] or 0) + 1; cnt[fx.away] = (cnt[fx.away] or 0) + 1
        home[fx.home] = (home[fx.home] or 0) + 1
      end
    end
    for i = 1, 36 do eq(cnt[i], 8); eq(home[i], 4) end
    -- two-legged knock-outs, single-match final at a neutral venue
    eq(#st.ko[2].ties[1].fixtures >= 2, true)
    eq(st.ko[5].ties[1].fixtures[1].neutral, true)
    assert(st.champion == st.ko[5].ties[1].winner)
  end
end)

test("World Cup 2026 format: 8 best thirds, R32 without same-group pairs (40 editions)", function()
  for seed = 1, 40 do
    local comp = load(WC, { seed = "w" .. seed })
    comp.controlled = {}
    local st = m.new_state(comp)
    eq(st.error, nil); eq(st.phase, "done")
    eq(st.ko[1].name, "Round of 32"); eq(#st.ko[1].ties, 16)
    local thirds = 0
    for _ in pairs(st.best_thirds) do thirds = thirds + 1 end
    eq(thirds, 8)
    local seen = {}
    for _, tie in ipairs(st.ko[1].ties) do
      assert(st.group_of[tie.a] ~= st.group_of[tie.b], "same-group R32 tie")
      assert(not seen[tie.a] and not seen[tie.b]); seen[tie.a], seen[tie.b] = true, true
      eq(#tie.fixtures >= 1, true)
      assert(tie.fixtures[1].needs_winner, "single-leg KO needs a winner")
    end
    -- the 8 best thirds really are better than the 4 eliminated thirds
    local function key(r) return r.pts * 10000 + (r.gf - r.ga + 100) * 100 + r.gf end
    local worst_in, best_out = math.huge, -math.huge
    for _, t in ipairs(st.group_tables) do
      local r = t[3]
      if st.best_thirds[r.idx] then worst_in = math.min(worst_in, key(r)) else best_out = math.max(best_out, key(r)) end
    end
    assert(worst_in >= best_out, "third-place ranking")
    eq(#st.fixtures >= 72 + 31, true)
  end
end)

test("custom formats: Euro (6 groups + 4 thirds), double round-robin league", function()
  local lines = { "name = Euro", "format = groups", "best_thirds = 4", "confed_default_limit = 9", "seed = e" }
  for g = 1, 6 do for p = 1, 4 do
    lines[#lines + 1] = string.format("team = T%d%d | X%d%d | %d | %d", g, p, g, p, p, 90 - p * 5)
  end end
  local comp = load(table.concat(lines, "\n"))
  comp.controlled = {}
  local st = m.new_state(comp)
  eq(st.phase, "done"); eq(st.ko[1].name, "Round of 16")

  local l = { "name = Liga", "format = league", "legs = 2", "seed = l" }
  for i = 1, 20 do l[#l + 1] = string.format("team = Club %d | ESP | 1 | %d", i, 60 + i) end
  local lc = load(table.concat(l, "\n"))
  lc.controlled = {}
  local ls = m.new_state(lc)
  eq(ls.phase, "done"); eq(#ls.fixtures, 380)
  eq(ls.final_table[1].p, 38)
  eq(ls.champion, ls.final_table[1].idx)
end)

test("competition file errors are reported", function()
  local _, e1 = m.parse_competition("format = swiss\nteam = A | X | 1 | 80\nteam = B | Y | 2 | 80")
  assert(#e1 > 0)
  local _, e2 = m.parse_competition("format = groups\nbest_thirds = 3\nteam = A | X | 1 | 80\nteam = B | X | 2 | 80")
  assert(#e2 > 0, "qualifiers not a power of 2")
  local _, e3 = m.parse_competition("format = cup")
  assert(#e3 > 0)
  local _, e4 = m.parse_competition("format = league\nteam = A | X | 1 | 80\nteam = a | X | 1 | 80")
  assert(table.concat(e4, ";"):find("duplicate"))
  local _, _, w = m.parse_competition("format = league\ncontrolled = Nobody\nteam = A | X | 1 | 80\nteam = B | X | 1 | 70")
  assert(table.concat(w, ";"):find("Nobody"))
end)

---------------------------------------------------------------------------
-- Playing as the user
---------------------------------------------------------------------------
test("user fixtures wait for the player; others are simulated around them", function()
  local comp = load(UCL)
  local st = m.new_state(comp)
  local open = m.open_fixtures(st)
  eq(#open, 1); eq(open[1].round, 1)
  assert(comp.teams[open[1].home].name == "Arsenal" or comp.teams[open[1].away].name == "Arsenal")
  -- the rest of matchday 1 kicks off only after you've played yours
  for _, fx in ipairs(st.fixtures) do
    if fx.round == 1 and fx ~= open[1] then assert(not st.results[fx.key], "simulated too early") end
  end
  eq(select(2, m.record(st, open[1].key .. "nope", { home_goals = 1, away_goals = 0 })), "unknown fixture " .. open[1].key .. "nope")
  assert(m.record(st, open[1].key, { home_goals = 2, away_goals = 1 }))
  eq(m.open_fixtures(st)[1].round, 2)
  for _, fx in ipairs(st.fixtures) do
    if fx.round == 1 then assert(st.results[fx.key], "matchday 1 complete") end
    if fx.round == 2 then assert(not st.results[fx.key], "matchday 2 waits for you") end
  end
  -- a later fixture can't be recorded early
  local later
  for _, fx in ipairs(st.fixtures) do if fx.round == 5 and m.is_controlled(st, fx) then later = fx end end
  eq(select(2, m.record(st, later.key, { home_goals = 0, away_goals = 0 })), "not playable yet")
  eq(m.match_rules(m.open_fixtures(st)[1]).extra_time, 0, "no extra time in the league phase")
end)

-- Plays the whole competition as the user with a scripted score function
local function play_through(st, score_fn)
  local guard = 0
  while st.phase ~= "done" do
    guard = guard + 1
    assert(guard < 500, "stuck")
    local open = m.open_fixtures(st)
    assert(#open > 0, "no open fixture but not done: " .. tostring(st.phase))
    local fx = open[1]
    assert(m.record(st, fx.key, score_fn(fx)))
  end
end

test("two-legged tie level on aggregate gets an ET+penalties decider", function()
  local comp = load(UCL, { controlled = "all" })
  local st = m.new_state(comp)
  local decider_seen = false
  play_through(st, function(fx)
    if fx.decider then
      decider_seen = true
      eq(m.match_rules(fx).extra_time, 1); eq(m.match_rules(fx).penalties, 1)
      return { home_goals = 1, away_goals = 1, home_pens = 5, away_pens = 3 }
    end
    if fx.leg then
      eq(m.match_rules(fx).extra_time, 0, "no ET in legs")
      return { home_goals = 1, away_goals = 0 }     -- 1-0, 0-1 -> 1-1 aggregate
    end
    if fx.final then
      eq(m.match_rules(fx).penalties, 1)
      return { home_goals = 3, away_goals = 2 }
    end
    return { home_goals = fx.home % 3, away_goals = fx.away % 2 }
  end)
  assert(decider_seen, "decider")
  -- every tie decided by the decider shoot-out in favour of the decider's home side (tie.a)
  for _, kr in ipairs(st.ko) do
    for _, tie in ipairs(kr.ties) do
      if kr.name ~= "Final" then eq(tie.winner, tie.a) end
    end
  end
  eq(st.champion, st.ko[#st.ko].ties[1].a)
end)

test("single-leg knockout drawn without penalties gets a decider", function()
  local comp = load(WC, { controlled = "all" })
  local st = m.new_state(comp)
  local deciders = 0
  play_through(st, function(fx)
    if fx.decider then deciders = deciders + 1; return { home_goals = 0, away_goals = 1 } end
    if fx.phase == "ko" then return { home_goals = 2, away_goals = 2 } end   -- e.g. ET disabled in-game
    return { home_goals = (fx.home * 7) % 4, away_goals = (fx.away * 3) % 3 }
  end)
  eq(deciders, 31, "one decider per knockout tie")
  for _, kr in ipairs(st.ko) do for _, tie in ipairs(kr.ties) do eq(tie.winner, tie.b) end end
end)

test("save/restore rebuilds the identical competition and continues", function()
  local comp = load(UCL)
  local st = m.new_state(comp)
  for k = 1, 5 do
    local fx = m.open_fixtures(st)[1]
    if k == 3 then m.simulate_open(st, fx.key)
    else m.record(st, fx.key, { home_goals = k, away_goals = 1 }) end
  end
  local text = m.serialize(st, { arsenal = 101 })
  local comp2 = load(UCL)
  local st2, ids, warnings, applied = m.restore(comp2, text)
  eq(#warnings, 0, table.concat(warnings, ";")); eq(applied, 5); eq(ids.arsenal, 101)
  eq(#st2.fixtures, #st.fixtures)
  for _, fx in ipairs(st.fixtures) do
    local a, b = st.results[fx.key], st2.results[fx.key]
    eq(st2.by_key[fx.key].home, fx.home)
    eq(a and a.home_goals, b and b.home_goals, fx.key)
    eq(a and a.away_goals, b and b.away_goals, fx.key)
  end
  eq(m.open_fixtures(st2)[1].key, m.open_fixtures(st)[1].key)
  -- a new edition gives a different draw
  local st3 = m.restore(load(UCL), "edition 2\n")
  local differs = false
  for i = 1, 20 do if st3.fixtures[i].key ~= st.fixtures[i].key then differs = true end end
  assert(differs, "edition 2 should redraw")
end)

test("HTML report contains tables, knockouts and the champion", function()
  local comp = load(UCL)
  comp.controlled = {}
  local st = m.new_state(comp)
  local html = m.report_html(st)
  assert(html:find("<!doctype html>", 1, true))
  assert(html:find("League phase", 1, true))
  assert(html:find("Knockout play-offs", 1, true))
  assert(html:find("Champion: <b>" .. comp.teams[st.champion].name, 1, true))
  assert(html:find("prefers-color-scheme:dark", 1, true))
end)

---------------------------------------------------------------------------
-- Team.bin
---------------------------------------------------------------------------
local function u32le(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function make_team_bin(entries)    -- id at offset 8, name at 234
  local out = {}
  for k, e in ipairs(entries) do
    local b = u32le(7) .. u32le(k % 3) .. u32le(e.id) .. string.rep("\0", 234 - 12)
    b = b .. e.name .. string.rep("\0", 70 - #e.name)
    b = b .. string.rep("\0", m.TEAMBIN_BLOCK - #b)
    out[#out + 1] = b
  end
  return table.concat(out)
end
local TEAMS = { { id = 101, name = "Arsenal" }, { id = 3001, name = "Bayern München" }, { id = 4417, name = "PSV" },
  { id = 2002, name = "Real Madrid" }, { id = 77, name = "Napoli" } }

test("Team.bin index: calibrates the id column from a known pair and maps names", function()
  local idx = assert(m.parse_team_bin(make_team_bin(TEAMS)))
  eq(idx.count, 5)
  eq(m.calibrate_team_bin(idx, 101, 4417), 8)
  eq(m.calibrate_team_bin(idx, 101, 999), nil)
  local by_name, by_id = m.team_bin_lookup(idx, 8)
  eq(by_name[m.name_key("Bayern München")], 3001)
  eq(by_id[77], "Napoli")
end)

---------------------------------------------------------------------------
-- End-to-end through a mocked sider
---------------------------------------------------------------------------
local sider_dir = tmp .. "/te-test-" .. os.time() .. "-" .. math.random(1e6) .. "/"
os.execute("mkdir -p '" .. sider_dir .. "modules/TournamentEngine'")
os.execute("cp '" .. COMP_DIR .. "'* '" .. sider_dir .. "modules/TournamentEngine/'")
local TE = sider_dir .. "modules/TournamentEngine/"

local live = nil
match = { stats = function() return live end }
memory = { read = function(addr, n) return addr:sub(1, n) end }   -- "addresses" are strings here
zlib = { unpack = function(s) return s end }

local H = {}
local ctx = { sider_dir = sider_dir, register = function(e, f) H[e] = f end }
local function frames(n) for _ = 1, n do H.display_frame(ctx) end end
local function overlay() return H.overlay_on(ctx) end
local function key(k) H.key_down(ctx, k) end
local function play_match(timeline)
  for _, s in ipairs(timeline) do
    live = { period = s[1], clock_minutes = s[2], home_score = s[3], away_score = s[4],
             pk_home_score = s[5] or 0, pk_away_score = s[6] or 0 }
    frames(15)
  end
  live = nil
  frames(15)
end

local S
test("e2e: init loads the UCL sample and writes save + HTML report", function()
  m.init(ctx)
  for _, e in ipairs({ "display_frame", "set_teams", "context_reset", "set_match_settings", "set_match_time",
                       "set_stadium", "livecpk_data_ready", "overlay_on", "key_down" }) do
    assert(H[e], "missing handler " .. e)
  end
  S = m._S()
  assert(S.state and S.state.comp.name:find("Champions League"), "loaded")
  assert(io.open(TE .. "ucl-league-phase.save")):close()
  assert(read(TE .. "ucl-league-phase.html"):find("League phase", 1, true))
  local o = overlay()
  assert(o:find("League phase %- Matchday 1"), o)
  assert(o:find("team id unknown"), "ids are not known yet:\n" .. o)
end)

local fx1
test("e2e: link unknown teams with [4], ET rules applied, result read from scoreboard", function()
  fx1 = m.open_fixtures(S.state)[1]
  H.set_teams(ctx, 5001, 5002)                         -- menu selection
  assert(overlay():find("not a scheduled fixture"))
  key(0x34)                                            -- link
  assert(S.active and S.active.fx == fx1)
  assert(overlay():find("Linked"), overlay())
  local opts = H.set_match_settings(ctx, { difficulty = 3, extra_time = 1, penalties = 1 })
  eq(opts.extra_time, 0); eq(opts.penalties, 0)
  play_match({ { 1, 10, 0, 0 }, { 2, 70, 1, 1 }, { 2, 93, 3, 1 } })
  local r = S.state.results[fx1.key]
  assert(r and not r.sim, "user result stored")
  eq(r.home_goals, 3); eq(r.away_goals, 1)
  assert(read(TE .. "ucl-league-phase.save"):find("R " .. fx1.key .. " 3 1 - - user", 1, true))
  local save = read(TE .. "ucl-league-phase.save")
  assert(save:find("I arsenal 500%d"), save)
end)

test("e2e: next fixture recognised by id (also with home/away swapped)", function()
  local fx2 = m.open_fixtures(S.state)[1]
  eq(fx2.round, 2)
  local T = S.state.comp.teams
  S.ids[T[fx2.home].key] = S.ids[T[fx2.home].key] or 6001
  S.ids[T[fx2.away].key] = S.ids[T[fx2.away].key] or 6002
  local hid, aid = S.ids[T[fx2.home].key], S.ids[T[fx2.away].key]
  H.set_teams(ctx, aid, hid)                           -- picked the wrong way round
  assert(S.active and S.active.swapped, "swapped fixture recognised")
  play_match({ { 2, 91, 2, 0 } })                      -- shown as away 2-0 home
  local r = S.state.results[fx2.key]
  eq(r.home_goals, 0); eq(r.away_goals, 2)
end)

test("e2e: abandoned match and non-fixture matches are not recorded", function()
  local fx3 = m.open_fixtures(S.state)[1]
  local T = S.state.comp.teams
  S.ids[T[fx3.home].key] = S.ids[T[fx3.home].key] or 7001
  S.ids[T[fx3.away].key] = S.ids[T[fx3.away].key] or 7002
  H.set_teams(ctx, S.ids[T[fx3.home].key], S.ids[T[fx3.away].key])
  play_match({ { 1, 30, 0, 2 } })                      -- quit at 30'
  H.context_reset(ctx)
  eq(S.state.results[fx3.key], nil)
  H.set_teams(ctx, 9998, 9999)                         -- random friendly
  play_match({ { 2, 95, 5, 0 } })
  eq(S.state.results[fx3.key], nil)
end)

test("e2e: [3] twice simulates the next match; overlay pages render", function()
  local fx3 = m.open_fixtures(S.state)[1]
  key(0x33)
  eq(S.state.results[fx3.key], nil, "first press only arms")
  key(0x33)
  assert(S.state.results[fx3.key] and S.state.results[fx3.key].skipped)
  key(0x31); assert(overlay():find("Pos Team"), overlay())
  local marked = false
  for _ = 1, 3 do
    if overlay():find("*Arsenal", 1, true) then marked = true end
    key(0x32)
  end
  assert(marked, "your club is marked in the table")
  assert(overlay():find("1%-12 of 36"), overlay())
  key(0x32); assert(overlay():find("13%-24 of 36"), overlay())
  key(0x31); assert(overlay():find("Knockout stage not reached yet"))
  key(0x31); assert(overlay():find("League phase %- Matchday 3 results"), overlay())
  assert(overlay():find("(played)", 1, true) or overlay():find("(skipped)", 1, true), overlay())
  key(0x31); eq(S.page, 1)
end)

test("e2e: progress survives a game restart", function()
  local done = 0
  for _, r in pairs(S.state.results) do if not r.sim then done = done + 1 end end
  H = {}
  m.init(ctx)
  S = m._S()
  local after = 0
  for _, r in pairs(S.state.results) do if not r.sim then after = after + 1 end end
  eq(after, done); eq(after, 3)
  eq(m.open_fixtures(S.state)[1].round, 4)
end)

test("e2e: play the whole Champions League to the final through the scoreboard", function()
  local guard = 0
  while S.state.phase ~= "done" do
    guard = guard + 1; assert(guard < 60, "stuck at " .. m.phase_text(S.state))
    local fx = m.open_fixtures(S.state)[1]
    local T = S.state.comp.teams
    S.ids[T[fx.home].key] = S.ids[T[fx.home].key] or (8000 + fx.home)
    S.ids[T[fx.away].key] = S.ids[T[fx.away].key] or (8000 + fx.away)
    H.set_teams(ctx, S.ids[T[fx.home].key], S.ids[T[fx.away].key])
    local opts = H.set_match_settings(ctx, { extra_time = 0, penalties = 0 })
    if fx.needs_winner or fx.decider then
      eq(opts.extra_time, 1, fx.label)
      local home_wins = T[fx.home].name == "Arsenal"
      play_match({ { 2, 90, 1, 1 }, { 4, 120, 1, 1 },
                   { 5, 120, 1, 1, home_wins and 4 or 2, home_wins and 2 or 4 } })   -- Arsenal win on pens
    else
      local arsenal_home = T[fx.home].name == "Arsenal"
      play_match({ { 2, 92, arsenal_home and 2 or 0, arsenal_home and 0 or 1 } })
    end
  end
  eq(S.state.comp.teams[S.state.champion].name, "Arsenal")
  S.page = 1
  local o = overlay()
  assert(o:find("Champion: Arsenal"), o)
  assert(read(TE .. "ucl-league-phase.html"):find("Champion: <b>Arsenal", 1, true))
end)

test("e2e: [5] twice starts a new edition with a fresh draw, keeping team ids", function()
  local old_first = S.state.fixtures[1].key
  local ids_before = 0
  for _ in pairs(S.ids) do ids_before = ids_before + 1 end
  key(0x35); key(0x35)
  eq(S.state.edition, 2)
  assert(S.state.fixtures[1].key ~= old_first, "new draw")
  local ids_after = 0
  for _ in pairs(S.ids) do ids_after = ids_after + 1 end
  eq(ids_after, ids_before)
  assert(overlay():find("New edition 2"), overlay())
end)

test("e2e: Team.bin names resolve ids automatically after one calibration", function()
  -- switch to a small league whose names exist in our fake Team.bin
  local f = io.open(TE .. "mini.txt", "w")
  f:write("name = Mini\nformat = league\nlegs = 1\ncontrolled = Arsenal\n")
  for _, t in ipairs(TEAMS) do f:write("team = " .. t.name .. " | X | 1 | 80\n") end
  f:close()
  f = io.open(TE .. "TournamentEngine.ini", "w"); f:write("competition = mini.txt\n"); f:close()
  key(0x35); key(0x35)
  eq(S.state.comp.name, "Mini")
  local bin = make_team_bin(TEAMS)
  H.livecpk_data_ready(ctx, "common\\etc\\pesdb\\Team.bin", bin:sub(1, 3000), 3000, #bin, 0)
  H.livecpk_data_ready(ctx, "common\\etc\\pesdb\\Team.bin", bin:sub(3001), #bin - 3000, #bin, 3000)
  assert(S.teambin and S.teambin.count == 5, "indexed")
  H.set_teams(ctx, 2002, 77)                            -- any real pair calibrates
  eq(S.teambin_offset, 8)
  local fx = m.open_fixtures(S.state)[1]
  local T = S.state.comp.teams
  local ids = { Arsenal = 101, ["Bayern München"] = 3001, PSV = 4417, ["Real Madrid"] = 2002, Napoli = 77 }
  H.set_teams(ctx, ids[T[fx.home].name], ids[T[fx.away].name])
  assert(S.active and S.active.fx == fx, "recognised by name via Team.bin")
  S.page = 1
  assert(overlay():find("%(" .. T[fx.home].name), overlay())
end)

test("e2e: broken competition file is explained on the overlay", function()
  local f = io.open(TE .. "TournamentEngine.ini", "w"); f:write("competition = missing.txt\n"); f:close()
  key(0x35); key(0x35)
  assert(overlay():find("competition file not found: missing.txt"), overlay())
end)

test("e2e: missing match-stats library is reported", function()
  local f = io.open(TE .. "TournamentEngine.ini", "w"); f:write("competition = world-cup-2026.txt\n"); f:close()
  key(0x35); key(0x35)
  local saved = match
  match = nil
  frames(15)
  assert(overlay():find("match%-stats%.enabled = 1"), overlay())
  match = saved
  S.page = 1
  key(0x31)
  assert(overlay():find("Group A"), overlay())
end)

test("module runs inside sider's restricted environment", function()
  local env = {}
  for _, k in ipairs({ "assert", "ipairs", "pairs", "tostring", "tonumber", "table", "string",
                       "math", "unpack", "type", "error", "io", "os", "_VERSION" }) do env[k] = _G[k] end
  env._G = env
  env.log, env.match, env.memory, env.zlib = log, match, memory, zlib
  local chunk = assert(loadfile(root .. "/modules/TournamentEngine.lua"))
  setfenv(chunk, env)
  local mod = chunk()
  local h = {}
  mod.init({ sider_dir = sider_dir, register = function(e, f) h[e] = f end })
  for _ = 1, 30 do h.display_frame({}) end
  assert(h.overlay_on({}):find("World Cup 2026"))
end)

os.execute("rm -rf '" .. sider_dir .. "'")
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
