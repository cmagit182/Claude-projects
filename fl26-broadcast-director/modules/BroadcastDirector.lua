--[[
  Broadcast Director  -  a sider module for Football Life 26
  =================================================================
  Camera mods for PES 2021 / FL26 give you one fixed set of camera
  values. A real broadcast isn't fixed: every ground has its own camera
  gantry, every competition its own TV style, and the director changes
  the shot as the match develops.

  Broadcast Director drives the game's Fan View camera like a TV
  director would:

    * Presets   - named camera set-ups (main gantry, low broadcast,
                  tactical wide, ...), editable live in the overlay.
    * Rules     - a preset per stadium and per competition, applied
                  automatically (stadium beats competition beats default).
                  Press one key to remember the current preset for the
                  current stadium or competition.
    * Direction - reads the live match (sider's match.stats) and adjusts
                  the shot: tighter framing in the closing minutes of a
                  close game, a little tighter in extra time, and a
                  dedicated low, close shot for penalty shoot-outs.
    * Blending  - every change is eased in over ~1 second instead of
                  snapping.
    * Operator  - optional, very subtle hand-held drift on zoom and
                  height so the picture doesn't look tripod-locked.

  Camera memory locations come from sider's camera.lua (game research
  by nesa24). Use this module INSTEAD of camera.lua, not together.

  sider.ini:
      lua.module = "BroadcastDirector.lua"
      match-stats.enabled = 1        ; needed for live direction only
  In game: Settings > Camera > "Fan View".
--]]

local m = { version = "1.0.0" }

---------------------------------------------------------------------------
-- Camera parameters and defaults (Fan View, PES 2021 engine)
---------------------------------------------------------------------------

m.PARAMS = { "zoom", "height", "angle" }
m.GAME_DEFAULT = { zoom = 25.60, height = 0.43, angle = 1.00 }   -- camera.lua defaults
m.LIMITS = { zoom = { 10, 60 }, height = { 0.05, 2.0 }, angle = { 0.2, 3.0 } }
m.STEP = { zoom = 0.25, height = 0.01, angle = 0.02 }
m.SETTLE = { zoom = 0.005, height = 0.0002, angle = 0.0002 }
m.OFFSETS = { zoom = 0x08, height = 0x0c, angle = 0x24 }        -- inside the camera block

m.PATTERNS = {
  camera = "\x0f\x11\x44\x24\x20\x89\x45\x87\x0f\x11\x4c\x24\x30",
}

m.BUILTIN_PRESETS = {
  { name = "Standard TV",    zoom = 25.60, height = 0.43, angle = 1.00 },
  { name = "Main Gantry",    zoom = 27.50, height = 0.62, angle = 1.15 },
  { name = "Low Broadcast",  zoom = 23.50, height = 0.30, angle = 0.90 },
  { name = "Close TV",       zoom = 21.50, height = 0.38, angle = 0.95 },
  { name = "Tactical Wide",  zoom = 31.00, height = 0.72, angle = 1.25 },
  { name = "Retro 90s",      zoom = 28.50, height = 0.50, angle = 1.05 },
}

-- Situational modifiers: zoom is multiplied, height multiplied, angle added
m.DIRECTION = {
  shootout = { zoom = 0.82, height = 0.75, angle = -0.05, label = "penalty shoot-out" },
  extra_time = { zoom = 0.96, height = 1.00, angle = 0.00, label = "extra time" },
  tension = { zoom = 0.93, height = 0.95, angle = 0.00, label = "closing minutes" },
}

m.BREATHING_LEVELS = { 0, 0.5, 1, 2 }    -- off / subtle / normal / strong
m.BREATHING_NAMES = { [0] = "off", [0.5] = "subtle", [1] = "normal", [2] = "strong" }

---------------------------------------------------------------------------
-- Pure helpers (unit-tested)
---------------------------------------------------------------------------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function to_bool(v) v = tostring(v):lower(); return v == "1" or v == "on" or v == "true" or v == "yes" end

function m.clamp_values(v)
  local out = {}
  for _, p in ipairs(m.PARAMS) do out[p] = clamp(v[p], m.LIMITS[p][1], m.LIMITS[p][2]) end
  return out
end

function m.default_config()
  local cfg = {
    default = "Standard TV", blend_seconds = 0.8, breathing = 0.5, director = true,
    tension_from = 80, invert_zoom = false,
    presets = {}, order = {}, stadium = {}, tournament = {},
  }
  for _, p in ipairs(m.BUILTIN_PRESETS) do
    cfg.presets[p.name] = { zoom = p.zoom, height = p.height, angle = p.angle }
    cfg.order[#cfg.order + 1] = p.name
  end
  return cfg
end

local function find_preset(cfg, name)
  if not name then return nil end
  if cfg.presets[name] then return name end
  local lname = name:lower()
  for n in pairs(cfg.presets) do if n:lower() == lname then return n end end
  return nil
end

--[[ ini format:
       default = Main Gantry
       blend_seconds = 0.8
       breathing = 0.5
       director = on
       preset.My Cam = 26.0, 0.5, 1.1     (zoom, height, angle)
       stadium.12 = Main Gantry
       tournament.17 = Low Broadcast                                    ]]
function m.parse_config(text)
  local cfg = m.default_config()
  local warnings = {}
  local rules = {}
  local n = 0
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    n = n + 1
    line = trim((line:gsub("^%s*[;#].*$", ""):gsub("%s+;.*$", "")))
    if line ~= "" then
      local key, value = line:match("^([^=]-)%s*=%s*(.-)$")
      if not key or key == "" then
        warnings[#warnings + 1] = string.format("line %d: cannot parse '%s'", n, line)
      else
        local lkey = key:lower()
        local pname = key:match("^[Pp]reset%.(.+)$")
        local sid = lkey:match("^stadium%.(%d+)$")
        local tid = lkey:match("^tournament%.(%d+)$")
        if pname then
          local z, h, a = value:match("^([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)$")
          if z then
            pname = trim(pname)
            if not cfg.presets[pname] then cfg.order[#cfg.order + 1] = pname end
            cfg.presets[pname] = m.clamp_values({ zoom = tonumber(z), height = tonumber(h), angle = tonumber(a) })
          else
            warnings[#warnings + 1] = string.format("line %d: preset needs 'zoom, height, angle'", n)
          end
        elseif sid or tid then
          rules[#rules + 1] = { kind = sid and "stadium" or "tournament", id = tonumber(sid or tid), name = value, line = n }
        elseif lkey == "default" then cfg.default = value
        elseif lkey == "director" or lkey == "invert_zoom" then cfg[lkey] = to_bool(value)
        elseif lkey == "blend_seconds" or lkey == "breathing" or lkey == "tension_from" then
          local v = tonumber(value)
          local lim = ({ blend_seconds = { 0, 10 }, breathing = { 0, 3 }, tension_from = { 45, 89 } })[lkey]
          if v and v >= lim[1] and v <= lim[2] then cfg[lkey] = v
          else warnings[#warnings + 1] = string.format("line %d: %s must be %s-%s", n, lkey, lim[1], lim[2]) end
        else
          warnings[#warnings + 1] = string.format("line %d: unknown key '%s'", n, key)
        end
      end
    end
  end
  -- rules may refer to presets defined further down, so resolve them last
  for _, r in ipairs(rules) do
    local name = find_preset(cfg, r.name)
    if name then cfg[r.kind][r.id] = name
    else warnings[#warnings + 1] = string.format("line %d: unknown preset '%s'", r.line, r.name) end
  end
  local d = find_preset(cfg, cfg.default)
  if d then cfg.default = d
  else
    warnings[#warnings + 1] = "unknown default preset '" .. tostring(cfg.default) .. "', using Standard TV"
    cfg.default = "Standard TV"
  end
  return cfg, warnings
end

local function fmt(v) return (string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", ".0")) end

function m.serialize_config(cfg)
  local L = {
    "; Broadcast Director settings (rewritten by the module when you save from the overlay)",
    ";",
    "; default        preset used when no stadium/competition rule matches",
    "; blend_seconds  how long camera changes take to ease in (0 = instant)",
    "; breathing      hand-held drift: 0 off, 0.5 subtle, 1 normal, 2 strong",
    "; director       on/off: live direction (closing minutes, extra time, shoot-outs)",
    "; tension_from   minute when the closing-minutes framing starts to build",
    "; invert_zoom    on if 'tighter' shots come out wider on your setup",
    "; preset.<name> = zoom, height, angle      (game default: 25.6, 0.43, 1.0)",
    "; stadium.<id> = <preset>     tournament.<id> = <preset>",
    "",
    "default = " .. cfg.default,
    "blend_seconds = " .. fmt(cfg.blend_seconds),
    "breathing = " .. fmt(cfg.breathing),
    "director = " .. (cfg.director and "on" or "off"),
    "tension_from = " .. tostring(cfg.tension_from),
    "invert_zoom = " .. (cfg.invert_zoom and "on" or "off"),
    "",
  }
  for _, name in ipairs(cfg.order) do
    local p = cfg.presets[name]
    L[#L + 1] = string.format("preset.%s = %s, %s, %s", name, fmt(p.zoom), fmt(p.height), fmt(p.angle))
  end
  L[#L + 1] = ""
  for _, kind in ipairs({ "stadium", "tournament" }) do
    local ids = {}
    for id in pairs(cfg[kind]) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do L[#L + 1] = string.format("%s.%d = %s", kind, id, cfg[kind][id]) end
  end
  return table.concat(L, "\n") .. "\n"
end

-- Which preset applies, and why
function m.resolve(cfg, stadium, tournament, override)
  if override and cfg.presets[override] then return override, "manual" end
  if stadium and cfg.stadium[stadium] then return cfg.stadium[stadium], "stadium " .. stadium end
  if tournament and cfg.tournament[tournament] then return cfg.tournament[tournament], "competition " .. tournament end
  return cfg.default, "default"
end

--[[ Live direction from a match.stats() snapshot. Returns a list of
     { mod, weight } where weight 0..1 scales the modifier. ]]
function m.direction(cfg, stats)
  if not cfg.director or not stats then return {} end
  local out = {}
  local p, min = stats.period or 0, stats.clock_minutes or 0
  if p == 5 then
    out[#out + 1] = { mod = m.DIRECTION.shootout, weight = 1 }
    return out
  end
  if p == 3 or p == 4 then out[#out + 1] = { mod = m.DIRECTION.extra_time, weight = 1 } end
  local diff = math.abs((stats.home_score or 0) - (stats.away_score or 0))
  if diff <= 1 then
    local w = 0
    if p == 2 or (p == 3 and min >= 90) then
      w = (min - cfg.tension_from) / (90 - cfg.tension_from)
    elseif p == 4 then
      w = (min - 110) / 10
    end
    w = clamp(w, 0, 1)
    if w > 0 then out[#out + 1] = { mod = m.DIRECTION.tension, weight = w } end
  end
  return out
end

-- Target camera values: preset + weighted modifiers
function m.target(cfg, preset, mods)
  local v = { zoom = preset.zoom, height = preset.height, angle = preset.angle }
  for _, d in ipairs(mods) do
    local zf = 1 + (d.mod.zoom - 1) * d.weight
    if cfg.invert_zoom then zf = 1 / zf end
    v.zoom = v.zoom * zf
    v.height = v.height * (1 + (d.mod.height - 1) * d.weight)
    v.angle = v.angle + d.mod.angle * d.weight
  end
  return m.clamp_values(v)
end

-- Exponential ease towards the target; dt in seconds
function m.blend(current, target, dt, seconds)
  if not current or seconds <= 0 then return { zoom = target.zoom, height = target.height, angle = target.angle } end
  local k = 1 - math.exp(-dt / (seconds / 3))     -- ~95% of the way after `seconds`
  local out = {}
  for _, p in ipairs(m.PARAMS) do
    local d = target[p] - current[p]
    -- settle exactly once the remaining difference is invisible
    if math.abs(d) < m.SETTLE[p] then out[p] = target[p] else out[p] = current[p] + d * k end
  end
  return out
end

-- Hand-held drift: two slow, unrelated sine waves per axis (relative offsets)
function m.breathing(t, level)
  if level <= 0 then return 0, 0 end
  local z = 0.0035 * level * (math.sin(t * 0.61) * 0.7 + math.sin(t * 1.37 + 1.1) * 0.3)
  local h = 0.0030 * level * (math.sin(t * 0.47 + 2.3) * 0.6 + math.sin(t * 1.09) * 0.4)
  return z, h
end

---------------------------------------------------------------------------
-- Game memory (same locations as sider's camera.lua, by nesa24)
---------------------------------------------------------------------------

function m.find_camera_block(mem)
  local loc = mem.search_process(m.PATTERNS.camera)
  if not loc then return nil end
  local rel = mem.unpack("i32", mem.read(loc - 4, 4))
  return loc + rel
end

function m.read_camera(mem, base)
  local v = {}
  for _, p in ipairs(m.PARAMS) do v[p] = mem.unpack("f", mem.read(base + m.OFFSETS[p], 4)) end
  return v
end

function m.write_camera(mem, base, v)
  for _, p in ipairs(m.PARAMS) do mem.write(base + m.OFFSETS[p], mem.pack("f", v[p])) end
end

---------------------------------------------------------------------------
-- sider glue
---------------------------------------------------------------------------

local FPS = 60
local VK = { k1 = 0x31, k2 = 0x32, k3 = 0x33, k4 = 0x34, k5 = 0x35, k6 = 0x36,
             k8 = 0x38, k9 = 0x39, k0 = 0x30, minus = 0xbd, plus = 0xbb }

local S = {
  cfg = m.default_config(), base = nil, err = nil, ini_path = nil,
  current = nil, written = nil, override = nil, frame = 0, stats = nil,
  stats_ok = nil, sel = 1, message = nil, stadium = nil, tournament = nil,
}

local function say(msg) if log then log(msg) end end

local function save_config()
  local f, err = io.open(S.ini_path, "w")
  if not f then S.message = "Cannot save: " .. tostring(err); return end
  f:write(m.serialize_config(S.cfg))
  f:close()
end

local function active_preset()
  local name, why = m.resolve(S.cfg, S.stadium, S.tournament, S.override)
  return name, why, S.cfg.presets[name]
end

local function step(dt)
  local _, _, preset = active_preset()
  local target = m.target(S.cfg, preset, m.direction(S.cfg, S.stats))
  S.current = m.blend(S.current, target, dt, S.cfg.blend_seconds)
  local out = { zoom = S.current.zoom, height = S.current.height, angle = S.current.angle }
  if S.stats and S.cfg.breathing > 0 then
    local bz, bh = m.breathing(S.frame / FPS, S.cfg.breathing)
    out.zoom = out.zoom * (1 + bz)
    out.height = out.height * (1 + bh)
  end
  out = m.clamp_values(out)
  local w = S.written
  if not w or math.abs(w.zoom - out.zoom) > 1e-4 or math.abs(w.height - out.height) > 1e-5
      or math.abs(w.angle - out.angle) > 1e-5 then
    m.write_camera(memory, S.base, out)
    S.written = out
  end
end

function m.display_frame(ctx)
  if not S.base then return end
  S.frame = S.frame + 1
  if S.frame % 6 == 0 then
    -- context and match state 10x per second is plenty
    S.stadium, S.tournament = ctx.stadium, ctx.tournament_id
    if match and match.stats then
      S.stats = match.stats()
      if S.stats then S.stats_ok = true end
    else
      S.stats, S.stats_ok = nil, false
    end
  end
  step(1 / FPS)
end

function m.set_teams(ctx)
  S.override = nil       -- manual choice lasts one match
end

function m.after_set_conditions(ctx)
  S.stadium, S.tournament = ctx.stadium, ctx.tournament_id
end

function m.overlay_on(ctx)
  if not S.base then
    return "Broadcast Director: camera not found in game memory (" .. tostring(S.err) .. ")"
  end
  local name, why, preset = active_preset()
  local mods = m.direction(S.cfg, S.stats)
  local live = {}
  for _, d in ipairs(mods) do live[#live + 1] = string.format("%s %d%%", d.mod.label, math.floor(d.weight * 100 + 0.5)) end
  local L = {
    string.format("Broadcast Director v%s  |  preset: %s  (%s)", m.version, name, why),
    string.format("Stadium %s  |  competition %s  |  direction %s%s  |  hand-held %s",
      tostring(S.stadium or "-"), tostring(S.tournament or "-"), S.cfg.director and "ON" or "OFF",
      #live > 0 and (": " .. table.concat(live, ", ")) or "",
      m.BREATHING_NAMES[S.cfg.breathing] or tostring(S.cfg.breathing)),
  }
  for i, p in ipairs(m.PARAMS) do
    local cur = S.written and S.written[p] or preset[p]
    L[#L + 1] = string.format("%s %-6s %6.2f   (live %6.2f)", i == S.sel and "-->" or "   ", p, preset[p], cur)
  end
  if S.stats_ok == false and S.cfg.director then
    L[#L + 1] = "!! add 'match-stats.enabled = 1' to sider.ini for live direction"
  end
  L[#L + 1] = "[1][2] preset  [3] direction  [4] hand-held  [5] use for this stadium  [6] use for this competition"
  L[#L + 1] = "[9][0] choose value  [-][+] adjust preset  [8] save"
  if S.message then L[#L + 1] = S.message end
  return table.concat(L, "\n")
end

local function cycle_preset(dir)
  local name = active_preset()
  local idx = 1
  for i, n in ipairs(S.cfg.order) do if n == name then idx = i end end
  idx = (idx - 1 + dir) % #S.cfg.order + 1
  S.override = S.cfg.order[idx]
  S.message = "Preset for this match: " .. S.override
end

function m.key_down(ctx, vkey)
  if not S.base then return end
  local name, _, preset = active_preset()
  if vkey == VK.k1 then cycle_preset(-1)
  elseif vkey == VK.k2 then cycle_preset(1)
  elseif vkey == VK.k3 then
    S.cfg.director = not S.cfg.director
    S.message = "Live direction " .. (S.cfg.director and "on" or "off")
  elseif vkey == VK.k4 then
    local idx = 1
    for i, v in ipairs(m.BREATHING_LEVELS) do if v == S.cfg.breathing then idx = i end end
    S.cfg.breathing = m.BREATHING_LEVELS[idx % #m.BREATHING_LEVELS + 1]
    S.message = "Hand-held drift: " .. m.BREATHING_NAMES[S.cfg.breathing]
  elseif vkey == VK.k5 or vkey == VK.k6 then
    local kind = vkey == VK.k5 and "stadium" or "tournament"
    local id = kind == "stadium" and S.stadium or S.tournament
    if not id then S.message = "No " .. kind .. " known yet - start a match first"
    else
      S.cfg[kind][id] = name
      S.override = nil
      save_config()
      S.message = string.format("Saved: %s %s uses %s", kind == "stadium" and "stadium" or "competition", id, name)
    end
  elseif vkey == VK.k9 then S.sel = (S.sel - 2) % #m.PARAMS + 1
  elseif vkey == VK.k0 then S.sel = S.sel % #m.PARAMS + 1
  elseif vkey == VK.minus or vkey == VK.plus then
    local p = m.PARAMS[S.sel]
    local v = preset[p] + (vkey == VK.plus and 1 or -1) * m.STEP[p]
    preset[p] = clamp(v, m.LIMITS[p][1], m.LIMITS[p][2])
    S.message = string.format("%s: %s = %.2f (press [8] to save)", name, p, preset[p])
  elseif vkey == VK.k8 then
    save_config()
    S.message = "Saved to BroadcastDirector.ini"
  end
end

function m.init(ctx)
  local root = (ctx and ctx.sider_dir) or ""
  local sep = root:find("/") and "/" or "\\"
  S.ini_path = root .. "modules" .. sep .. "BroadcastDirector.ini"
  local f = io.open(S.ini_path, "r")
  if f then
    local cfg, warnings = m.parse_config(f:read("*a"))
    f:close()
    S.cfg = cfg
    for _, w in ipairs(warnings) do say("BroadcastDirector.ini " .. w) end
  else
    S.cfg = m.default_config()
    save_config()
    say("created " .. S.ini_path)
  end

  -- (sider's module environment has no pcall; the search itself is safe)
  S.base, S.err, S.current, S.written = nil, nil, nil, nil
  local base = memory and m.find_camera_block(memory)
  if base then
    S.base = base
    local before = m.read_camera(memory, base)
    say(string.format("camera block at %s (zoom %.2f, height %.2f, angle %.2f)",
      memory.hex and memory.hex(base) or tostring(base), before.zoom, before.height, before.angle))
  else
    S.err = memory and "code pattern not found" or "sider memory library unavailable"
    say("camera block not found: " .. S.err .. " - module inactive")
  end

  ctx.register("display_frame", m.display_frame)
  ctx.register("set_teams", m.set_teams)
  ctx.register("after_set_conditions", m.after_set_conditions)
  ctx.register("overlay_on", m.overlay_on)
  ctx.register("key_down", m.key_down)
end

function m._S() return S end

return m
