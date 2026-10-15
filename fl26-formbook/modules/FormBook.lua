--[[
  FormBook  -  a sider module for Football Life 26
  -----------------------------------------------------------------
  Football Life 26 (PES 2021 engine + sider 7) forgets every result the
  moment a match ends: there is no head-to-head record, no form guide
  outside Master League, and no history across exhibition matches,
  cups and leagues. FormBook fixes that.

  1. Results ledger - every completed match is recorded automatically
     (score, extra time, penalties, competition, difficulty) to
     sider\modules\FormBook\results.csv, which opens in Excel/Sheets.
  2. Pre-match briefing - the sider overlay shows the all-time
     head-to-head between the two teams you are about to play, the
     last meeting, and each side's last-5 form, in every game mode.
  3. Adaptive difficulty (opt-in) - FormBook watches your team's results
     at the current difficulty and moves the AI level up when you are
     cruising and down when you are struggling.

  Requirements in sider.ini:
      match-stats.enabled = 1
      lua.module = "FormBook.lua"

  Overlay keys: [1] next page  [2] adaptive difficulty on/off
                [3] undo last recorded result (press twice)
--]]

local m = { version = "1.0.0" }

local DIFFICULTY_NAME = {
  [0] = "Beginner", [1] = "Amateur", [2] = "Regular", [3] = "Professional",
  [4] = "Top Player", [5] = "Super Star", [6] = "Legend",
}
local EXHIBITION = 65535
local VK_1, VK_2, VK_3 = 0x31, 0x32, 0x33
local POLL_EVERY = 15        -- frames between match.stats() polls (~4 per second)
local CSV_HEADER = "date,tournament_id,match_info,home_id,away_id," ..
                   "home_goals,away_goals,home_pens,away_pens,decided,difficulty"

m.DEFAULT_CONFIG = {
  record_exhibition = true,
  form_length = 5,
  adaptive = false,
  my_team = "auto",          -- "auto" or a team id
  window = 5,                -- results at one level considered for a change
  min_matches = 3,           -- results needed at a level before it can change
  promote_ppg = 2.4,         -- points per game needed to step up
  demote_ppg = 0.8,          -- points per game at or below which to step down
  min_difficulty = 2,
  max_difficulty = 6,
  team_names = {},
  tournament_names = { [EXHIBITION] = "Friendly" },
}

---------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function to_bool(v)
  v = tostring(v):lower()
  return v == "1" or v == "true" or v == "yes" or v == "on"
end

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = type(v) == "table" and copy(v) or v end
  return c
end

function m.parse_config(text)
  local cfg = copy(m.DEFAULT_CONFIG)
  local warnings = {}
  local numeric = {
    form_length = { 1, 10 }, window = { 1, 20 }, min_matches = { 1, 20 },
    promote_ppg = { 0, 3 }, demote_ppg = { 0, 3 },
    min_difficulty = { 0, 6 }, max_difficulty = { 0, 6 },
  }
  local n = 0
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    n = n + 1
    line = trim((line:gsub("^%s*[;#].*$", "")))
    if line ~= "" then
      local key, value = line:match("^([%w_%.]+)%s*=%s*(.-)$")
      if not key then
        warnings[#warnings + 1] = string.format("line %d: cannot parse '%s'", n, line)
      else
        key = key:lower()
        value = trim((value:gsub("%s+[;#].*$", ""):gsub('^"(.*)"$', "%1")))
        local team_id = key:match("^team%.(%d+)$")
        local tour_id = key:match("^tournament%.(%d+)$")
        if team_id then
          cfg.team_names[tonumber(team_id)] = value
        elseif tour_id then
          cfg.tournament_names[tonumber(tour_id)] = value
        elseif key == "record_exhibition" or key == "adaptive" then
          cfg[key] = to_bool(value)
        elseif key == "my_team" then
          if value:lower() == "auto" then cfg.my_team = "auto"
          elseif tonumber(value) then cfg.my_team = tonumber(value)
          else warnings[#warnings + 1] = string.format("line %d: my_team must be auto or a team id", n) end
        elseif numeric[key] then
          local v = tonumber(value)
          local r = numeric[key]
          if v and v >= r[1] and v <= r[2] then cfg[key] = v
          else warnings[#warnings + 1] = string.format("line %d: %s must be %s-%s", n, key, r[1], r[2]) end
        else
          warnings[#warnings + 1] = string.format("line %d: unknown key '%s'", n, key)
        end
      end
    end
  end
  if cfg.min_difficulty > cfg.max_difficulty then
    warnings[#warnings + 1] = "min_difficulty > max_difficulty; swapped"
    cfg.min_difficulty, cfg.max_difficulty = cfg.max_difficulty, cfg.min_difficulty
  end
  if cfg.demote_ppg >= cfg.promote_ppg then
    warnings[#warnings + 1] = "demote_ppg must be below promote_ppg; using defaults"
    cfg.promote_ppg, cfg.demote_ppg = m.DEFAULT_CONFIG.promote_ppg, m.DEFAULT_CONFIG.demote_ppg
  end
  return cfg, warnings
end

-- CSV ------------------------------------------------------------------

local FIELDS = { "date", "tournament_id", "match_info", "home_id", "away_id",
  "home_goals", "away_goals", "home_pens", "away_pens", "decided", "difficulty" }

function m.result_to_csv(r)
  local out = {}
  for i, f in ipairs(FIELDS) do
    local v = r[f]
    out[i] = v == nil and "" or tostring(v)
  end
  return table.concat(out, ",")
end

function m.csv_to_result(line)
  local cols = {}
  for c in (line .. ","):gmatch("([^,]*),") do cols[#cols + 1] = c end
  if #cols < #FIELDS - 1 then return nil end
  local r = {}
  for i, f in ipairs(FIELDS) do
    local v = cols[i]
    if v == nil or v == "" then r[f] = nil
    elseif f == "date" or f == "decided" then r[f] = v
    else r[f] = tonumber(v) end
  end
  if not (r.home_id and r.away_id and r.home_goals and r.away_goals) then return nil end
  return r
end

function m.parse_results(text)
  local list = {}
  for line in text:gmatch("[^\r\n]+") do
    if not line:match("^date,") then
      local r = m.csv_to_result(line)
      if r then list[#list + 1] = r end
    end
  end
  return list
end

-- Match outcome --------------------------------------------------------

-- Outcome of a result for team_id: "W", "D", "L" or nil if not involved.
-- Shoot-out winners get the W, but the match counts as a draw for goals.
function m.outcome(r, team_id)
  local gf, ga, pf, pa
  if r.home_id == team_id then
    gf, ga, pf, pa = r.home_goals, r.away_goals, r.home_pens, r.away_pens
  elseif r.away_id == team_id then
    gf, ga, pf, pa = r.away_goals, r.home_goals, r.away_pens, r.home_pens
  else
    return nil
  end
  if gf > ga then return "W" elseif gf < ga then return "L" end
  if r.decided == "PENS" and pf and pa and pf ~= pa then
    return pf > pa and "W" or "L"
  end
  return "D"
end

function m.head_to_head(results, a, b)
  local h = { played = 0, a_wins = 0, b_wins = 0, draws = 0, a_goals = 0, b_goals = 0, last = nil }
  for _, r in ipairs(results) do
    if (r.home_id == a and r.away_id == b) or (r.home_id == b and r.away_id == a) then
      h.played = h.played + 1
      local o = m.outcome(r, a)
      if o == "W" then h.a_wins = h.a_wins + 1
      elseif o == "L" then h.b_wins = h.b_wins + 1
      else h.draws = h.draws + 1 end
      if r.home_id == a then
        h.a_goals, h.b_goals = h.a_goals + r.home_goals, h.b_goals + r.away_goals
      else
        h.a_goals, h.b_goals = h.a_goals + r.away_goals, h.b_goals + r.home_goals
      end
      h.last = r
    end
  end
  return h
end

-- Last n outcomes for a team, oldest first, e.g. "WWDLW".
function m.form(results, team_id, n)
  local out = {}
  for i = #results, 1, -1 do
    local o = m.outcome(results[i], team_id)
    if o then
      table.insert(out, 1, o)
      if #out >= n then break end
    end
  end
  return table.concat(out)
end

-- Is the scoreboard snapshot a finished match? Returns "FT"/"AET"/"PENS" or nil.
-- sider derives period from the clock: 1/2 halves, 3/4 extra time, 5 shoot-out.
-- A match ending exactly on 90:00 or 120:00 without added time reports the
-- next period number, so the boundary minute is accepted as well.
function m.completion(s)
  if not s then return nil end
  local p, min = s.period or 0, s.clock_minutes or 0
  if p == 5 then return "PENS" end
  if p == 4 and min >= 120 then return "AET" end
  if p == 2 and min >= 90 then return "FT" end
  if p == 3 and min == 90 then return "FT" end
  return nil
end

-- Adaptive difficulty ----------------------------------------------------

-- The team present in each of the last `window` results (at least
-- min_matches of them), i.e. the team the player controls in a career.
function m.detect_my_team(results, window, min_matches)
  local n = math.min(window, #results)
  if n < min_matches then return nil end
  local first = results[#results]
  for _, cand in ipairs({ first.home_id, first.away_id }) do
    local ok = true
    for i = #results - n + 1, #results do
      local r = results[i]
      if r.home_id ~= cand and r.away_id ~= cand then ok = false; break end
    end
    if ok then return cand end
  end
  return nil
end

--[[ Decide the next difficulty for my_team.
     Looks at my_team's most recent results that were all played at the
     same difficulty (the current level). Returns new_level, info. ]]
function m.next_difficulty(results, my_team, cfg, fallback)
  local level, streak = nil, {}
  for i = #results, 1, -1 do
    local r = results[i]
    if m.outcome(r, my_team) and r.difficulty then
      if level == nil then level = r.difficulty end
      if r.difficulty ~= level or #streak >= cfg.window then break end
      table.insert(streak, 1, r)
    end
  end
  local info = { played = #streak, ppg = nil, level = level or fallback, change = 0 }
  if level == nil then return fallback, info end
  local pts = 0
  for _, r in ipairs(streak) do
    local o = m.outcome(r, my_team)
    pts = pts + (o == "W" and 3 or o == "D" and 1 or 0)
  end
  info.ppg = #streak > 0 and pts / #streak or nil
  local new = level
  if #streak >= cfg.min_matches then
    if info.ppg >= cfg.promote_ppg then new = level + 1
    elseif info.ppg <= cfg.demote_ppg then new = level - 1 end
  end
  new = math.max(cfg.min_difficulty, math.min(cfg.max_difficulty, new))
  info.change = new - level
  info.level = new
  return new, info
end

---------------------------------------------------------------------------
-- Match tracker: feeds on match.stats() snapshots
---------------------------------------------------------------------------

--[[ Tracker states:
       idle     - no match on screen
       live     - scoreboard exists, snapshot being updated
       suspended- scoreboard went away before full time; resumes if the
                  same fixture's scoreboard comes back, discarded otherwise ]]
function m.new_tracker()
  return { state = "idle", pending = nil }
end

-- Feed one poll. `fixture` = current teams etc. Returns a finished result or nil.
function m.track(t, stats, fixture)
  if stats then
    if t.state == "suspended" and t.pending
        and t.pending.home_id == fixture.home_id and t.pending.away_id == fixture.away_id
        and (stats.clock_minutes or 0) >= (t.pending.last.clock_minutes or 0) then
      t.state = "live"
    elseif t.state ~= "live" then
      t.pending = {
        home_id = fixture.home_id, away_id = fixture.away_id,
        tournament_id = fixture.tournament_id, match_info = fixture.match_info,
        difficulty = fixture.difficulty,
      }
      t.state = "live"
    end
    t.pending.last = {
      home_score = stats.home_score, away_score = stats.away_score,
      pk_home_score = stats.pk_home_score, pk_away_score = stats.pk_away_score,
      period = stats.period, clock_minutes = stats.clock_minutes,
    }
    return nil
  end
  -- scoreboard gone
  if t.state == "live" then
    local p = t.pending
    local decided = m.completion(p.last)
    if decided then
      t.state, t.pending = "idle", nil
      if not (p.home_id and p.away_id) then return nil end
      return {
        tournament_id = p.tournament_id, match_info = p.match_info,
        home_id = p.home_id, away_id = p.away_id,
        home_goals = p.last.home_score, away_goals = p.last.away_score,
        home_pens = decided == "PENS" and p.last.pk_home_score or nil,
        away_pens = decided == "PENS" and p.last.pk_away_score or nil,
        decided = decided, difficulty = p.difficulty,
      }
    end
    t.state = "suspended"
  end
  return nil
end

-- A new fixture is being set up: anything unfinished is abandoned.
function m.reset_tracker(t)
  t.state, t.pending = "idle", nil
end

---------------------------------------------------------------------------
-- sider glue
---------------------------------------------------------------------------

local cfg = copy(m.DEFAULT_CONFIG)
local results = {}
local tracker = m.new_tracker()
local data_dir, csv_path
local frame = 0
local page = 1
local undo_armed = false
local stats_available = nil   -- nil = unknown yet
local fixture = {}
local briefing_cache = { key = nil, text = nil }
local last_message
local PAGES = 3

local function say(msg)
  if log then log(msg) end
end

local function team_name(id)
  if id == nil then return "?" end
  return cfg.team_names[id] or ("Team " .. id)
end

local function tournament_name(id)
  if id == nil then return "?" end
  return cfg.tournament_names[id] or ("Competition " .. id)
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function save_all()
  local f, err = io.open(csv_path, "w")
  if not f then say("cannot write " .. csv_path .. ": " .. tostring(err)); return false end
  f:write(CSV_HEADER, "\n")
  for _, r in ipairs(results) do f:write(m.result_to_csv(r), "\n") end
  f:close()
  return true
end

local function append_result(r)
  local exists = read_file(csv_path) ~= nil
  local f, err = io.open(csv_path, "a")
  if not f then say("cannot write " .. csv_path .. ": " .. tostring(err)); return end
  if not exists then f:write(CSV_HEADER, "\n") end
  f:write(m.result_to_csv(r), "\n")
  f:close()
end

local function describe_result(r)
  local s = string.format("%s %d-%d %s", team_name(r.home_id), r.home_goals,
    r.away_goals, team_name(r.away_id))
  if r.decided == "AET" then s = s .. " (aet)"
  elseif r.decided == "PENS" then
    s = s .. string.format(" (%d-%d pens)", r.home_pens or 0, r.away_pens or 0)
  end
  return s
end

local function invalidate() briefing_cache.key = nil end

local function current_my_team()
  if cfg.my_team ~= "auto" then return cfg.my_team end
  return m.detect_my_team(results, cfg.window, cfg.min_matches)
end

local function on_result(r)
  if r.tournament_id == EXHIBITION and not cfg.record_exhibition then return end
  r.date = os.date("%Y-%m-%d")
  results[#results + 1] = r
  append_result(r)
  invalidate()
  last_message = "Recorded: " .. describe_result(r)
  say(string.format("recorded: %s [%s]", m.result_to_csv(r), describe_result(r)))
end

local function poll(ctx)
  local stats = nil
  if match and match.stats then
    stats = match.stats()
    if stats then stats_available = true end
  else
    stats_available = false
  end
  local f = {
    home_id = fixture.home_id or ctx.home_team, away_id = fixture.away_id or ctx.away_team,
    tournament_id = ctx.tournament_id, match_info = ctx.match_info,
    difficulty = fixture.difficulty or ctx.difficulty,
  }
  local r = m.track(tracker, stats, f)
  if r then on_result(r) end
end

function m.display_frame(ctx)
  frame = frame + 1
  if frame % POLL_EVERY == 0 then poll(ctx) end
end

-- Record a finished match that has not been polled since its scoreboard
-- went away, then forget anything unfinished.
local function flush_and_reset()
  local r = m.track(tracker, nil, {})
  if r then on_result(r) end
  m.reset_tracker(tracker)
end

function m.set_teams(ctx, home, away)
  flush_and_reset()
  fixture = { home_id = home, away_id = away }
  invalidate()
end

function m.context_reset(ctx)
  -- back to the main menu: an unfinished match is abandoned
  flush_and_reset()
  -- keep the ids (a reset can arrive while a match is loading) but stop
  -- showing that fixture's briefing in the menus
  fixture.stale = true
  invalidate()
end

function m.set_match_settings(ctx, options)
  fixture.difficulty = options.difficulty
  if not cfg.adaptive then return nil end
  local me = current_my_team()
  local home, away = fixture.home_id or ctx.home_team, fixture.away_id or ctx.away_team
  if not me or (me ~= home and me ~= away) then return nil end
  local level, info = m.next_difficulty(results, me, cfg, options.difficulty)
  if level == nil or level == options.difficulty then return nil end
  say(string.format("adaptive difficulty for %s: %s -> %s (%d played, %.2f ppg at current level)",
    team_name(me), DIFFICULTY_NAME[options.difficulty] or "?", DIFFICULTY_NAME[level] or "?",
    info.played, info.ppg or 0))
  last_message = string.format("Difficulty set to %s", DIFFICULTY_NAME[level] or level)
  options.difficulty = level
  fixture.difficulty = level
  return options
end

-- Overlay ----------------------------------------------------------------

local function briefing_page(home, away, tour)
  local lines = {}
  lines[#lines + 1] = string.format("%s vs %s  |  %s",
    team_name(home), team_name(away), tournament_name(tour))
  local h = m.head_to_head(results, home, away)
  if h.played == 0 then
    lines[#lines + 1] = "Head-to-head: first recorded meeting"
  else
    lines[#lines + 1] = string.format("Head-to-head (%d): %s %d  -  draws %d  -  %d %s   goals %d-%d",
      h.played, team_name(home), h.a_wins, h.draws, h.b_wins, team_name(away), h.a_goals, h.b_goals)
    lines[#lines + 1] = string.format("Last meeting %s: %s", h.last.date or "?", describe_result(h.last))
  end
  local fh = m.form(results, home, cfg.form_length)
  local fa = m.form(results, away, cfg.form_length)
  lines[#lines + 1] = string.format("Form: %s %s   |   %s %s",
    team_name(home), fh ~= "" and fh or "-", team_name(away), fa ~= "" and fa or "-")
  return table.concat(lines, "\n")
end

local function recent_page()
  local lines = { string.format("Recent results (%d recorded)", #results) }
  for i = #results, math.max(1, #results - 5), -1 do
    local r = results[i]
    lines[#lines + 1] = string.format("%s  %s  [%s]", r.date or "?", describe_result(r),
      tournament_name(r.tournament_id))
  end
  if #results == 0 then lines[#lines + 1] = "No matches recorded yet - play one to full time." end
  return table.concat(lines, "\n")
end

local function difficulty_page()
  local me = current_my_team()
  local lines = { "Adaptive difficulty: " .. (cfg.adaptive and "ON" or "OFF") }
  if not me then
    lines[#lines + 1] = string.format(
      "Your team: not detected yet (needs %d results with a common team, or set my_team in the ini)",
      cfg.min_matches)
  else
    local level, info = m.next_difficulty(results, me, cfg, nil)
    lines[#lines + 1] = string.format("Your team: %s%s   form %s", team_name(me),
      cfg.my_team == "auto" and " (auto)" or "", m.form(results, me, cfg.form_length))
    if level then
      lines[#lines + 1] = string.format("Next match: %s  (%d at current level, %.2f pts/game; up at %.1f, down at %.1f)",
        DIFFICULTY_NAME[level] or level, info.played, info.ppg or 0, cfg.promote_ppg, cfg.demote_ppg)
    end
  end
  lines[#lines + 1] = string.format("Range: %s - %s", DIFFICULTY_NAME[cfg.min_difficulty], DIFFICULTY_NAME[cfg.max_difficulty])
  return table.concat(lines, "\n")
end

function m.overlay_on(ctx)
  local home, away
  if not fixture.stale then
    home = fixture.home_id or ctx.home_team
    away = fixture.away_id or ctx.away_team
  end
  local key = table.concat({ page, tostring(home), tostring(away), tostring(ctx.tournament_id),
    #results, tostring(cfg.adaptive), tostring(undo_armed), tostring(last_message),
    tostring(stats_available) }, "|")
  if briefing_cache.key ~= key then
    local body
    if page == 1 then
      body = (home and away) and briefing_page(home, away, ctx.tournament_id) or recent_page()
    elseif page == 2 then
      body = recent_page()
    else
      body = difficulty_page()
    end
    local header = string.format("FormBook v%s  [page %d/%d]", m.version, page, PAGES)
    if stats_available == false then
      header = header .. "  !! add 'match-stats.enabled = 1' to sider.ini - results cannot be recorded"
    end
    local footer = "[1] next page   [2] adaptive difficulty " .. (cfg.adaptive and "ON" or "OFF") ..
      "   [3] " .. (undo_armed and "PRESS AGAIN to delete last result" or "undo last result")
    if last_message then footer = footer .. "\n" .. last_message end
    briefing_cache.key = key
    briefing_cache.text = header .. "\n" .. body .. "\n" .. footer
  end
  return briefing_cache.text
end

function m.key_down(ctx, vkey)
  if vkey ~= VK_3 then undo_armed = false end
  if vkey == VK_1 then
    page = page % PAGES + 1
  elseif vkey == VK_2 then
    cfg.adaptive = not cfg.adaptive
    last_message = "Adaptive difficulty " .. (cfg.adaptive and "enabled" or "disabled") .. " (this session)"
  elseif vkey == VK_3 then
    if #results == 0 then
      last_message = "Nothing to undo"
    elseif undo_armed then
      local r = table.remove(results)
      save_all()
      undo_armed = false
      last_message = "Deleted: " .. describe_result(r)
      say("undo: removed " .. m.result_to_csv(r))
    else
      undo_armed = true
    end
  end
  invalidate()
end

function m.init(ctx)
  local root = (ctx and ctx.sider_dir) or ""
  local sep = root:find("/") and "/" or "\\"
  data_dir = root .. "modules" .. sep .. "FormBook"
  csv_path = data_dir .. sep .. "results.csv"
  if fs and fs.make_dirs then fs.make_dirs(data_dir) end

  local ini = read_file(root .. "modules" .. sep .. "FormBook.ini")
  if ini then
    local warnings
    cfg, warnings = m.parse_config(ini)
    for _, w in ipairs(warnings) do say("FormBook.ini " .. w) end
  else
    cfg = copy(m.DEFAULT_CONFIG)
    say("FormBook.ini not found, using defaults")
  end

  local csv = read_file(csv_path)
  results = csv and m.parse_results(csv) or {}

  ctx.register("display_frame", m.display_frame)
  ctx.register("set_teams", m.set_teams)
  ctx.register("context_reset", m.context_reset)
  ctx.register("set_match_settings", m.set_match_settings)
  ctx.register("overlay_on", m.overlay_on)
  ctx.register("key_down", m.key_down)
  say(string.format("FormBook v%s loaded: %d results from %s (adaptive=%s)",
    m.version, #results, csv_path, tostring(cfg.adaptive)))
end

-- Test hooks
function m._state()
  return { cfg = cfg, results = results, tracker = tracker, csv_path = csv_path,
           page = page, undo_armed = undo_armed, stats_available = stats_available }
end

return m
