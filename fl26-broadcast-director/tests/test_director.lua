-- Broadcast Director tests (LuaJIT / Lua 5.1):  ./run_tests.sh
-- sider's memory library is replaced by a simulated process: a byte store
-- containing the same machine-code pattern camera.lua searches for, a
-- RIP-relative offset to a camera block, and real IEEE-754 floats.
local root = arg[1] or "."
local tmp = arg[2] or "/tmp"
package.path = root .. "/modules/?.lua;" .. package.path

local logs = {}
log = function(msg) logs[#logs + 1] = msg end
local m = require("BroadcastDirector")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("ok   " .. name)
  else failed = failed + 1; print("FAIL " .. name .. "\n     " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function near(a, b, tol, msg)
  if math.abs(a - b) > (tol or 1e-4) then error((msg or "") .. string.format(" expected %.5f, got %.5f", b, a), 2) end
end

---------------------------------------------------------------------------
-- Simulated game process
---------------------------------------------------------------------------
local function pack_f32(x)
  if x == 0 then return "\0\0\0\0" end
  local sign = 0
  if x < 0 then sign = 1; x = -x end
  local mant, exp = math.frexp(x)               -- x = mant * 2^exp, mant in [0.5,1)
  exp = exp + 126
  mant = math.floor((mant * 2 - 1) * 8388608 + 0.5)
  if mant == 8388608 then mant = 0; exp = exp + 1 end
  local b4 = sign * 128 + math.floor(exp / 2)
  local b3 = (exp % 2) * 128 + math.floor(mant / 65536)
  local b2 = math.floor(mant / 256) % 256
  local b1 = mant % 256
  return string.char(b1, b2, b3, b4)
end
local function unpack_f32(s)
  local b1, b2, b3, b4 = s:byte(1, 4)
  local sign = b4 >= 128 and -1 or 1
  local exp = (b4 % 128) * 2 + math.floor(b3 / 128)
  local mant = (b3 % 128) * 65536 + b2 * 256 + b1
  if exp == 0 then return 0 end
  return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end
local function pack_i32(v)
  if v < 0 then v = v + 4294967296 end
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function unpack_i32(s)
  local a, b, c, d = s:byte(1, 4)
  local v = a + b * 256 + c * 65536 + d * 16777216
  if v >= 2147483648 then v = v - 4294967296 end
  return v
end

local function new_process()
  local bytes = {}
  local p = { writes = 0 }
  function p.write(addr, s)
    for i = 1, #s do bytes[addr + i - 1] = s:byte(i) end
    p.writes = p.writes + 1
  end
  function p.read(addr, n)
    local t = {}
    for i = 0, n - 1 do t[#t + 1] = string.char(bytes[addr + i] or 0) end
    return table.concat(t)
  end
  function p.search_process(pattern) return p.pattern_at end
  function p.pack(fmt, v)
    if fmt == "f" then return pack_f32(v) elseif fmt == "i32" then return pack_i32(v) end
    error("fmt " .. fmt)
  end
  function p.unpack(fmt, s)
    if fmt == "f" then return unpack_f32(s) elseif fmt == "i32" then return unpack_i32(s) end
    error("fmt " .. fmt)
  end
  function p.hex(v) return string.format("0x%x", v) end
  -- code: "...movups [rbp+rel32]..." pattern at 0x140001000; rel32 sits just before it
  p.pattern_at = 0x140001000
  p.block = 0x143f20000
  p.write(p.pattern_at - 4, pack_i32(p.block - p.pattern_at))
  p.write(p.pattern_at, m.PATTERNS.camera)
  -- game default Fan View values
  p.write(p.block + 0x08, pack_f32(25.6))
  p.write(p.block + 0x0c, pack_f32(0.43))
  p.write(p.block + 0x24, pack_f32(1.0))
  p.write(p.block + 0x10, pack_f32(123.0))      -- neighbouring data must stay untouched
  p.writes = 0
  return p
end

---------------------------------------------------------------------------
-- Pure logic
---------------------------------------------------------------------------
test("float encoding used by the simulated process is exact IEEE-754", function()
  for _, v in ipairs({ 25.6, 0.43, 1.0, 31.0, 0.05, 60 }) do near(unpack_f32(pack_f32(v)), v, 1e-6) end
  eq(pack_f32(1.0), "\0\0\128\63")
end)

test("config: defaults, presets, rules (forward references), warnings", function()
  local cfg, w = m.parse_config([[
default = main gantry
breathing = 1
director = off
stadium.12 = My Cam
tournament.17 = Low Broadcast
preset.My Cam = 26.5, 0.55, 1.1
preset.Standard TV = 25.0, 0.40, 1.0
]])
  eq(#w, 0, table.concat(w, ";"))
  eq(cfg.default, "Main Gantry"); eq(cfg.breathing, 1); eq(cfg.director, false)
  eq(cfg.stadium[12], "My Cam"); eq(cfg.tournament[17], "Low Broadcast")
  eq(cfg.presets["My Cam"].zoom, 26.5)
  eq(cfg.presets["Standard TV"].zoom, 25.0, "built-in preset overridden")
  eq(cfg.order[#cfg.order], "My Cam")
  local c2, w2 = m.parse_config("default = Nope\nstadium.3 = Ghost\npreset.X = 1,2\nbreathing = 9\nfoo = 1\npreset.Huge = 999, 5, 9")
  eq(#w2, 5, table.concat(w2, ";"))
  eq(c2.default, "Standard TV")
  eq(c2.presets.Huge.zoom, 60, "clamped"); eq(c2.presets.Huge.height, 2.0); eq(c2.presets.Huge.angle, 3.0)
end)

test("config round-trips through serialize/parse", function()
  local cfg = m.parse_config("preset.Sky = 26.1, 0.47, 1.08\nstadium.40 = Sky\ntournament.17 = Close TV\nbreathing = 2\ninvert_zoom = on")
  local back, w = m.parse_config(m.serialize_config(cfg))
  eq(#w, 0, table.concat(w, ";"))
  eq(back.stadium[40], "Sky"); eq(back.tournament[17], "Close TV")
  eq(back.breathing, 2); eq(back.invert_zoom, true)
  near(back.presets.Sky.height, 0.47)
end)

test("shipped ini parses cleanly", function()
  local f = assert(io.open(root .. "/modules/BroadcastDirector.ini"))
  local _, w = m.parse_config(f:read("*a")); f:close()
  eq(#w, 0, table.concat(w, ";"))
end)

test("resolve: manual > stadium > competition > default", function()
  local cfg = m.parse_config("stadium.12 = Main Gantry\ntournament.17 = Low Broadcast")
  eq((m.resolve(cfg, 12, 17, nil)), "Main Gantry")
  eq((m.resolve(cfg, 99, 17, nil)), "Low Broadcast")
  eq((m.resolve(cfg, 99, 99, nil)), "Standard TV")
  eq((m.resolve(cfg, 12, 17, "Retro 90s")), "Retro 90s")
  local _, why = m.resolve(cfg, 12, 17); eq(why, "stadium 12")
end)

test("direction: quiet early on, builds in the closing minutes of a close game", function()
  local cfg = m.default_config()
  eq(#m.direction(cfg, { period = 1, clock_minutes = 20, home_score = 0, away_score = 0 }), 0)
  eq(#m.direction(cfg, nil), 0)
  local d = m.direction(cfg, { period = 2, clock_minutes = 85, home_score = 1, away_score = 0 })
  eq(#d, 1); near(d[1].weight, 0.5); eq(d[1].mod.label, "closing minutes")
  eq(m.direction(cfg, { period = 2, clock_minutes = 93, home_score = 2, away_score = 2 })[1].weight, 1)
  eq(#m.direction(cfg, { period = 2, clock_minutes = 88, home_score = 3, away_score = 0 }), 0, "game is over")
  local et = m.direction(cfg, { period = 4, clock_minutes = 115, home_score = 1, away_score = 1 })
  eq(#et, 2); eq(et[1].mod.label, "extra time"); near(et[2].weight, 0.5)
  local so = m.direction(cfg, { period = 5, clock_minutes = 120, home_score = 1, away_score = 1 })
  eq(#so, 1); eq(so[1].mod.label, "penalty shoot-out")
  cfg.director = false
  eq(#m.direction(cfg, { period = 5 }), 0)
end)

test("target: modifiers tighten the shot, invert_zoom flips zoom only", function()
  local cfg = m.default_config()
  local p = cfg.presets["Standard TV"]
  local t = m.target(cfg, p, { { mod = m.DIRECTION.shootout, weight = 1 } })
  near(t.zoom, 25.6 * 0.82); near(t.height, 0.43 * 0.75); near(t.angle, 0.95)
  local half = m.target(cfg, p, { { mod = m.DIRECTION.tension, weight = 0.5 } })
  near(half.zoom, 25.6 * (1 - 0.07 * 0.5))
  cfg.invert_zoom = true
  near(m.target(cfg, p, { { mod = m.DIRECTION.shootout, weight = 1 } }).zoom, 25.6 / 0.82)
end)

test("blend eases in: ~95% after blend_seconds, instant when 0", function()
  local cur = { zoom = 20, height = 0.4, angle = 1 }
  local tgt = { zoom = 30, height = 0.6, angle = 1.2 }
  local v = cur
  for _ = 1, 48 do v = m.blend(v, tgt, 1 / 60, 0.8) end       -- 0.8 s
  near(v.zoom, 30 - 10 * math.exp(-3), 0.05)
  assert(v.zoom < 30, "not overshooting")
  local inst = m.blend(cur, tgt, 1 / 60, 0)
  eq(inst.zoom, 30)
  eq(m.blend(nil, tgt, 1 / 60, 0.8).zoom, 30, "first frame snaps")
end)

test("hand-held drift is tiny, smooth and bounded", function()
  local maxz, maxh, maxstep, prev = 0, 0, 0, nil
  for f = 0, 60 * 120 do
    local z, h = m.breathing(f / 60, 1)
    maxz, maxh = math.max(maxz, math.abs(z)), math.max(maxh, math.abs(h))
    if prev then maxstep = math.max(maxstep, math.abs(z - prev)) end
    prev = z
  end
  assert(maxz <= 0.0035 + 1e-9 and maxz > 0.002, "zoom drift " .. maxz)       -- <= 0.35%
  assert(maxh <= 0.0030 + 1e-9, "height drift " .. maxh)
  assert(maxstep < 0.0002, "no visible jumps between frames: " .. maxstep)
  local z0 = m.breathing(10, 0); eq(z0, 0)
end)

test("finds the camera block exactly like camera.lua (RIP-relative offset)", function()
  local p = new_process()
  eq(m.find_camera_block(p), p.block)
  local v = m.read_camera(p, p.block)
  near(v.zoom, 25.6, 1e-5); near(v.height, 0.43, 1e-5); near(v.angle, 1.0)
  p.pattern_at = nil
  eq(m.find_camera_block(p), nil)
end)

---------------------------------------------------------------------------
-- End-to-end with a mocked sider
---------------------------------------------------------------------------
local sider_dir = tmp .. "/bd-test-" .. os.time() .. "-" .. math.random(1e6) .. "/"
os.execute("mkdir -p '" .. sider_dir .. "modules'")
local INI = sider_dir .. "modules/BroadcastDirector.ini"

local proc = new_process()
memory = proc
local live = nil
match = { stats = function() return live end }

local H = {}
local ctx = { sider_dir = sider_dir, register = function(e, f) H[e] = f end }
local function frames(n) for _ = 1, n do H.display_frame(ctx) end end
local function cam() return m.read_camera(proc, proc.block) end
local S

test("e2e: init creates the ini, finds the camera, registers events", function()
  m.init(ctx)
  S = m._S()
  eq(S.base, proc.block)
  assert(io.open(INI)):close()
  for _, e in ipairs({ "display_frame", "set_teams", "after_set_conditions", "overlay_on", "key_down" }) do
    assert(H[e], "missing " .. e)
  end
end)

test("e2e: stadium rule applied and blended in; neighbouring memory untouched", function()
  local f = io.open(INI, "w")
  f:write("default = Standard TV\nblend_seconds = 0.5\nbreathing = 0\nstadium.12 = Tactical Wide\n")
  f:close()
  H = {}; m.init(ctx); S = m._S()
  frames(1)
  near(cam().zoom, 25.6, 1e-4, "starts at default")
  ctx.stadium, ctx.tournament_id = 12, 17
  H.set_teams(ctx, 1, 2); H.after_set_conditions(ctx)
  frames(6)
  local z = cam().zoom
  assert(z > 25.6 and z < 31, "partway: " .. z)
  frames(60)
  near(cam().zoom, 31.0, 0.01); near(cam().height, 0.72, 0.001); near(cam().angle, 1.25, 0.001)
  near(unpack_f32(proc.read(proc.block + 0x10, 4)), 123.0, 0, "neighbour untouched")
  -- steady state (fully settled): no more writes
  frames(60)
  local before = proc.writes
  frames(30)
  eq(proc.writes, before, "no redundant writes when nothing changes")
end)

test("e2e: live direction - closing minutes, then the shoot-out camera", function()
  live = { period = 1, clock_minutes = 30, home_score = 0, away_score = 0 }
  frames(120)
  near(cam().zoom, 31.0, 0.01, "nothing early in the match")
  live = { period = 2, clock_minutes = 90, home_score = 1, away_score = 1 }
  frames(120)
  near(cam().zoom, 31.0 * 0.93, 0.02, "closing minutes")
  live = { period = 5, clock_minutes = 120, home_score = 1, away_score = 1, pk_home_score = 0, pk_away_score = 0 }
  frames(120)
  near(cam().zoom, 31.0 * 0.82, 0.02, "shoot-out")
  near(cam().height, 0.72 * 0.75, 0.002)
  local o = H.overlay_on(ctx)
  assert(o:find("penalty shoot%-out 100%%"), o)
  assert(o:find("Tactical Wide  %(stadium 12%)"), o)
  live = nil
  frames(120)
  near(cam().zoom, 31.0, 0.01, "back to the preset after the match")
end)

test("e2e: hand-held drift only moves the picture during a match", function()
  H.key_down(ctx, 0x34)            -- breathing off -> subtle
  eq(S.cfg.breathing, 0.5)
  frames(60)
  local w = proc.writes
  frames(60)
  eq(proc.writes, w, "static outside a match")
  live = { period = 1, clock_minutes = 10, home_score = 0, away_score = 0 }
  local lo, hi = math.huge, -math.huge
  for _ = 1, 600 do
    frames(1)
    local z = cam().zoom
    lo, hi = math.min(lo, z), math.max(hi, z)
  end
  assert(hi - lo > 0.01, "moves: " .. (hi - lo))
  assert(hi - lo < 31 * 0.0035 * 2 * 0.5 + 0.01, "but only a little: " .. (hi - lo))
  live = nil
end)

test("e2e: manual preset for one match, reset on the next fixture", function()
  H.key_down(ctx, 0x32)            -- next preset
  eq(S.override, "Retro 90s")
  frames(90)
  near(cam().zoom, 28.5, 0.01)
  H.set_teams(ctx, 3, 4)
  eq(S.override, nil)
  frames(90)
  near(cam().zoom, 31.0, 0.01)
end)

test("e2e: tune a preset live, save it, and remember it for a competition", function()
  ctx.stadium = 77                 -- a ground without a rule -> default
  frames(90)
  H.key_down(ctx, 0x32)            -- Standard TV -> Main Gantry for this match
  eq(S.override, "Main Gantry")
  H.key_down(ctx, 0x30)            -- select height
  H.key_down(ctx, 0xbb); H.key_down(ctx, 0xbb)
  near(S.cfg.presets["Main Gantry"].height, 0.64)
  H.key_down(ctx, 0x36)            -- use for this competition (17)
  eq(S.cfg.tournament[17], "Main Gantry")
  local saved = m.parse_config(io.open(INI):read("*a"))
  eq(saved.tournament[17], "Main Gantry")
  near(saved.presets["Main Gantry"].height, 0.64)
  frames(120)
  near(cam().height, 0.64, 0.002, "competition rule active without override")
  H.key_down(ctx, 0x35)            -- and for stadium 77
  eq(m.parse_config(io.open(INI):read("*a")).stadium[77], "Main Gantry")
  assert(H.overlay_on(ctx):find("Saved: stadium 77 uses Main Gantry"))
end)

test("e2e: missing match-stats is explained; direction can be switched off", function()
  local saved = match
  match = nil
  frames(6)
  assert(H.overlay_on(ctx):find("match%-stats%.enabled = 1"))
  match = saved
  H.key_down(ctx, 0x33)
  eq(S.cfg.director, false)
  assert(H.overlay_on(ctx):find("direction OFF"))
end)

test("e2e: camera pattern missing -> module stays inactive and says why", function()
  local p2 = new_process()
  p2.pattern_at = nil
  memory = p2
  local h = {}
  m.init({ sider_dir = sider_dir, register = function(e, f) h[e] = f end })
  h.display_frame({})
  eq(p2.writes, 0)
  assert(h.overlay_on({}):find("camera not found"))
  memory = proc
end)

test("module runs inside sider's restricted environment", function()
  local env = {}
  for _, k in ipairs({ "assert", "ipairs", "pairs", "tostring", "tonumber", "table", "string",
                       "math", "unpack", "type", "error", "io", "os", "_VERSION" }) do env[k] = _G[k] end
  env._G = env
  env.log, env.memory, env.match = log, proc, match
  local chunk = assert(loadfile(root .. "/modules/BroadcastDirector.lua"))
  setfenv(chunk, env)
  local mod = chunk()
  local h = {}
  mod.init({ sider_dir = sider_dir, register = function(e, f) h[e] = f end })
  for _ = 1, 30 do h.display_frame({ stadium = 1 }) end
  assert(h.overlay_on({}):find("Broadcast Director"))
end)

os.execute("rm -rf '" .. sider_dir .. "'")
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
