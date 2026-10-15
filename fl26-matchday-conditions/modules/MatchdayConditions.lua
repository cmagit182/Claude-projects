--[[
  Matchday Conditions  -  a sider module for Football Life 26
  -----------------------------------------------------------------
  Football Life 26 runs on the PES 2021 engine and ships with sider,
  which loads Lua modules from sider\modules\.

  Out of the box nearly every match is played in fine weather at the
  same time of day. This module replaces that with weather, kick-off
  time (day/night) and pitch season picked from a monthly climate
  profile, so a January away day in a cold league can be a snowy night
  match while a July friendly in a hot league is a dry evening kick-off.

  * Climate profiles: temperate, cold, mediterranean, tropical, arid
  * Calendar month: real-world date, or fixed via the ini file
  * Southern-hemisphere leagues are shifted by six months
  * Per-tournament profile overrides (tournament.<id> = cold)
  * Deterministic per fixture: the same match on the same day always
    gets the same conditions, so restarting a match does not reroll it
  * Overlay with hotkeys: [1] on/off  [2] reroll next match  [3] profile

  Install: copy MatchdayConditions.lua and MatchdayConditions.ini into
  sider\modules\ and add to sider.ini:
      lua.module = "MatchdayConditions.lua"
--]]

local m = { version = "1.0.0" }

-- sider option values (PES 2021 / sider 7)
local WEATHER = { fine = 0, rain = 1, snow = 2 }
local WEATHER_NAME = { [0] = "Fine", [1] = "Rain", [2] = "Snow" }
local TIME = { day = 0, night = 1 }
local TIME_NAME = { [0] = "Day", [1] = "Night" }
local SEASON = { summer = 0, winter = 1 }
local SEASON_NAME = { [0] = "Summer", [1] = "Winter" }

-- Virtual-key codes for the overlay hotkeys
local VK_1, VK_2, VK_3 = 0x31, 0x32, 0x33

--[[ Climate profiles, northern-hemisphere months 1..12.
     rain/snow/night are percentages; winter = months played on a
     winter pitch (dormant grass, breath vapour, darker light). ]]
m.PROFILES = {
  temperate = {
    rain  = { 35, 32, 30, 28, 25, 22, 20, 22, 26, 32, 36, 38 },
    snow  = { 10,  8,  3,  0,  0,  0,  0,  0,  0,  0,  2,  8 },
    night = { 55, 50, 45, 40, 35, 30, 30, 35, 45, 50, 55, 60 },
    winter = { [1]=true, [2]=true, [3]=true, [11]=true, [12]=true },
  },
  cold = {
    rain  = { 15, 15, 20, 30, 30, 30, 30, 32, 35, 35, 25, 18 },
    snow  = { 40, 35, 25,  8,  0,  0,  0,  0,  0,  5, 25, 40 },
    night = { 60, 55, 45, 35, 25, 20, 20, 25, 40, 50, 60, 65 },
    winter = { [1]=true, [2]=true, [3]=true, [4]=true, [10]=true, [11]=true, [12]=true },
  },
  mediterranean = {
    rain  = { 25, 22, 20, 18, 12,  5,  3,  5, 12, 20, 25, 27 },
    snow  = {  1,  1,  0,  0,  0,  0,  0,  0,  0,  0,  0,  1 },
    night = { 45, 45, 50, 55, 65, 75, 80, 75, 65, 55, 45, 45 },
    winter = { [1]=true, [2]=true, [12]=true },
  },
  tropical = {
    rain  = { 40, 40, 45, 45, 50, 55, 55, 55, 50, 45, 40, 40 },
    snow  = {  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0 },
    night = { 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60, 60 },
    winter = {},
  },
  arid = {
    rain  = {  5,  5,  4,  3,  2,  1,  1,  1,  2,  3,  4,  5 },
    snow  = {  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0 },
    night = { 55, 55, 60, 70, 80, 85, 85, 85, 80, 70, 60, 55 },
    winter = { [1]=true, [12]=true },
  },
}
m.PROFILE_ORDER = { "temperate", "cold", "mediterranean", "tropical", "arid" }

m.DEFAULT_CONFIG = {
  enabled = true,
  profile = "temperate",
  hemisphere = "north",
  month = "auto",            -- "auto" = real date, or 1..12
  fixed_per_fixture = true,
  weather_effects = 2,       -- 2 = force the weather visuals on
  allow_snow = true,
  tournaments = {},          -- [tournament_id] = { profile=, hemisphere= }
}

---------------------------------------------------------------------------
-- Helpers (pure, unit-tested)
---------------------------------------------------------------------------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function to_bool(v)
  v = tostring(v):lower()
  return v == "1" or v == "true" or v == "yes" or v == "on"
end

local function copy_config(src)
  local c = {}
  for k, v in pairs(src) do c[k] = v end
  c.tournaments = {}
  for k, v in pairs(src.tournaments or {}) do
    c.tournaments[k] = { profile = v.profile, hemisphere = v.hemisphere }
  end
  return c
end

-- Parse the flat key = value ini format. Unknown keys and bad values
-- are reported in the returned warnings list and otherwise ignored.
function m.parse_config(text)
  local cfg = copy_config(m.DEFAULT_CONFIG)
  local warnings = {}
  local n = 0
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    n = n + 1
    line = trim((line:gsub("[;#].*$", "")))
    if line ~= "" then
      local key, value = line:match("^([%w_%.]+)%s*=%s*(.-)$")
      if not key then
        warnings[#warnings + 1] = string.format("line %d: cannot parse '%s'", n, line)
      else
        key = key:lower()
        value = trim(value:gsub('^"(.*)"$', "%1"))
        local tid, tkey = key:match("^tournament%.(%d+)%.?(%a*)$")
        if tid then
          tid = tonumber(tid)
          local t = cfg.tournaments[tid] or {}
          local v = value:lower()
          if (tkey == "" or tkey == "profile") and m.PROFILES[v] then
            t.profile = v
          elseif tkey == "hemisphere" and (v == "north" or v == "south") then
            t.hemisphere = v
          else
            warnings[#warnings + 1] = string.format("line %d: bad value for %s", n, key)
          end
          cfg.tournaments[tid] = t
        elseif key == "enabled" or key == "fixed_per_fixture" or key == "allow_snow" then
          cfg[key] = to_bool(value)
        elseif key == "profile" then
          if m.PROFILES[value:lower()] then cfg.profile = value:lower()
          else warnings[#warnings + 1] = string.format("line %d: unknown profile '%s'", n, value) end
        elseif key == "hemisphere" then
          local v = value:lower()
          if v == "north" or v == "south" then cfg.hemisphere = v
          else warnings[#warnings + 1] = string.format("line %d: hemisphere must be north/south", n) end
        elseif key == "month" then
          local mo = tonumber(value)
          if value:lower() == "auto" then cfg.month = "auto"
          elseif mo and mo >= 1 and mo <= 12 and mo % 1 == 0 then cfg.month = mo
          else warnings[#warnings + 1] = string.format("line %d: month must be auto or 1-12", n) end
        elseif key == "weather_effects" then
          local we = tonumber(value)
          if we and we >= 0 and we <= 2 then cfg.weather_effects = we
          else warnings[#warnings + 1] = string.format("line %d: weather_effects must be 0-2", n) end
        else
          warnings[#warnings + 1] = string.format("line %d: unknown key '%s'", n, key)
        end
      end
    end
  end
  return cfg, warnings
end

-- Northern-hemisphere month equivalent for a given real month.
function m.climate_month(month, hemisphere)
  if hemisphere == "south" then return (month + 5) % 12 + 1 end
  return month
end

-- Stable 31-bit string hash (exact in double arithmetic).
function m.hash(s)
  local h = 7
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
  if h == 0 then h = 1 end
  return h
end

-- Park-Miller minimal-standard PRNG; returns a function yielding [0,100).
function m.rng(seed)
  local state = seed % 2147483647
  if state <= 0 then state = state + 2147483646 end
  return function()
    state = (state * 16807) % 2147483647
    return (state - 1) / 2147483646 * 100
  end
end

-- Resolve profile + hemisphere for a tournament.
function m.resolve_profile(cfg, tournament_id)
  local t = tournament_id and cfg.tournaments[tournament_id] or {}
  return t.profile or cfg.profile, t.hemisphere or cfg.hemisphere
end

--[[ Core decision. `fixture` = { home=, away=, tournament=, year=,
     month=, day=, reroll= }. Returns a table with weather, timeofday,
     season, profile and climate month. ]]
function m.pick_conditions(cfg, fixture)
  local profile_name, hemisphere = m.resolve_profile(cfg, fixture.tournament)
  local p = m.PROFILES[profile_name] or m.PROFILES.temperate
  local cm = m.climate_month(fixture.month, hemisphere)

  local seed_str
  if cfg.fixed_per_fixture then
    seed_str = string.format("%s|%s|%s|%d-%d-%d|%d",
      tostring(fixture.home), tostring(fixture.away), tostring(fixture.tournament),
      fixture.year or 0, fixture.month, fixture.day or 0, fixture.reroll or 0)
  else
    seed_str = string.format("%d|%d", fixture.entropy or os.time(), fixture.reroll or 0)
  end
  local roll = m.rng(m.hash(seed_str))

  local winter = p.winter[cm] == true
  local snow_pct = (cfg.allow_snow and winter) and p.snow[cm] or 0
  local w = roll()
  local weather
  if w < snow_pct then
    weather = WEATHER.snow
  elseif w < snow_pct + p.rain[cm] then
    weather = WEATHER.rain
  else
    weather = WEATHER.fine
  end

  local timeofday = (roll() < p.night[cm]) and TIME.night or TIME.day
  local season = winter and SEASON.winter or SEASON.summer
  if weather == WEATHER.snow then season = SEASON.winter end

  return {
    weather = weather,
    timeofday = timeofday,
    season = season,
    profile = profile_name,
    hemisphere = hemisphere,
    climate_month = cm,
  }
end

function m.describe(c)
  return string.format("%s, %s match, %s pitch (%s)",
    WEATHER_NAME[c.weather], TIME_NAME[c.timeofday], SEASON_NAME[c.season], c.profile)
end

---------------------------------------------------------------------------
-- sider glue
---------------------------------------------------------------------------

local cfg = copy_config(m.DEFAULT_CONFIG)
local last_pick, last_status
local reroll = 0

local function say(msg)
  if log then log("MatchdayConditions: " .. msg) end
end

local function load_config(ctx)
  local dir = (ctx and ctx.sider_dir) or ""
  local path = dir .. "modules\\MatchdayConditions.ini"
  local f = io.open(path, "r") or io.open(dir .. "modules/MatchdayConditions.ini", "r")
  if not f then
    say("no ini found, using defaults")
    return
  end
  local text = f:read("*a")
  f:close()
  local warnings
  cfg, warnings = m.parse_config(text)
  for _, w in ipairs(warnings) do say("ini " .. w) end
end

local function current_month()
  if cfg.month ~= "auto" then return cfg.month end
  return tonumber(os.date("%m"))
end

function m.set_conditions(ctx, options)
  if not cfg.enabled then
    last_status = "disabled - game defaults used"
    return nil
  end
  local fixture = {
    home = ctx.home_team, away = ctx.away_team, tournament = ctx.tournament_id,
    year = tonumber(os.date("%Y")), month = current_month(), day = tonumber(os.date("%d")),
    reroll = reroll,
  }
  local c = m.pick_conditions(cfg, fixture)
  last_pick = c
  last_status = m.describe(c)
  say(string.format("home=%s away=%s tournament=%s month=%d -> %s",
    tostring(fixture.home), tostring(fixture.away), tostring(fixture.tournament),
    fixture.month, last_status))

  options.weather = c.weather
  options.timeofday = c.timeofday
  options.season = c.season
  options.weather_effects = cfg.weather_effects
  return options
end

function m.overlay_on(ctx)
  local profile = m.resolve_profile(cfg, ctx.tournament_id)
  return string.format(
    "Matchday Conditions v%s | %s | profile: %s%s\n" ..
    "Last match: %s\n" ..
    "[1] on/off   [2] reroll next match   [3] next profile",
    m.version, cfg.enabled and "ON" or "OFF", profile,
    cfg.month == "auto" and "" or (" | month " .. cfg.month),
    last_status or "none yet")
end

function m.key_down(ctx, vkey)
  if vkey == VK_1 then
    cfg.enabled = not cfg.enabled
    say("enabled = " .. tostring(cfg.enabled))
  elseif vkey == VK_2 then
    reroll = reroll + 1
    say("reroll counter = " .. reroll)
  elseif vkey == VK_3 then
    local idx = 1
    for i, name in ipairs(m.PROFILE_ORDER) do
      if name == cfg.profile then idx = i end
    end
    cfg.profile = m.PROFILE_ORDER[idx % #m.PROFILE_ORDER + 1]
    say("default profile = " .. cfg.profile)
  end
end

function m.init(ctx)
  load_config(ctx)
  ctx.register("set_conditions", m.set_conditions)
  ctx.register("overlay_on", m.overlay_on)
  ctx.register("key_down", m.key_down)
  say(string.format("v%s loaded (profile=%s, month=%s, enabled=%s)",
    m.version, cfg.profile, tostring(cfg.month), tostring(cfg.enabled)))
end

-- Test hooks
function m._get_config() return cfg end
function m._get_last_pick() return last_pick end

return m
