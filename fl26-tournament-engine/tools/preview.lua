-- Preview a competition outside the game: validates the file, makes the
-- draw, simulates every match and prints tables, knockouts and champion.
--
--   luajit tools/preview.lua modules/TournamentEngine/world-cup-2026.txt [report.html] [edition]
--
-- Use it to check a competition you wrote before playing it in FL26.
local here = (arg[0]:match("^(.*)[/\\]tools[/\\]") or ".")
package.path = here .. "/modules/?.lua;" .. package.path
local m = require("TournamentEngine")

local file, out, edition = arg[1], arg[2], tonumber(arg[3] or "1")
if not file then
  print("usage: luajit tools/preview.lua <competition.txt> [report.html] [edition]")
  os.exit(2)
end
local f = assert(io.open(file, "r"))
local comp, errors, warnings = m.parse_competition(f:read("*a"))
f:close()
for _, w in ipairs(warnings) do print("warning: " .. w) end
if #errors > 0 then
  for _, e in ipairs(errors) do print("ERROR: " .. e) end
  os.exit(1)
end
comp.controlled = {}                       -- simulate everything
local state = m.restore(comp, "edition " .. edition .. "\n")
if state.error then print("ERROR: " .. state.error); os.exit(1) end

print(string.format("%s  (%s, %d teams, %d matches, edition %d)\n", comp.name, comp.format, #comp.teams,
  #state.fixtures, edition))
local zone = m.zone_fn(state)
for _, tb in ipairs(m.current_tables(state)) do
  print(tb.title)
  for _, line in ipairs(m.table_lines(state, tb.rows, zone)) do print("  " .. line) end
  print()
end
for _, kr in ipairs(state.ko) do
  print(kr.name)
  for _, tie in ipairs(kr.ties) do
    local ga, gb, pa, pb = m.tie_aggregate(state, tie)
    local legs = {}
    for _, fx in ipairs(tie.fixtures) do legs[#legs + 1] = m.score_text(state.results[fx.key]) end
    print(string.format("  %-22s v %-22s %d-%d%s  [%s]  -> %s", comp.teams[tie.a].name, comp.teams[tie.b].name,
      ga, gb, (pa and pa ~= pb) and string.format(" (%d-%d p)", pa, pb) or "", table.concat(legs, ", "),
      comp.teams[tie.winner].name))
  end
  print()
end
print("Champion: " .. comp.teams[state.champion].name)
if out then
  local o = assert(io.open(out, "w"))
  o:write(m.report_html(state))
  o:close()
  print("Report written to " .. out)
end
