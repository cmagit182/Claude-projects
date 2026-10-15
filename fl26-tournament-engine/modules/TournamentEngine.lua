--[[
  Tournament Engine  -  a sider module for Football Life 26
  =================================================================
  Play modern competition formats that the PES 2021 engine cannot run:

    * swiss   - Champions League 2024+ "league phase": 36 teams, 4 pots,
                8 different opponents each (2 per pot, 1 home + 1 away),
                one table, knockout play-offs for 9th-24th, then R16.
    * groups  - group stage + knockout, including the 48-team World Cup
                2026 (12 groups, top 2 + 8 best third-placed -> R32),
                Euro-style (6 groups + 4 best thirds) or classic 8x4.
    * league  - any round-robin league (single or double).

  The engine makes the draw (with country / confederation limits),
  schedules every matchday, simulates the matches that don't involve
  your team(s), and keeps the tables and knockout bracket.

  You play your fixtures as exhibition matches. When you pick the two
  teams, the module recognises the fixture, applies the right rules
  (no extra time in league/first legs; extra time + penalties in
  knockouts and deciders), reads the final score from the scoreboard
  when the match ends, and advances the competition. An HTML report
  of every table, fixture and bracket is written after each update.

  Requirements (sider.ini):
      match-stats.enabled = 1
      lua.module = "TournamentEngine.lua"

  Files (in sider\modules\TournamentEngine\):
      TournamentEngine.ini    which competition is active
      <competition>.txt       format, teams, pots, ratings
      <competition>.save      your progress (created automatically)
      <competition>.html      report (created automatically)

  The core (draw, schedule, simulation, standings, knockouts) is pure
  Lua with no sider dependencies, so it is unit-tested and can be run
  from the command line with tools/preview.lua.
--]]

local m = { version = "1.0.0" }

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = trim(part) end
  return out
end

-- Stable 31-bit string hash (exact in double arithmetic)
function m.hash(s)
  local h = 7
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
  if h == 0 then h = 1 end
  return h
end

-- Park-Miller PRNG. rng:next() in [0,1), rng:int(n) in 1..n
function m.rng(seed)
  if type(seed) == "string" then seed = m.hash(seed) end
  local state = seed % 2147483647
  if state <= 0 then state = state + 2147483646 end
  local r = {}
  function r.next()
    state = (state * 16807) % 2147483647
    return (state - 1) / 2147483646
  end
  function r.int(n) return math.floor(r.next() * n) + 1 end
  function r.shuffle(t)
    for i = #t, 2, -1 do
      local j = r.int(i)
      t[i], t[j] = t[j], t[i]
    end
    return t
  end
  return r
end

-- Lower-case ASCII key for matching team names ("Bayern München" -> "bayernmunchen")
local FOLD = {
  ["à"]="a",["á"]="a",["â"]="a",["ã"]="a",["ä"]="a",["å"]="a",["æ"]="ae",["ç"]="c",
  ["è"]="e",["é"]="e",["ê"]="e",["ë"]="e",["ì"]="i",["í"]="i",["î"]="i",["ï"]="i",
  ["ñ"]="n",["ò"]="o",["ó"]="o",["ô"]="o",["õ"]="o",["ö"]="o",["ø"]="o",["ù"]="u",
  ["ú"]="u",["û"]="u",["ü"]="u",["ý"]="y",["ÿ"]="y",["ß"]="ss",["ş"]="s",["ğ"]="g",
  ["ı"]="i",["ł"]="l",["ś"]="s",["ź"]="z",["ż"]="z",["č"]="c",["ć"]="c",["ř"]="r",
  ["š"]="s",["ž"]="z",["đ"]="d",["ő"]="o",["ű"]="u",["ă"]="a",["ș"]="s",["ț"]="t",
  ["À"]="a",["Á"]="a",["Ä"]="a",["Å"]="a",["Ç"]="c",["É"]="e",["Ö"]="o",["Ø"]="o",
  ["Ü"]="u",["Š"]="s",["Ž"]="z",["Č"]="c",["Ł"]="l",["Ś"]="s",
}
function m.name_key(s)
  s = s:gsub("[\192-\223][\128-\191]", function(ch) return FOLD[ch] or "" end)
  s = s:gsub("[\224-\255][\128-\191]+", "")
  return (s:lower():gsub("[^%w]", ""))
end

-- Standard bracket order: seed_order(8) = {1,8,4,5,2,7,3,6}
function m.seed_order(n)
  local order = { 1 }
  while #order < n do
    local size = #order * 2
    local nxt = {}
    for _, s in ipairs(order) do
      nxt[#nxt + 1] = s
      nxt[#nxt + 1] = size + 1 - s
    end
    order = nxt
  end
  return order
end

local function is_pow2(n)
  if n < 2 then return false end
  while n % 2 == 0 do n = n / 2 end
  return n == 1
end

---------------------------------------------------------------------------
-- Competition file
---------------------------------------------------------------------------

m.FORMAT_DEFAULTS = {
  name = "Tournament", format = "league", seed = "1",
  legs = 2,                -- league: 1 or 2 round robins
  group_legs = 1,          -- groups: 1 or 2 round robins
  knockout_legs = 1,       -- 1 or 2 (final is always one match)
  advance_per_group = 2, best_thirds = 0,
  direct = 8, playoff = 16,
  matches_per_team = 8,    -- swiss (fixed: 2 per pot with 4 pots)
  max_same_country = 2,    -- swiss
  same_country = false,    -- swiss: allow same-country opponents
  confed_limits = {},      -- groups: per-confederation max per group (default 1)
  confed_default_limit = 1,
  home_advantage = 0.25,
  final_stadium = nil,
  decider_minutes = nil,
}

--[[ Parses a competition description. Team lines:
       team = Name | COUNTRY | pot | rating [| id=123] [| group=A]
     Returns comp, errors (fatal) and warnings. ]]
function m.parse_competition(text)
  local comp = {}
  for k, v in pairs(m.FORMAT_DEFAULTS) do comp[k] = v end
  comp.confed_limits = {}
  comp.teams = {}
  comp.controlled_names = {}
  local errors, warnings = {}, {}
  local n = 0
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    n = n + 1
    line = trim((line:gsub("^%s*[;#].*$", ""):gsub("%s+;.*$", "")))
    if line ~= "" then
      local key, value = line:match("^([%w_]+)%s*=%s*(.-)$")
      if not key then
        warnings[#warnings + 1] = string.format("line %d: cannot parse '%s'", n, line)
      else
        key = key:lower()
        if key == "team" then
          local p = split(value, "|")
          local t = { name = p[1], country = (p[2] or ""):upper(), pot = tonumber(p[3]),
                      rating = tonumber(p[4]) }
          for i = 5, #p do
            local k2, v2 = p[i]:match("^(%a+)%s*=%s*(.+)$")
            if k2 == "id" then t.id = tonumber(v2)
            elseif k2 == "group" then t.group = v2:upper() end
          end
          if not t.name or t.name == "" or not t.rating then
            errors[#errors + 1] = string.format("line %d: team needs 'Name | COUNTRY | pot | rating'", n)
          else
            if not t.pot then t.pot = 1 end
            t.key = m.name_key(t.name)
            comp.teams[#comp.teams + 1] = t
          end
        elseif key == "controlled" then
          if value:lower() == "all" then comp.controlled_all = true
          else
            for _, nm in ipairs(split(value, ",")) do
              if nm ~= "" then comp.controlled_names[#comp.controlled_names + 1] = nm end
            end
          end
        elseif key == "confed_limit" then
          for _, item in ipairs(split(value, ",")) do
            local c, lim = item:match("^(%w+)%s*:%s*(%d+)$")
            if c then comp.confed_limits[c:upper()] = tonumber(lim)
            else warnings[#warnings + 1] = string.format("line %d: confed_limit wants e.g. UEFA:2", n) end
          end
        elseif key == "same_country" then
          comp.same_country = (value:lower() == "true" or value == "1" or value:lower() == "yes")
        elseif key == "name" or key == "seed" or key == "format" then
          comp[key] = key == "format" and value:lower() or value
        elseif m.FORMAT_DEFAULTS[key] ~= nil or key == "final_stadium" or key == "decider_minutes" then
          local num = tonumber(value)
          if num then comp[key] = num
          else warnings[#warnings + 1] = string.format("line %d: %s must be a number", n, key) end
        else
          warnings[#warnings + 1] = string.format("line %d: unknown key '%s'", n, key)
        end
      end
    end
  end

  -- validation -------------------------------------------------------------
  local nt = #comp.teams
  local seen = {}
  for _, t in ipairs(comp.teams) do
    if seen[t.key] then errors[#errors + 1] = "duplicate team: " .. t.name end
    seen[t.key] = true
  end
  if comp.format == "swiss" then
    local pots = {}
    for _, t in ipairs(comp.teams) do pots[t.pot] = (pots[t.pot] or 0) + 1 end
    local size = pots[1]
    for p = 1, 4 do
      if pots[p] ~= size then errors[#errors + 1] = "swiss needs 4 pots of equal size (pot " .. p .. ")" end
    end
    if size and size < 3 then errors[#errors + 1] = "swiss needs at least 3 teams per pot" end
    if nt ~= 4 * (size or 0) then errors[#errors + 1] = "swiss: every team must be in pot 1-4" end
    if comp.playoff > 0 and comp.playoff / 2 ~= comp.direct then
      errors[#errors + 1] = "swiss: playoff must be 2 x direct (e.g. direct=8, playoff=16)"
    end
    if comp.direct + comp.playoff > nt then errors[#errors + 1] = "swiss: direct + playoff > teams" end
    local ko = comp.playoff > 0 and comp.direct * 2 or comp.direct
    if not is_pow2(ko) then errors[#errors + 1] = "swiss: knockout size must be a power of 2" end
  elseif comp.format == "groups" then
    local pots = {}
    local npots = 0
    for _, t in ipairs(comp.teams) do
      pots[t.pot] = (pots[t.pot] or 0) + 1
      if t.pot > npots then npots = t.pot end
    end
    local g = pots[1] or 0
    for p = 1, npots do
      if pots[p] ~= g then errors[#errors + 1] = "groups: every pot needs the same number of teams (one per group)" end
    end
    comp.groups = g
    comp.group_size = npots
    local q = g * comp.advance_per_group + comp.best_thirds
    if comp.best_thirds > g then errors[#errors + 1] = "groups: best_thirds > number of groups" end
    if not is_pow2(q) then errors[#errors + 1] = "groups: qualifiers (" .. q .. ") must be a power of 2" end
    for _, t in ipairs(comp.teams) do
      if t.group then
        local gi = t.group:byte() - 64
        if gi < 1 or gi > g then errors[#errors + 1] = "bad group for " .. t.name
        else t.fixed_group = gi end
      end
    end
  elseif comp.format == "league" then
    if nt < 2 then errors[#errors + 1] = "league needs at least 2 teams" end
  else
    errors[#errors + 1] = "format must be swiss, groups or league"
  end

  -- controlled teams -> indices
  comp.index_by_key = {}
  for i, t in ipairs(comp.teams) do t.idx = i; comp.index_by_key[t.key] = i end
  comp.controlled = {}
  for _, nm in ipairs(comp.controlled_names) do
    local i = comp.index_by_key[m.name_key(nm)]
    if i then comp.controlled[i] = true
    else warnings[#warnings + 1] = "controlled team not in the competition: " .. nm end
  end
  if comp.controlled_all then for i = 1, nt do comp.controlled[i] = true end end
  return comp, errors, warnings
end

---------------------------------------------------------------------------
-- Draws
---------------------------------------------------------------------------

--[[ Swiss league-phase draw. Each team gets one home and one away
     opponent from every pot (including its own), never the same club
     twice, never a club from its own country (unless same_country),
     and at most max_same_country opponents from any one country.
     Returns a list of {home, away} (team indices) or nil, reason. ]]
function m.swiss_draw(comp, rng)
  local pots = { {}, {}, {}, {} }
  for i, t in ipairs(comp.teams) do table.insert(pots[t.pot], i) end
  local teams = comp.teams

  for attempt = 1, 400 do
    local opp = {}       -- opp[i][j] = true if already drawn together
    local ccount = {}    -- ccount[i][country] = opponents from that country
    for i = 1, #teams do opp[i] = {}; ccount[i] = {} end
    local matches = {}

    local function ok(a, b)
      if a == b or opp[a][b] then return false end
      local ca, cb = teams[a].country, teams[b].country
      if not comp.same_country and ca ~= "" and ca == cb then return false end
      if cb ~= "" and (ccount[a][cb] or 0) >= comp.max_same_country then return false end
      if ca ~= "" and (ccount[b][ca] or 0) >= comp.max_same_country then return false end
      return true
    end
    local function link(a, b, on)
      local d = on and 1 or -1
      opp[a][b], opp[b][a] = on or nil, on or nil
      local ca, cb = teams[a].country, teams[b].country
      ccount[a][cb] = (ccount[a][cb] or 0) + d
      ccount[b][ca] = (ccount[b][ca] or 0) + d
    end

    -- one bijection: every team in pot p hosts exactly one team of pot q
    local function bijection(p, q)
      local hosts = rng.shuffle({ unpack(pots[p]) })
      local used = {}       -- guests already hosted
      local pick = {}
      local budget = 2000
      local function dfs(k)
        if k > #hosts then return true end
        budget = budget - 1
        if budget < 0 then return false end
        local h = hosts[k]
        local cands = rng.shuffle({ unpack(pots[q]) })
        for _, g in ipairs(cands) do
          -- p == q: forbid the reverse fixture (would be the same pairing twice)
          if not used[g] and ok(h, g) then
            used[g] = true; link(h, g, true); pick[k] = g
            if dfs(k + 1) then return true end
            used[g] = nil; link(h, g, false); pick[k] = nil
          end
        end
        return false
      end
      if not dfs(1) then
        for k = 1, #hosts do if pick[k] then link(hosts[k], pick[k], false) end end
        return false
      end
      for k = 1, #hosts do matches[#matches + 1] = { home = hosts[k], away = pick[k] } end
      return true
    end

    -- most constrained first: same-pot, then cross pots
    local order = { {1,1}, {2,2}, {3,3}, {4,4} }
    for p = 1, 4 do for q = 1, 4 do if p ~= q then order[#order + 1] = { p, q } end end end
    local good = true
    for _, pq in ipairs(order) do
      if not bijection(pq[1], pq[2]) then good = false; break end
    end
    if good then return matches end
  end
  return nil, "could not complete the draw with these country restrictions"
end

--[[ Group draw: pot by pot, one team of each pot per group, respecting
     per-confederation limits (country field = confederation). Teams with
     a fixed group (hosts) are placed first. Returns groups[g] = {idx...} ]]
function m.group_draw(comp, rng)
  local G, S = comp.groups, comp.group_size
  local function limit(c) return comp.confed_limits[c] or comp.confed_default_limit end
  for attempt = 1, 400 do
    local groups, conf = {}, {}
    for g = 1, G do groups[g] = {}; conf[g] = {} end
    local failed = false
    for p = 1, S do
      local fixed, free = {}, {}
      for i, t in ipairs(comp.teams) do
        if t.pot == p then
          if t.fixed_group then fixed[#fixed + 1] = i else free[#free + 1] = i end
        end
      end
      local taken = {}
      for _, i in ipairs(fixed) do
        local g, c = comp.teams[i].fixed_group, comp.teams[i].country
        table.insert(groups[g], i); taken[g] = true
        conf[g][c] = (conf[g][c] or 0) + 1
      end
      rng.shuffle(free)
      local budget = 5000
      local placed = {}
      local function dfs(k)
        if k > #free then return true end
        budget = budget - 1
        if budget < 0 then return false end
        local i = free[k]
        local c = comp.teams[i].country
        local gs = {}
        for g = 1, G do gs[g] = g end
        rng.shuffle(gs)
        for _, g in ipairs(gs) do
          if not taken[g] and (conf[g][c] or 0) < limit(c) then
            taken[g] = true; conf[g][c] = (conf[g][c] or 0) + 1; placed[k] = g
            if dfs(k + 1) then return true end
            taken[g] = nil; conf[g][c] = conf[g][c] - 1; placed[k] = nil
          end
        end
        return false
      end
      if not dfs(1) then failed = true; break end
      for k, i in ipairs(free) do table.insert(groups[placed[k]], i) end
    end
    if not failed then return groups end
  end
  return nil, "could not complete the group draw with these confederation limits"
end

---------------------------------------------------------------------------
-- Scheduling
---------------------------------------------------------------------------

-- Round robin (circle method). Returns rounds[r] = { {home, away}, ... }
function m.round_robin(list, legs)
  local t = { unpack(list) }
  if #t % 2 == 1 then t[#t + 1] = false end      -- bye
  local n = #t
  local rounds = {}
  for r = 1, n - 1 do
    local games = {}
    for i = 1, n / 2 do
      local a, b = t[i], t[n + 1 - i]
      if a and b then
        -- alternate home/away so nobody is always at home
        if (r + i) % 2 == 0 then a, b = b, a end
        games[#games + 1] = { home = a, away = b }
      end
    end
    rounds[r] = games
    -- rotate all but the first
    table.insert(t, 2, table.remove(t))
  end
  if legs == 2 then
    local first = #rounds
    for r = 1, first do
      local games = {}
      for _, g in ipairs(rounds[r]) do games[#games + 1] = { home = g.away, away = g.home } end
      rounds[first + r] = games
    end
  end
  return rounds
end

--[[ Assigns matchdays so nobody plays twice on one matchday: proper edge
     colouring with Kempe-chain repairs. Uses `rounds` colours if it can
     (8 for the swiss league phase); returns rounds[r] = {match...}. ]]
function m.schedule(matches, nteams, rounds, rng)
  for attempt = 1, 60 do
    local K = rounds
    local at = {}            -- at[v][c] = match index
    for v = 1, nteams do at[v] = {} end
    local color = {}
    local order = {}
    for i = 1, #matches do order[i] = i end
    rng.shuffle(order)
    local failed = false
    for _, e in ipairs(order) do
      local u, v = matches[e].home, matches[e].away
      local done = false
      for c = 1, K do
        if not at[u][c] and not at[v][c] then
          at[u][c], at[v][c], color[e] = e, e, c; done = true; break
        end
      end
      if not done then
        -- a free at u (busy at v), b free at v (busy at u): flip the a/b chain from v
        local fa, fb = {}, {}
        for c = 1, K do
          if not at[u][c] then fa[#fa + 1] = c end
          if not at[v][c] then fb[#fb + 1] = c end
        end
        rng.shuffle(fa); rng.shuffle(fb)
        for _, a in ipairs(fa) do
          for _, b in ipairs(fb) do
            -- walk the chain
            local path, x, cur, hits_u = {}, v, a, false
            while true do
              local me = at[x][cur]
              if not me then break end
              local y = matches[me].home == x and matches[me].away or matches[me].home
              path[#path + 1] = me
              if y == u then hits_u = true; break end
              x = y
              cur = (cur == a) and b or a
              if #path > #matches then hits_u = true; break end
            end
            if not hits_u then
              for _, pe in ipairs(path) do
                local h, w = matches[pe].home, matches[pe].away
                at[h][color[pe]], at[w][color[pe]] = nil, nil
              end
              for _, pe in ipairs(path) do
                local nc = (color[pe] == a) and b or a
                color[pe] = nc
                local h, w = matches[pe].home, matches[pe].away
                at[h][nc], at[w][nc] = pe, pe
              end
              at[u][a], at[v][a], color[e] = e, e, a
              done = true
              break
            end
          end
          if done then break end
        end
      end
      if not done then failed = true; break end
    end
    if not failed then
      local out = {}
      for c = 1, K do out[c] = {} end
      for i = 1, #matches do table.insert(out[color[i]], matches[i]) end
      return out
    end
  end
  -- fall back to a greedy schedule with extra matchdays (never seen in tests)
  local out, busy = {}, {}
  for _, mt in ipairs(matches) do
    local r = 1
    while busy[r] and (busy[r][mt.home] or busy[r][mt.away]) do r = r + 1 end
    busy[r] = busy[r] or {}
    out[r] = out[r] or {}
    busy[r][mt.home], busy[r][mt.away] = true, true
    table.insert(out[r], mt)
  end
  return out
end

---------------------------------------------------------------------------
-- Match simulation
---------------------------------------------------------------------------

local function poisson(rng, lambda)
  local l, k, p = math.exp(-lambda), 0, 1
  repeat
    k = k + 1
    p = p * rng.next()
  until p <= l
  return k - 1
end

--[[ Simulates a fixture from team ratings. Knockout fixtures that need a
     winner get extra time (a third of the scoring rate) and penalties. ]]
function m.simulate(comp, fx)
  local rng = m.rng(tostring(comp.seed) .. "|sim|" .. fx.key)
  local rh, ra = comp.teams[fx.home].rating, comp.teams[fx.away].rating
  local diff = (rh - ra) / 10
  local adv = fx.neutral and 0 or comp.home_advantage
  local lh = math.min(5, 1.3 * math.exp(diff * 0.5 + adv * 0.5))
  local la = math.min(5, 1.3 * math.exp(-diff * 0.5 - adv * 0.5))
  local r = { home_goals = poisson(rng, lh), away_goals = poisson(rng, la), sim = true }
  if fx.needs_winner then
    local th, ta = fx.agg_home or 0, fx.agg_away or 0
    if r.home_goals + th == r.away_goals + ta then
      r.home_goals = r.home_goals + poisson(rng, lh / 3)
      r.away_goals = r.away_goals + poisson(rng, la / 3)
      if r.home_goals + th == r.away_goals + ta then
        local ph, pa = 0, 0
        local p_h = 0.75 + (rh - ra) / 400
        local p_a = 0.75 - (rh - ra) / 400
        for k = 1, 5 do
          if rng.next() < p_h then ph = ph + 1 end
          if rng.next() < p_a then pa = pa + 1 end
        end
        while ph == pa do
          local sh, sa = rng.next() < p_h, rng.next() < p_a
          if sh then ph = ph + 1 end
          if sa then pa = pa + 1 end
        end
        r.home_pens, r.away_pens = ph, pa
        r.decided = "PENS"
      else
        r.decided = "AET"
      end
    end
  end
  return r
end

---------------------------------------------------------------------------
-- Standings
---------------------------------------------------------------------------

--[[ Table for a set of team indices over the given fixtures (only played
     ones count). Order: points, goal difference, goals for, wins, away
     goals, rating, then a seeded coin toss. ]]
function m.standings(state, members, filter)
  local comp = state.comp
  local rows, by = {}, {}
  for _, i in ipairs(members) do
    local row = { idx = i, p = 0, w = 0, d = 0, l = 0, gf = 0, ga = 0, agf = 0, pts = 0 }
    rows[#rows + 1] = row; by[i] = row
  end
  for _, fx in ipairs(state.fixtures) do
    local r = state.results[fx.key]
    if r and filter(fx) and by[fx.home] and by[fx.away] then
      local h, a = by[fx.home], by[fx.away]
      local hg, ag = r.home_goals, r.away_goals
      h.p, a.p = h.p + 1, a.p + 1
      h.gf, h.ga, a.gf, a.ga = h.gf + hg, h.ga + ag, a.gf + ag, a.ga + hg
      a.agf = a.agf + ag
      if hg > ag then h.w, a.l, h.pts = h.w + 1, a.l + 1, h.pts + 3
      elseif hg < ag then a.w, h.l, a.pts = a.w + 1, h.l + 1, a.pts + 3
      else h.d, a.d, h.pts, a.pts = h.d + 1, a.d + 1, h.pts + 1, a.pts + 1 end
    end
  end
  local lot = {}
  local lr = m.rng(tostring(comp.seed) .. "|lots")
  for i = 1, #comp.teams do lot[i] = lr.next() end
  table.sort(rows, function(x, y)
    if x.pts ~= y.pts then return x.pts > y.pts end
    local gx, gy = x.gf - x.ga, y.gf - y.ga
    if gx ~= gy then return gx > gy end
    if x.gf ~= y.gf then return x.gf > y.gf end
    if x.w ~= y.w then return x.w > y.w end
    if x.agf ~= y.agf then return x.agf > y.agf end
    local rx, ry = comp.teams[x.idx].rating, comp.teams[y.idx].rating
    if rx ~= ry then return rx > ry end
    return lot[x.idx] < lot[y.idx]
  end)
  for pos, row in ipairs(rows) do row.pos = pos end
  return rows
end

---------------------------------------------------------------------------
-- Competition state machine
---------------------------------------------------------------------------

local function ko_round_name(nteams)
  if nteams == 2 then return "Final" end
  if nteams == 4 then return "Semi-finals" end
  if nteams == 8 then return "Quarter-finals" end
  return "Round of " .. nteams
end

local function add_fixture(state, fx)
  fx.n = #state.fixtures + 1
  state.fixtures[fx.n] = fx
  state.by_key[fx.key] = fx
  return fx
end

function m.is_controlled(state, fx)
  return state.comp.controlled[fx.home] or state.comp.controlled[fx.away] or false
end

-- Creates the draw and the first phase's fixtures.
local function start(state)
  local comp = state.comp
  local rng = m.rng(tostring(comp.seed) .. "|draw")
  if comp.format == "swiss" then
    local matches, err = m.swiss_draw(comp, rng)
    if not matches then state.error = err; return end
    local rounds = m.schedule(matches, #comp.teams, comp.matches_per_team, rng)
    for r, games in ipairs(rounds) do
      for _, g in ipairs(games) do
        add_fixture(state, { key = string.format("LP%d:%d-%d", r, g.home, g.away), home = g.home, away = g.away,
          round = r, phase = "league", label = "League phase - Matchday " .. r })
      end
    end
    state.next_round = #rounds + 1
    state.phase = "league"
  elseif comp.format == "groups" then
    local groups, err = m.group_draw(comp, rng)
    if not groups then state.error = err; return end
    state.groups = groups
    state.group_of = {}
    local maxr = 0
    for g, members in ipairs(groups) do
      -- pot order inside the group = seeding position
      table.sort(members, function(a, b) return comp.teams[a].pot < comp.teams[b].pot end)
      for _, i in ipairs(members) do state.group_of[i] = g end
      local rounds = m.round_robin(members, comp.group_legs)
      for r, games in ipairs(rounds) do
        if r > maxr then maxr = r end
        for _, gm in ipairs(games) do
          add_fixture(state, { key = string.format("G%s%d:%d-%d", string.char(64 + g), r, gm.home, gm.away),
            home = gm.home, away = gm.away, round = r, phase = "groups", group = g,
            label = string.format("Group %s - Matchday %d", string.char(64 + g), r) })
        end
      end
    end
    state.next_round = maxr + 1
    state.phase = "groups"
  else
    local all = {}
    for i = 1, #comp.teams do all[i] = i end
    rng.shuffle(all)
    local rounds = m.round_robin(all, comp.legs)
    for r, games in ipairs(rounds) do
      for _, g in ipairs(games) do
        add_fixture(state, { key = string.format("R%d:%d-%d", r, g.home, g.away), home = g.home, away = g.away,
          round = r, phase = "league", label = "Matchday " .. r })
      end
    end
    state.next_round = #rounds + 1
    state.phase = "league"
  end
end

-- Builds the fixtures for a knockout round from a list of ties {a=, b=}
local function add_ko_round(state, name, ties)
  local comp = state.comp
  local kr = { name = name, ties = ties, index = #state.ko + 1 }
  state.ko[kr.index] = kr
  local final = name == "Final"
  local legs = final and 1 or comp.knockout_legs
  local r1 = state.next_round
  for t, tie in ipairs(ties) do
    tie.id = string.format("K%dT%d", kr.index, t)
    tie.legs = legs
    tie.fixtures = {}
    if legs == 1 then
      tie.fixtures[1] = add_fixture(state, { key = tie.id, home = tie.a, away = tie.b, round = r1,
        phase = "ko", tie = tie, needs_winner = true, neutral = final, final = final, label = name })
    else
      tie.fixtures[1] = add_fixture(state, { key = tie.id .. "L1", home = tie.b, away = tie.a, round = r1,
        phase = "ko", tie = tie, leg = 1, label = name .. " - 1st leg" })
      tie.fixtures[2] = add_fixture(state, { key = tie.id .. "L2", home = tie.a, away = tie.b, round = r1 + 1,
        phase = "ko", tie = tie, leg = 2, label = name .. " - 2nd leg" })
    end
  end
  state.next_round = r1 + legs
  state.phase = "ko"
end

-- Aggregate for a tie from team a's perspective
function m.tie_aggregate(state, tie)
  local ga, gb, pa, pb = 0, 0, nil, nil
  local complete = true
  for _, fx in ipairs(tie.fixtures) do
    local r = state.results[fx.key]
    if not r then complete = false
    else
      if fx.home == tie.a then ga, gb = ga + r.home_goals, gb + r.away_goals
      else ga, gb = ga + r.away_goals, gb + r.home_goals end
      if r.home_pens then
        if fx.home == tie.a then pa, pb = r.home_pens, r.away_pens else pa, pb = r.away_pens, r.home_pens end
      end
    end
  end
  return ga, gb, pa, pb, complete
end

-- Decides a tie if possible; adds a decider fixture when the scheduled
-- matches finished level (e.g. extra time was not played in-game).
local function resolve_tie(state, tie)
  if tie.winner then return true end
  local ga, gb, pa, pb, complete = m.tie_aggregate(state, tie)
  if not complete then return false end
  if ga ~= gb then tie.winner = ga > gb and tie.a or tie.b; return true end
  if pa and pb and pa ~= pb then tie.winner = pa > pb and tie.a or tie.b; return true end
  local nd = #tie.fixtures + 1
  local last = tie.fixtures[#tie.fixtures]
  tie.fixtures[nd] = add_fixture(state, { key = tie.id .. "D" .. nd, home = tie.a, away = tie.b,
    round = state.next_round, phase = "ko", tie = tie, needs_winner = true, decider = true,
    agg_home = 0, agg_away = 0, neutral = last.neutral, final = last.final,
    label = (last.label:gsub(" %- %d%a%a leg$", "")) .. " - decider (extra time + penalties)" })
  state.next_round = state.next_round + 1
  return false
end

local function first_ko_round(state)
  local comp = state.comp
  if comp.format == "swiss" then
    local all = {}
    for i = 1, #comp.teams do all[i] = i end
    local table_ = m.standings(state, all, function(fx) return fx.phase == "league" end)
    state.final_table = table_
    local seed = {}
    for pos, row in ipairs(table_) do seed[pos] = row.idx end
    state.seed_of = {}
    for pos, idx in ipairs(seed) do state.seed_of[idx] = pos end
    local D, P = comp.direct, comp.playoff
    if P > 0 then
      local ties = {}
      for i = 1, P / 2 do ties[i] = { a = seed[D + i], b = seed[D + P + 1 - i], top = D + i } end
      add_ko_round(state, "Knockout play-offs", ties)
      state.pending_direct = seed
    else
      local ties = {}
      for _, s in ipairs(m.seed_order(D / 2)) do
        ties[#ties + 1] = { a = seed[s], b = seed[D + 1 - s] }
      end
      add_ko_round(state, ko_round_name(D), ties)
    end
  else
    -- groups: rank qualifiers (winners, runners-up, ..., best thirds)
    local ranked_by_pos = {}
    state.group_tables = {}
    for g, members in ipairs(state.groups) do
      local t = m.standings(state, members, function(fx) return fx.phase == "groups" end)
      state.group_tables[g] = t
      for pos, row in ipairs(t) do
        ranked_by_pos[pos] = ranked_by_pos[pos] or {}
        table.insert(ranked_by_pos[pos], row)
      end
    end
    local function cmp(x, y)
      if x.pts ~= y.pts then return x.pts > y.pts end
      if x.gf - x.ga ~= y.gf - y.ga then return x.gf - x.ga > y.gf - y.ga end
      if x.gf ~= y.gf then return x.gf > y.gf end
      return comp.teams[x.idx].rating > comp.teams[y.idx].rating
    end
    local q = {}
    for pos = 1, comp.advance_per_group do
      table.sort(ranked_by_pos[pos], cmp)
      for _, row in ipairs(ranked_by_pos[pos]) do q[#q + 1] = row.idx end
    end
    state.best_thirds = {}
    if comp.best_thirds > 0 then
      local third = ranked_by_pos[comp.advance_per_group + 1]
      table.sort(third, cmp)
      for k = 1, comp.best_thirds do
        q[#q + 1] = third[k].idx
        state.best_thirds[third[k].idx] = true
      end
    end
    state.seed_of = {}
    for s, idx in ipairs(q) do state.seed_of[idx] = s end
    -- seed k vs seed Q+1-k, avoiding teams from the same group
    local Q = #q
    local bottom = {}
    for k = 1, Q / 2 do bottom[k] = q[Q + 1 - k] end
    for k = 1, Q / 2 do
      if state.group_of[q[k]] == state.group_of[bottom[k]] then
        for j = Q / 2, 1, -1 do
          if j ~= k and state.group_of[q[k]] ~= state.group_of[bottom[j]]
              and state.group_of[q[j]] ~= state.group_of[bottom[k]] then
            bottom[k], bottom[j] = bottom[j], bottom[k]
            break
          end
        end
      end
    end
    local ties = {}
    for _, k in ipairs(m.seed_order(Q / 2)) do ties[#ties + 1] = { a = q[k], b = bottom[k] } end
    add_ko_round(state, ko_round_name(Q), ties)
  end
end

local function next_ko_round(state)
  local comp = state.comp
  local last = state.ko[#state.ko]
  if last.name == "Final" then
    state.champion = last.ties[1].winner
    state.runner_up = last.ties[1].winner == last.ties[1].a and last.ties[1].b or last.ties[1].a
    state.phase = "done"
    return
  end
  local ties = {}
  if last.name == "Knockout play-offs" then
    -- seed s (1..D) meets the winner of the play-off tie whose top seed is 2D+1-s
    local D = comp.direct
    local winner_by_top = {}
    for _, t in ipairs(last.ties) do winner_by_top[t.top] = t.winner end
    for _, s in ipairs(m.seed_order(D)) do
      ties[#ties + 1] = { a = state.pending_direct[s], b = winner_by_top[2 * D + 1 - s] }
    end
    add_ko_round(state, ko_round_name(2 * D), ties)
    return
  end
  for k = 1, #last.ties, 2 do
    local w1, w2 = last.ties[k].winner, last.ties[k + 1].winner
    -- better seed (lower number) hosts the 2nd leg
    if (state.seed_of[w2] or 999) < (state.seed_of[w1] or 999) then w1, w2 = w2, w1 end
    ties[#ties + 1] = { a = w1, b = w2 }
  end
  add_ko_round(state, ko_round_name(#ties * 2), ties)
end

-- Lowest round number that still has unplayed fixtures
function m.current_round(state)
  local best
  for _, fx in ipairs(state.fixtures) do
    if not state.results[fx.key] and (not best or fx.round < best) then best = fx.round end
  end
  return best
end

--[[ Advances the competition as far as possible: once the controlled
     fixtures of the current round are played, simulates the rest of that
     round, resolves ties and creates the next phase. Stops when a
     controlled fixture is waiting. ]]
function m.progress(state)
  local guard = 0
  while state.phase ~= "done" and not state.error do
    guard = guard + 1
    if guard > 10000 then state.error = "internal: progress loop"; return end
    if #state.fixtures == 0 then start(state)
    else
      -- settle every tie whose matches are all played (may add deciders)
      if state.phase == "ko" then
        for _, tie in ipairs(state.ko[#state.ko].ties) do resolve_tie(state, tie) end
      end
      local r = m.current_round(state)
      if r then
        -- your matches in this round are played first; the rest of the
        -- round is simulated once you have played (so tables stay level)
        local waiting = false
        for _, fx in ipairs(state.fixtures) do
          if fx.round == r and not state.results[fx.key] and m.is_controlled(state, fx) then waiting = true end
        end
        if waiting then return end
        for _, fx in ipairs(state.fixtures) do
          if fx.round == r and not state.results[fx.key] then
            do
              if fx.tie and fx.leg == 2 then
                local a1 = state.results[fx.tie.fixtures[1].key]
                fx.needs_winner = true
                fx.agg_home, fx.agg_away = a1.away_goals, a1.home_goals
              end
              state.results[fx.key] = m.simulate(state.comp, fx)
              state.seq = (state.seq or 0) + 1
              state.results[fx.key].seq = state.seq
            end
          end
        end
      else
        if state.phase == "league" and state.comp.format == "league" then
          local all = {}
          for i = 1, #state.comp.teams do all[i] = i end
          state.final_table = m.standings(state, all, function(fx) return fx.phase == "league" end)
          state.champion = state.final_table[1].idx
          state.phase = "done"
        elseif state.phase == "league" or state.phase == "groups" then
          first_ko_round(state)
        elseif state.phase == "ko" then
          next_ko_round(state)
        end
      end
    end
  end
end

function m.new_state(comp)
  local state = { comp = comp, fixtures = {}, by_key = {}, results = {}, ko = {}, next_round = 1 }
  m.progress(state)
  return state
end

-- Controlled fixtures that can be played now
function m.open_fixtures(state)
  local r = m.current_round(state)
  local out = {}
  if not r then return out end
  for _, fx in ipairs(state.fixtures) do
    if fx.round == r and not state.results[fx.key] and m.is_controlled(state, fx) then out[#out + 1] = fx end
  end
  return out
end

-- Rules for a fixture played in-game
function m.match_rules(fx)
  if fx.needs_winner or fx.decider then return { extra_time = 1, penalties = 1 } end
  return { extra_time = 0, penalties = 0 }
end

-- Records a result for an open fixture, then advances. Returns ok, err.
function m.record(state, key, res)
  local fx = state.by_key[key]
  if not fx then return false, "unknown fixture " .. tostring(key) end
  if state.results[key] then return false, "already played" end
  local r = m.current_round(state)
  if fx.round ~= r then return false, "not playable yet" end
  state.results[key] = res
  state.seq = (state.seq or 0) + 1
  res.seq = state.seq
  m.progress(state)
  return true
end

-- Simulates the next open controlled fixture (when you'd rather skip it)
function m.simulate_open(state, key)
  local fx = state.by_key[key]
  if not fx or state.results[key] then return false end
  if fx.tie and fx.leg == 2 then
    local a1 = state.results[fx.tie.fixtures[1].key]
    fx.needs_winner = true
    fx.agg_home, fx.agg_away = a1.away_goals, a1.home_goals
  end
  local res = m.simulate(state.comp, fx)
  res.sim, res.skipped = nil, true      -- stored in the save like a played result
  return m.record(state, key, res)
end

---------------------------------------------------------------------------
-- Save files: only user results and team ids are stored. Everything else
-- (draw, schedule, simulated results) is rebuilt from the seed.
---------------------------------------------------------------------------

function m.result_line(key, r)
  return string.format("R %s %d %d %s %s %s", key, r.home_goals, r.away_goals,
    r.home_pens and tostring(r.home_pens) or "-", r.away_pens and tostring(r.away_pens) or "-",
    r.skipped and "skip" or "user")
end

function m.serialize(state, ids)
  local lines = { "# Tournament Engine save - " .. state.comp.name, "seed " .. tostring(state.comp.base_seed or state.comp.seed),
                  "edition " .. tostring(state.edition or 1) }
  for key, id in pairs(ids or {}) do lines[#lines + 1] = string.format("I %s %d", key, id) end
  for _, fx in ipairs(state.fixtures) do
    local r = state.results[fx.key]
    if r and not r.sim then lines[#lines + 1] = m.result_line(fx.key, r) end
  end
  return table.concat(lines, "\n") .. "\n"
end

-- Rebuilds a state from a competition and save text. Returns state, ids, warnings.
function m.restore(comp, text)
  local stored, ids, warnings = {}, {}, {}
  -- every new edition (season) gets its own draw from the same base seed
  local edition = tonumber(("\n" .. (text or "")):match("\nedition (%d+)") or "1")
  comp.base_seed = comp.base_seed or comp.seed
  comp.seed = edition > 1 and (tostring(comp.base_seed) .. "/" .. edition) or comp.base_seed
  local order = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local key, hg, ag, ph, pa, kind = line:match("^R (%S+) (%d+) (%d+) (%S+) (%S+) (%a+)$")
    if key then
      stored[key] = { home_goals = tonumber(hg), away_goals = tonumber(ag),
        home_pens = tonumber(ph), away_pens = tonumber(pa), skipped = kind == "skip" or nil }
      order[#order + 1] = key
    else
      local tkey, id = line:match("^I (%S+) (%d+)$")
      if tkey then ids[tkey] = tonumber(id) end
      local seed = line:match("^seed (.+)$")
      if seed and seed ~= tostring(comp.base_seed) then
        warnings[#warnings + 1] = "save was made with seed " .. seed .. "; competition file says " .. tostring(comp.base_seed)
      end
    end
  end
  local state = m.new_state(comp)
  state.edition = edition
  -- replay: keep applying stored results as their fixtures become playable
  local progressed = true
  local applied = 0
  while progressed do
    progressed = false
    for _, fx in ipairs(m.open_fixtures(state)) do
      local r = stored[fx.key]
      if r then
        stored[fx.key] = nil
        m.record(state, fx.key, r)
        applied = applied + 1
        progressed = true
        break
      end
    end
  end
  for _, key in ipairs(order) do
    if stored[key] then warnings[#warnings + 1] = "stored result no longer matches a fixture: " .. key end
  end
  return state, ids, warnings, applied
end

---------------------------------------------------------------------------
-- Team.bin name index (lets competition files use names instead of ids)
---------------------------------------------------------------------------

m.TEAMBIN_BLOCK = 1468      -- record size used by sider's team_bin_reader example
m.TEAMBIN_NAME_OFFS = 234
m.TEAMBIN_NAME_LEN = 70

local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

--[[ Parses Team.bin. The id field position is not documented, so every
     u32 at offsets 0..32 whose values are all distinct is kept as a
     candidate; set_teams later tells us which candidate is the id. ]]
function m.parse_team_bin(bin)
  local B = m.TEAMBIN_BLOCK
  local count = math.floor(#bin / B)
  if count < 2 then return nil end
  local names = {}
  for k = 0, count - 1 do
    local raw = bin:sub(k * B + m.TEAMBIN_NAME_OFFS + 1, k * B + m.TEAMBIN_NAME_OFFS + m.TEAMBIN_NAME_LEN)
    names[k + 1] = raw:match("^[^%z]*")
  end
  local candidates = {}
  for off = 0, 32, 4 do
    local vals, seen, okc = {}, {}, true
    for k = 0, count - 1 do
      local v = u32(bin, k * B + off + 1)
      if v == 0 or seen[v] then okc = false; break end
      seen[v] = true
      vals[k + 1] = v
    end
    if okc then candidates[#candidates + 1] = { offset = off, ids = vals, set = seen } end
  end
  return { names = names, candidates = candidates, count = count }
end

-- Picks the candidate offset that contains both observed team ids
function m.calibrate_team_bin(index, id1, id2)
  for _, c in ipairs(index.candidates) do
    if c.set[id1] and c.set[id2] then return c.offset end
  end
  return nil
end

function m.team_bin_lookup(index, offset)
  for _, c in ipairs(index.candidates) do
    if c.offset == offset then
      local by_name, dup = {}, {}
      for k, nm in ipairs(index.names) do
        local key = m.name_key(nm)
        if key ~= "" then
          if by_name[key] then dup[key] = true end
          by_name[key] = c.ids[k]
        end
      end
      for key in pairs(dup) do by_name[key] = nil end    -- ambiguous names are not used
      local by_id = {}
      for k, nm in ipairs(index.names) do by_id[c.ids[k]] = nm end
      return by_name, by_id
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Text output (overlay + CLI) and HTML report
---------------------------------------------------------------------------

function m.score_text(r)
  if not r then return "-" end
  local s = r.home_goals .. "-" .. r.away_goals
  if r.home_pens then s = s .. string.format(" (%d-%d p)", r.home_pens, r.away_pens)
  elseif r.decided == "AET" then s = s .. " aet" end
  return s
end

function m.phase_text(state)
  if state.error then return "Error: " .. state.error end
  if state.phase == "done" then return "Finished - champion: " .. state.comp.teams[state.champion].name end
  local r = m.current_round(state)
  for _, fx in ipairs(state.fixtures) do
    if fx.round == r and not state.results[fx.key] then return (fx.label:gsub("^Group %a %- ", "Group stage - ")) end
  end
  return state.phase or "?"
end

-- Pads to n characters (UTF-8 aware, so "München" lines up)
local function pad(s, n)
  s = tostring(s)
  local len = #(s:gsub("[\128-\191]", ""))
  if len > n then
    local out, count = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      count = count + 1
      if count > n then break end
      out[#out + 1] = ch
    end
    return table.concat(out)
  end
  return s .. string.rep(" ", n - len)
end

function m.table_lines(state, rows, zones)
  local comp = state.comp
  local out = { "Pos " .. pad("Team", 22) .. "  P  W  D  L   GD  Pts" }
  for _, row in ipairs(rows) do
    local mark = zones and zones(row.pos) or " "
    local name = comp.teams[row.idx].name
    if comp.controlled[row.idx] then name = "*" .. name end
    out[#out + 1] = string.format("%2d%s %s %2d %2d %2d %2d %4s %4d", row.pos, mark, pad(name, 22),
      row.p, row.w, row.d, row.l, (row.gf - row.ga > 0 and "+" or "") .. (row.gf - row.ga), row.pts)
  end
  return out
end

function m.current_tables(state)
  local comp = state.comp
  if comp.format == "groups" then
    local out = {}
    if state.groups then
      for g, members in ipairs(state.groups) do
        out[g] = { title = "Group " .. string.char(64 + g),
          rows = m.standings(state, members, function(fx) return fx.phase == "groups" end) }
      end
    end
    return out
  end
  local all = {}
  for i = 1, #comp.teams do all[i] = i end
  return { { title = comp.format == "swiss" and "League phase" or "Table",
             rows = m.standings(state, all, function(fx) return fx.phase == "league" end) } }
end

function m.zone_fn(state)
  local comp = state.comp
  if comp.format == "swiss" then
    return function(pos)
      if pos <= comp.direct then return "+" end
      if pos <= comp.direct + comp.playoff then return "~" end
      return " "
    end
  elseif comp.format == "groups" then
    return function(pos)
      if pos <= comp.advance_per_group then return "+" end
      if pos == comp.advance_per_group + 1 and comp.best_thirds > 0 then return "?" end
      return " "
    end
  end
  return function(pos) return pos == 1 and "+" or " " end
end

local function esc(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function m.report_html(state)
  local comp = state.comp
  local T = comp.teams
  local h = {}
  local function w(s) h[#h + 1] = s end
  w("<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>")
  w("<title>" .. esc(comp.name) .. "</title><style>")
  w(":root{--bg:#f7f7f5;--fg:#1b1b1b;--muted:#6b6b6b;--card:#fff;--line:#e3e3e0;--acc:#0b6bcb;--q:#e3f1e5;--p:#fdf3dc}")
  w("@media(prefers-color-scheme:dark){:root{--bg:#141414;--fg:#ececec;--muted:#9a9a9a;--card:#1d1d1d;--line:#333;--acc:#5aa9ff;--q:#1f3324;--p:#3a321c}}")
  w("body{background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif;margin:0;padding:16px;max-width:1100px;margin:auto}")
  w("h1{font-size:22px;margin:4px 0}h2{font-size:17px;margin:24px 0 8px}.muted{color:var(--muted)}")
  w(".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px}")
  w(".card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px;overflow-x:auto}.wide{grid-column:1/-1}")
  w("table{border-collapse:collapse;width:100%}td,th{padding:3px 6px;text-align:right;white-space:nowrap}")
  w("td:nth-child(2),th:nth-child(2){text-align:left}tr.q td{background:var(--q)}tr.p td{background:var(--p)}")
  w(".you{font-weight:700;color:var(--acc)}.fx{display:flex;justify-content:space-between;gap:8px;padding:2px 0;border-bottom:1px solid var(--line)}")
  w(".champ{font-size:18px;padding:12px;border-radius:8px;background:var(--q)}</style></head><body>")
  w("<h1>" .. esc(comp.name) .. "</h1><div class='muted'>" .. esc(m.phase_text(state)) ..
    " &middot; generated " .. esc(os.date("%Y-%m-%d %H:%M")) .. " by Tournament Engine " .. m.version .. "</div>")
  if state.champion then
    w("<p class='champ'>&#127942; Champion: <b>" .. esc(T[state.champion].name) .. "</b>" ..
      (state.runner_up and (" &middot; runner-up " .. esc(T[state.runner_up].name)) or "") .. "</p>")
  end
  local function tname(i)
    return comp.controlled[i] and ("<span class='you'>" .. esc(T[i].name) .. "</span>") or esc(T[i].name)
  end
  -- tables
  local zone = m.zone_fn(state)
  w("<h2>Standings</h2><div class='grid'>")
  local tables = m.current_tables(state)
  for _, tb in ipairs(tables) do
    w("<div class='card" .. (#tables == 1 and " wide" or "") .. "'><b>" .. esc(tb.title) .. "</b><table><tr><th>#</th><th>Team</th><th>P</th><th>W</th><th>D</th><th>L</th><th>GF</th><th>GA</th><th>Pts</th></tr>")
    for _, r in ipairs(tb.rows) do
      local z = zone(r.pos)
      if z == "?" and state.best_thirds then z = state.best_thirds[r.idx] and "+" or " " end
      local cls = z == "+" and " class='q'" or ((z == "~" or z == "?") and " class='p'" or "")
      w(string.format("<tr%s><td>%d</td><td>%s</td><td>%d</td><td>%d</td><td>%d</td><td>%d</td><td>%d</td><td>%d</td><td><b>%d</b></td></tr>",
        cls, r.pos, tname(r.idx), r.p, r.w, r.d, r.l, r.gf, r.ga, r.pts))
    end
    w("</table></div>")
  end
  w("</div>")
  -- knockout
  if #state.ko > 0 then
    w("<h2>Knockout</h2><div class='grid'>")
    for _, kr in ipairs(state.ko) do
      w("<div class='card'><b>" .. esc(kr.name) .. "</b>")
      for _, tie in ipairs(kr.ties) do
        local ga, gb, pa, pb, complete = m.tie_aggregate(state, tie)
        local res = complete and (ga .. "-" .. gb .. ((pa and pa ~= pb) and string.format(" (%d-%d p)", pa, pb) or "")) or "&ndash;"
        local a = tie.winner == tie.a and "<b>" .. tname(tie.a) .. "</b>" or tname(tie.a)
        local b = tie.winner == tie.b and "<b>" .. tname(tie.b) .. "</b>" or tname(tie.b)
        w("<div class='fx'><span>" .. a .. " v " .. b .. "</span><span>" .. res .. "</span></div>")
      end
      w("</div>")
    end
    w("</div>")
  end
  -- fixtures by round
  w("<h2>Fixtures &amp; results</h2><div class='grid'>")
  local by_round, rounds = {}, {}
  for _, fx in ipairs(state.fixtures) do
    if not by_round[fx.round] then by_round[fx.round] = {}; rounds[#rounds + 1] = fx.round end
    table.insert(by_round[fx.round], fx)
  end
  table.sort(rounds)
  for _, r in ipairs(rounds) do
    local first = by_round[r][1]
    local title = first.phase == "groups" and ("Group stage - Matchday " .. r) or first.label
    w("<div class='card'><b>" .. esc(title) .. "</b>")
    for _, fx in ipairs(by_round[r]) do
      local res = state.results[fx.key]
      w("<div class='fx'><span>" .. tname(fx.home) .. " v " .. tname(fx.away) .. "</span><span>" ..
        esc(m.score_text(res)) .. (res and not res.sim and not res.skipped and " &#9917;" or "") .. "</span></div>")
    end
    w("</div>")
  end
  w("</div><p class='muted'>&#9917; = played by you in-game. Highlighted teams are yours.</p></body></html>")
  return table.concat(h, "\n")
end

---------------------------------------------------------------------------
-- Match tracker (reads sider's match.stats scoreboard)
---------------------------------------------------------------------------

-- "FT"/"AET"/"PENS" if the snapshot is a finished match, else nil
function m.completion(s)
  if not s then return nil end
  local p, min = s.period or 0, s.clock_minutes or 0
  if p == 5 then return "PENS" end
  if p == 4 and min >= 120 then return "AET" end
  if p == 2 and min >= 90 then return "FT" end
  if p == 3 and min == 90 then return "FT" end
  return nil
end

function m.new_tracker() return { state = "idle" } end

function m.track(t, stats)
  if stats then
    if t.state ~= "live" then
      if t.state ~= "suspended" or (stats.clock_minutes or 0) < (t.last.clock_minutes or 0) then
        t.last = nil
      end
      t.state = "live"
    end
    t.last = { home_score = stats.home_score, away_score = stats.away_score,
      pk_home_score = stats.pk_home_score, pk_away_score = stats.pk_away_score,
      period = stats.period, clock_minutes = stats.clock_minutes }
    return nil
  end
  if t.state == "live" then
    local decided = m.completion(t.last)
    if decided then
      local l = t.last
      t.state, t.last = "idle", nil
      return { home_goals = l.home_score, away_goals = l.away_score,
        home_pens = decided == "PENS" and l.pk_home_score or nil,
        away_pens = decided == "PENS" and l.pk_away_score or nil, decided = decided }
    end
    t.state = "suspended"
  end
  return nil
end

---------------------------------------------------------------------------
-- sider glue
---------------------------------------------------------------------------

local VK = { k1 = 0x31, k2 = 0x32, k3 = 0x33, k4 = 0x34, k5 = 0x35 }
local POLL_EVERY = 15
local PAGES = 4

local S = {
  dir = nil, comp_file = nil, state = nil, ids = {}, errors = {}, page = 1, scroll = 0,
  frame = 0, tracker = m.new_tracker(), active = nil, selected = nil, armed = nil,
  message = nil, stats_ok = nil, teambin = nil, teambin_chunks = {}, teambin_offset = nil,
  by_name = nil, by_id = nil, cache_key = nil, cache_text = nil,
}

local function say(msg) if log then log(msg) end end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, text)
  local f, err = io.open(path, "w")
  if not f then say("cannot write " .. path .. ": " .. tostring(err)); return false end
  f:write(text)
  f:close()
  return true
end

local function team_id(i)
  local t = S.state.comp.teams[i]
  return t.id or S.ids[t.key] or (S.by_name and S.by_name[t.key])
end

local function team_label(i)
  local t = S.state.comp.teams[i]
  return S.state.comp.controlled[i] and ("*" .. t.name) or t.name
end

local function persist()
  if not S.state then return end
  write_file(S.dir .. S.comp_file:gsub("%.txt$", "") .. ".save", m.serialize(S.state, S.ids))
  write_file(S.dir .. S.comp_file:gsub("%.txt$", "") .. ".html", m.report_html(S.state))
  S.cache_key = nil
end

local function load_competition()
  S.errors = {}
  local cfg = read_file(S.dir .. "TournamentEngine.ini") or ""
  S.comp_file = cfg:match("\n%s*competition%s*=%s*([^\r\n;]+)") or cfg:match("^%s*competition%s*=%s*([^\r\n;]+)")
  S.comp_file = S.comp_file and trim(S.comp_file) or "ucl-league-phase.txt"
  local text = read_file(S.dir .. S.comp_file)
  if not text then
    S.errors[1] = "competition file not found: " .. S.comp_file
    S.state = nil
    return
  end
  local comp, errors, warnings = m.parse_competition(text)
  for _, w in ipairs(warnings) do say(S.comp_file .. ": " .. w) end
  if #errors > 0 then
    S.errors = errors
    for _, e in ipairs(errors) do say(S.comp_file .. ": ERROR " .. e) end
    S.state = nil
    return
  end
  local save = read_file(S.dir .. S.comp_file:gsub("%.txt$", "") .. ".save")
  local state, ids, rwarn, applied = m.restore(comp, save)
  for _, w in ipairs(rwarn) do say("save: " .. w) end
  S.state, S.ids = state, ids
  if state.error then S.errors[1] = state.error end
  say(string.format("%s loaded: %d teams, %s, %d of your results restored", comp.name, #comp.teams,
    comp.format, applied))
  persist()
end

-- Find the open fixture for the teams chosen in the menu
local function match_fixture(home, away)
  if not S.state then return nil end
  for _, fx in ipairs(m.open_fixtures(S.state)) do
    local h, a = team_id(fx.home), team_id(fx.away)
    if h == home and a == away then return fx, false end
    if h == away and a == home then return fx, true end
  end
  return nil
end

local function on_result(res)
  local act = S.active
  S.active = nil
  if not act or not S.state then return end
  if act.swapped then
    res.home_goals, res.away_goals = res.away_goals, res.home_goals
    res.home_pens, res.away_pens = res.away_pens, res.home_pens
  end
  local fx = act.fx
  local ok, err = m.record(S.state, fx.key, res)
  if ok then
    S.message = string.format("Recorded %s %s %s", team_label(fx.home), m.score_text(res), team_label(fx.away))
    say("recorded " .. fx.key .. " " .. m.score_text(res))
    persist()
  else
    S.message = "Could not record result: " .. err
    say(S.message)
  end
end

local function flush()
  local res = m.track(S.tracker, nil)
  if res then on_result(res) end
  S.tracker = m.new_tracker()
end

function m.display_frame(ctx)
  S.frame = S.frame + 1
  if S.frame % POLL_EVERY ~= 0 then return end
  local stats
  if match and match.stats then
    stats = match.stats()
    if stats then S.stats_ok = true end
  else
    S.stats_ok = false
  end
  if not S.active then
    -- only matches that were recognised as fixtures are tracked
    if not stats then S.tracker = m.new_tracker() end
    return
  end
  local res = m.track(S.tracker, stats)
  if res then on_result(res) end
end

function m.set_teams(ctx, home, away)
  flush()
  S.selected = { home = home, away = away }
  S.active = nil
  if S.teambin and not S.teambin_offset then
    S.teambin_offset = m.calibrate_team_bin(S.teambin, home, away)
    if S.teambin_offset then
      S.by_name, S.by_id = m.team_bin_lookup(S.teambin, S.teambin_offset)
      write_file(S.dir .. "teambin-offset.txt", tostring(S.teambin_offset))
      say("Team.bin id offset calibrated: " .. S.teambin_offset)
    end
  end
  local fx, swapped = match_fixture(home, away)
  if fx then
    S.active = { fx = fx, swapped = swapped }
    S.message = "Fixture recognised: " .. fx.label .. (swapped and " (home/away swapped)" or "")
    say(string.format("fixture %s recognised (teams %d v %d)", fx.key, home, away))
  end
  S.cache_key = nil
end

function m.context_reset(ctx)
  flush()
  S.active = nil
  S.selected = nil
  S.cache_key = nil
end

function m.set_match_settings(ctx, options)
  if not S.active then return nil end
  local rules = m.match_rules(S.active.fx)
  options.extra_time = rules.extra_time
  options.penalties = rules.penalties
  return options
end

function m.set_match_time(ctx, minutes)
  if S.active and S.active.fx.decider and S.state.comp.decider_minutes then
    return S.state.comp.decider_minutes
  end
  return nil
end

function m.set_stadium(ctx, options)
  if S.active and S.active.fx.final and S.state.comp.final_stadium then
    return S.state.comp.final_stadium
  end
  return nil
end

function m.data_ready(ctx, filename, data, size, total_size, offset)
  if not filename:lower():match("pesdb\\team%.bin$") or not memory then return end
  S.teambin_chunks[#S.teambin_chunks + 1] = memory.read(data, size)
  if offset + size >= total_size then
    local bin = table.concat(S.teambin_chunks)
    S.teambin_chunks = {}
    if zlib and zlib.unpack then bin = zlib.unpack(bin) or bin end
    local ok, index = pcall(m.parse_team_bin, bin)
    if ok and index then
      S.teambin = index
      local saved = tonumber(read_file(S.dir .. "teambin-offset.txt") or "")
      if saved then
        S.teambin_offset = saved
        S.by_name, S.by_id = m.team_bin_lookup(index, saved)
      end
      say(string.format("Team.bin: %d teams indexed, %d id candidates", index.count, #index.candidates))
    end
  end
end

-- Overlay ----------------------------------------------------------------

local function page_next()
  local st = S.state
  local L = {}
  local open = m.open_fixtures(st)
  if st.phase == "done" then
    L[#L + 1] = "Champion: " .. st.comp.teams[st.champion].name .. "   (runner-up: " ..
      (st.runner_up and st.comp.teams[st.runner_up].name or "-") .. ")"
    L[#L + 1] = "Press [5] twice to start a new edition with a fresh draw."
  elseif #open == 0 then
    L[#L + 1] = "No fixture for your team(s) right now."
  else
    L[#L + 1] = "Play these as exhibition matches (pick home team on the left):"
    for k, fx in ipairs(open) do
      if k > 4 then L[#L + 1] = string.format("  ... and %d more", #open - 4); break end
      local rules = m.match_rules(fx)
      local agg = ""
      if fx.leg == 2 then
        local a1 = st.results[fx.tie.fixtures[1].key]
        agg = string.format("  [1st leg %s %s %s]", st.comp.teams[fx.tie.fixtures[1].home].name,
          m.score_text(a1), st.comp.teams[fx.tie.fixtures[1].away].name)
      end
      L[#L + 1] = string.format("  %s v %s  -  %s%s%s", team_label(fx.home), team_label(fx.away), fx.label,
        rules.extra_time == 1 and "  (ET + pens)" or "", agg)
      local missing = {}
      if not team_id(fx.home) then missing[#missing + 1] = st.comp.teams[fx.home].name end
      if not team_id(fx.away) then missing[#missing + 1] = st.comp.teams[fx.away].name end
      if #missing > 0 then
        L[#L + 1] = "    team id unknown: " .. table.concat(missing, ", ") ..
          " - select the teams in exhibition, then press [4] to link"
      end
    end
  end
  if S.selected then
    local sel = string.format("Selected in menu: %d v %d", S.selected.home, S.selected.away)
    if S.by_id then
      sel = sel .. string.format("  (%s v %s)", S.by_id[S.selected.home] or "?", S.by_id[S.selected.away] or "?")
    end
    L[#L + 1] = sel .. (S.active and ("  ->  " .. S.active.fx.label .. ", result will be recorded")
      or "  ->  not a scheduled fixture")
  end
  return L
end

local function page_tables()
  local st = S.state
  local tables = m.current_tables(st)
  local L = {}
  local zone = m.zone_fn(st)
  if st.comp.format == "groups" then
    local per = 2
    local first = (S.scroll % math.ceil(#tables / per)) * per + 1
    for g = first, math.min(#tables, first + per - 1) do
      L[#L + 1] = tables[g].title
      for _, line in ipairs(m.table_lines(st, tables[g].rows, zone)) do L[#L + 1] = line end
    end
    L[#L + 1] = string.format("[2] more groups (%d-%d of %d)", first, math.min(#tables, first + per - 1), #tables)
  else
    local rows = tables[1].rows
    local per = 12
    local pages = math.ceil(#rows / per)
    local first = (S.scroll % pages) * per + 1
    local slice = {}
    for k = first, math.min(#rows, first + per - 1) do slice[#slice + 1] = rows[k] end
    L[#L + 1] = tables[1].title .. "   + qualified  ~ play-off   * your team"
    for _, line in ipairs(m.table_lines(st, slice, zone)) do L[#L + 1] = line end
    L[#L + 1] = string.format("[2] scroll (%d-%d of %d)", first, math.min(#rows, first + per - 1), #rows)
  end
  return L
end

local function page_ko()
  local st = S.state
  local L = {}
  if #st.ko == 0 then
    L[#L + 1] = "Knockout stage not reached yet."
    return L
  end
  local idx = #st.ko - (S.scroll % #st.ko)
  local kr = st.ko[idx]
  L[#L + 1] = kr.name .. string.format("   [2] earlier rounds (%d/%d)", idx, #st.ko)
  for _, tie in ipairs(kr.ties) do
    local ga, gb, pa, pb, complete = m.tie_aggregate(st, tie)
    local res = complete and (ga .. "-" .. gb .. ((pa and pa ~= pb) and string.format(" (%d-%d p)", pa, pb) or "")) or "-"
    local w = tie.winner and ("  -> " .. st.comp.teams[tie.winner].name) or ""
    L[#L + 1] = string.format("  %s v %s  %s%s", team_label(tie.a), team_label(tie.b), res, w)
  end
  return L
end

-- Results of completed rounds, newest first ([2] steps back); your matches on top
local function page_results()
  local st = S.state
  local cur = m.current_round(st) or math.huge
  local rounds, seen = {}, {}
  for _, fx in ipairs(st.fixtures) do
    if fx.round < cur and not seen[fx.round] then seen[fx.round] = true; rounds[#rounds + 1] = fx.round end
  end
  table.sort(rounds, function(a, b) return a > b end)
  if #rounds == 0 then return { "No completed matchday yet." } end
  local r = rounds[S.scroll % #rounds + 1]
  local mine, others = {}, {}
  for _, fx in ipairs(st.fixtures) do
    if fx.round == r then table.insert(m.is_controlled(st, fx) and mine or others, fx) end
  end
  local title = (mine[1] or others[1]).label
  if (mine[1] or others[1]).phase == "groups" then title = "Group stage - Matchday " .. r end
  local L = { string.format("%s results   [2] earlier (%d/%d)", title, S.scroll % #rounds + 1, #rounds) }
  local shown = 0
  for _, list in ipairs({ mine, others }) do
    for _, fx in ipairs(list) do
      if shown >= 11 then break end
      local res = st.results[fx.key]
      local tag = (not res.sim and not res.skipped) and "  (played)" or (res.skipped and "  (skipped)" or "")
      L[#L + 1] = string.format("  %s %s %s%s", team_label(fx.home), m.score_text(res), team_label(fx.away), tag)
      shown = shown + 1
    end
  end
  if #mine + #others > shown then L[#L + 1] = string.format("  ... %d more in the HTML report", #mine + #others - shown) end
  return L
end

function m.overlay_on(ctx)
  local key = table.concat({ S.page, S.scroll, tostring(S.armed), tostring(S.message), tostring(S.stats_ok),
    tostring(S.selected and S.selected.home), tostring(S.selected and S.selected.away),
    tostring(S.active ~= nil), tostring(S.state and #S.state.fixtures), tostring(S.by_id ~= nil) }, "|")
  if key == S.cache_key then return S.cache_text end
  local L = {}
  if not S.state then
    L[1] = "Tournament Engine v" .. m.version .. " - competition could not be loaded:"
    for _, e in ipairs(S.errors) do L[#L + 1] = "  " .. e end
    L[#L + 1] = "Fix the file in sider\\modules\\TournamentEngine\\ and press [5] twice to reload."
  else
    L[1] = string.format("%s  |  %s  |  page %d/%d", S.state.comp.name, m.phase_text(S.state), S.page, PAGES)
    if S.stats_ok == false then
      L[#L + 1] = "!! add 'match-stats.enabled = 1' to sider.ini - results cannot be read from the scoreboard"
    end
    local body = (S.page == 1 and page_next) or (S.page == 2 and page_tables) or (S.page == 3 and page_ko) or page_results
    for _, line in ipairs(body()) do L[#L + 1] = line end
    local armed = S.armed == "sim" and "[3] PRESS AGAIN to simulate" or "[3] simulate my next match"
    local armed5 = S.armed == "reset" and "[5] PRESS AGAIN for a new draw" or "[5] new edition"
    L[#L + 1] = "[1] page  [2] scroll  " .. armed .. "  [4] link selected teams  " .. armed5
  end
  if S.message then L[#L + 1] = S.message end
  S.cache_key, S.cache_text = key, table.concat(L, "\n")
  return S.cache_text
end

function m.key_down(ctx, vkey)
  local was = S.armed
  S.armed = nil
  if vkey == VK.k1 then
    S.page = S.page % PAGES + 1; S.scroll = 0
  elseif vkey == VK.k2 then
    S.scroll = S.scroll + 1
  elseif vkey == VK.k3 and S.state then
    local open = m.open_fixtures(S.state)
    if #open == 0 then S.message = "Nothing to simulate"
    elseif was == "sim" then
      local fx = open[1]
      m.simulate_open(S.state, fx.key)
      S.message = string.format("Simulated %s %s %s", team_label(fx.home), m.score_text(S.state.results[fx.key]),
        team_label(fx.away))
      if S.active and S.active.fx == fx then S.active = nil end
      persist()
    else
      S.armed = "sim"
    end
  elseif vkey == VK.k4 and S.state then
    local open = m.open_fixtures(S.state)
    if not S.selected then S.message = "Select both teams in an exhibition match first"
    elseif #open == 0 then S.message = "No open fixture to link"
    else
      -- link to the first open fixture with an unknown id
      for _, fx in ipairs(open) do
        if not team_id(fx.home) or not team_id(fx.away) then
          local T = S.state.comp.teams
          S.ids[T[fx.home].key] = S.selected.home
          S.ids[T[fx.away].key] = S.selected.away
          S.active = { fx = fx, swapped = false }
          S.message = string.format("Linked %s = %d, %s = %d. This match will be recorded.",
            T[fx.home].name, S.selected.home, T[fx.away].name, S.selected.away)
          persist()
          break
        end
      end
      if not S.active then S.message = "All open fixtures already have team ids" end
    end
  elseif vkey == VK.k5 then
    if was == "reset" then
      if S.state then
        local base = S.dir .. S.comp_file:gsub("%.txt$", "")
        os.rename(base .. ".save", base .. "-" .. os.date("%Y%m%d-%H%M%S") .. ".save")
        -- keep linked team ids for the new edition
        local ids = S.ids
        write_file(base .. ".save", m.serialize({ comp = S.state.comp, fixtures = {}, results = {},
          edition = (S.state.edition or 1) + 1 }, ids))
      end
      S.active, S.selected = nil, nil
      load_competition()
      S.message = S.state and string.format("New edition %d of %s - fresh draw made", S.state.edition, S.state.comp.name)
        or "Reload failed"
    else
      S.armed = "reset"
    end
  end
  S.cache_key = nil
end

function m.init(ctx)
  local root = (ctx and ctx.sider_dir) or ""
  local sep = root:find("/") and "/" or "\\"
  S.dir = root .. "modules" .. sep .. "TournamentEngine" .. sep
  load_competition()
  ctx.register("display_frame", m.display_frame)
  ctx.register("set_teams", m.set_teams)
  ctx.register("context_reset", m.context_reset)
  ctx.register("set_match_settings", m.set_match_settings)
  ctx.register("set_match_time", m.set_match_time)
  ctx.register("set_stadium", m.set_stadium)
  ctx.register("livecpk_data_ready", m.data_ready)
  ctx.register("overlay_on", m.overlay_on)
  ctx.register("key_down", m.key_down)
end

-- test hook
function m._S() return S end

return m
