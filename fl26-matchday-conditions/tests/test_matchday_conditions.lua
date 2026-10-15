-- Test suite for MatchdayConditions.lua. Runs under LuaJIT (sider's runtime)
-- or Lua 5.1 with a mocked sider context:  ./run_tests.sh
local root = arg[1] or "."
package.path = root .. "/modules/?.lua;" .. package.path

local logs = {}
log = function(msg) logs[#logs + 1] = msg end

local m = require("MatchdayConditions")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("ok   " .. name)
  else failed = failed + 1; print("FAIL " .. name .. "\n     " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function fixture(over)
  local f = { home = 101, away = 202, tournament = 17, year = 2026, month = 1, day = 10, reroll = 0 }
  for k, v in pairs(over or {}) do f[k] = v end
  return f
end

-- Monte-Carlo frequencies over many distinct fixtures
local function frequencies(cfg, month, n)
  local counts = { w = { [0] = 0, [1] = 0, [2] = 0 }, night = 0, winter = 0 }
  for i = 1, n do
    local c = m.pick_conditions(cfg, fixture({ home = i, away = i * 7 + 3, month = month, day = i % 28 + 1 }))
    counts.w[c.weather] = counts.w[c.weather] + 1
    if c.timeofday == 1 then counts.night = counts.night + 1 end
    if c.season == 1 then counts.winter = counts.winter + 1 end
  end
  return counts
end

---------------------------------------------------------------------------
test("profiles have 12 months and valid percentages", function()
  for name, p in pairs(m.PROFILES) do
    for _, key in ipairs({ "rain", "snow", "night" }) do
      eq(#p[key], 12, name .. "." .. key)
      for mo = 1, 12 do
        assert(p[key][mo] >= 0 and p[key][mo] <= 100, name .. " bad pct")
      end
    end
    for mo = 1, 12 do assert(p.rain[mo] + p.snow[mo] <= 100, name .. " rain+snow > 100") end
  end
  eq(#m.PROFILE_ORDER, 5)
end)

test("rng is deterministic and in range", function()
  local a, b = m.rng(12345), m.rng(12345)
  for _ = 1, 1000 do
    local x, y = a(), b()
    eq(x, y)
    assert(x >= 0 and x < 100, "out of range " .. x)
  end
  assert(m.rng(1)() ~= m.rng(2)(), "different seeds should differ")
end)

test("hash is stable and positive", function()
  eq(m.hash("abc"), m.hash("abc"))
  assert(m.hash("abc") ~= m.hash("abd"))
  assert(m.hash("") > 0)
end)

test("southern hemisphere shifts by six months", function()
  eq(m.climate_month(1, "south"), 7)
  eq(m.climate_month(7, "south"), 1)
  eq(m.climate_month(12, "south"), 6)
  eq(m.climate_month(6, "south"), 12)
  eq(m.climate_month(3, "north"), 3)
end)

test("same fixture gives same conditions; reroll changes the seed", function()
  local cfg = m.parse_config("")
  local a = m.pick_conditions(cfg, fixture())
  local b = m.pick_conditions(cfg, fixture())
  eq(a.weather, b.weather); eq(a.timeofday, b.timeofday); eq(a.season, b.season)
  local differs = false
  for r = 1, 50 do
    local c = m.pick_conditions(cfg, fixture({ reroll = r }))
    if c.weather ~= a.weather or c.timeofday ~= a.timeofday then differs = true end
  end
  assert(differs, "rerolling never changed anything")
end)

test("no snow in summer, frequent snow in a cold January", function()
  local cfg = m.parse_config("profile = cold")
  local jul = frequencies(cfg, 7, 2000)
  eq(jul.w[2], 0, "snow in July")
  eq(jul.winter, 0, "winter pitch in July")
  local jan = frequencies(cfg, 1, 4000)
  local pct = jan.w[2] / 4000 * 100
  assert(pct > 34 and pct < 46, "cold Jan snow ~40%, got " .. pct)
  eq(jan.winter, 4000, "January should be winter pitch")
end)

test("observed rain/night rates track the profile", function()
  local cfg = m.parse_config("profile = mediterranean")
  local n = 5000
  local jul = frequencies(cfg, 7, n)
  local rain = jul.w[1] / n * 100
  local night = jul.night / n * 100
  assert(rain < 6, "med July rain ~3%, got " .. rain)
  assert(night > 76 and night < 84, "med July night ~80%, got " .. night)
end)

test("tropical and arid never snow", function()
  for _, prof in ipairs({ "tropical", "arid" }) do
    local cfg = m.parse_config("profile = " .. prof)
    for mo = 1, 12 do eq(frequencies(cfg, mo, 300).w[2], 0, prof .. " month " .. mo) end
  end
end)

test("allow_snow = false suppresses snow", function()
  local cfg = m.parse_config("profile = cold\nallow_snow = false")
  eq(frequencies(cfg, 1, 2000).w[2], 0)
end)

test("parse_config reads all keys and tournament overrides", function()
  local cfg, warn = m.parse_config([[
; comment
enabled = no
profile = Arid
hemisphere = south
month = 11
fixed_per_fixture = false
weather_effects = 1
tournament.17 = cold
tournament.25 = tropical   # inline comment
tournament.25.hemisphere = south
]])
  eq(#warn, 0, "warnings")
  eq(cfg.enabled, false); eq(cfg.profile, "arid"); eq(cfg.hemisphere, "south")
  eq(cfg.month, 11); eq(cfg.fixed_per_fixture, false); eq(cfg.weather_effects, 1)
  eq(cfg.tournaments[17].profile, "cold")
  eq(cfg.tournaments[25].profile, "tropical")
  eq(cfg.tournaments[25].hemisphere, "south")
  -- defaults are not mutated by parsing
  eq(m.DEFAULT_CONFIG.profile, "temperate")
  eq(next(m.DEFAULT_CONFIG.tournaments), nil)
end)

test("parse_config warns on bad input and keeps defaults", function()
  local cfg, warn = m.parse_config("profile = lunar\nmonth = 13\nfoo = 1\ngarbage line\ntournament.3 = moon")
  eq(#warn, 5)
  eq(cfg.profile, "temperate"); eq(cfg.month, "auto")
end)

test("tournament override wins over default profile", function()
  local cfg = m.parse_config("profile = arid\ntournament.17 = cold\ntournament.17.hemisphere = south")
  local p, h = m.resolve_profile(cfg, 17)
  eq(p, "cold"); eq(h, "south")
  p, h = m.resolve_profile(cfg, 99)
  eq(p, "arid"); eq(h, "north")
  -- cold + south in July => climate month 1 => winter pitch
  local c = m.pick_conditions(cfg, fixture({ tournament = 17, month = 7 }))
  eq(c.climate_month, 1); eq(c.season, 1)
end)

test("shipped ini parses cleanly", function()
  local f = assert(io.open(root .. "/modules/MatchdayConditions.ini", "r"))
  local cfg, warn = m.parse_config(f:read("*a")); f:close()
  eq(#warn, 0, "warnings: " .. table.concat(warn, "; "))
  eq(cfg.enabled, true)
end)

---------------------------------------------------------------------------
-- End-to-end with a mocked sider context
---------------------------------------------------------------------------
test("sider integration: init, set_conditions, overlay, hotkeys", function()
  local handlers = {}
  local ctx = {
    sider_dir = root .. "/",
    register = function(event, fn) handlers[event] = fn end,
  }
  m.init(ctx)
  assert(handlers.set_conditions and handlers.overlay_on and handlers.key_down, "handlers missing")
  eq(m._get_config().profile, "temperate", "ini loaded")

  ctx.home_team, ctx.away_team, ctx.tournament_id = 101, 202, 17
  local opts = { stadium = 5, weather = 0, timeofday = 0, season = 0, weather_effects = 1 }
  local out = handlers.set_conditions(ctx, opts)
  assert(out, "set_conditions returned nil")
  assert(out.weather >= 0 and out.weather <= 2)
  assert(out.timeofday == 0 or out.timeofday == 1)
  assert(out.season == 0 or out.season == 1)
  eq(out.weather_effects, 2); eq(out.stadium, 5, "other options preserved")

  -- replay -> identical
  local again = handlers.set_conditions(ctx, { stadium = 5 })
  eq(again.weather, out.weather); eq(again.timeofday, out.timeofday)

  local text = handlers.overlay_on(ctx)
  assert(text:find("Matchday Conditions") and text:find("ON") and text:find("Last match"), text)

  handlers.key_down(ctx, 0x33)                       -- next profile
  eq(m._get_config().profile, "cold")
  handlers.key_down(ctx, 0x32)                       -- reroll
  handlers.key_down(ctx, 0x31)                       -- disable
  eq(m._get_config().enabled, false)
  eq(handlers.set_conditions(ctx, { stadium = 5 }), nil, "disabled should leave options alone")
  assert(handlers.overlay_on(ctx):find("OFF"))
  handlers.key_down(ctx, 0x31)
  eq(m._get_config().enabled, true)

  local found = false
  for _, l in ipairs(logs) do if l:find("tournament=17") then found = true end end
  assert(found, "expected a log line with the tournament id")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
