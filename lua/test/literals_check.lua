-- literals_check.lua - every double literal of lua/gen/engine.lua (lua/gen/literals.txt: the text the translator wrote,
-- and the bits of the C# double it stands for) read back by Lua's own parser (load): the bits must be the same, and the
-- value must be a float. After perl/test/literals_check.pl.
-- Run: python3 lua/test/runlua.py lua/test/literals_check.lua
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
return function(dir)
  local n, bad = 0, 0
  for line in io.lines(dir .. "/gen/literals.txt") do
    local t, h = line:match("^(%S+) (%x+)$")
    if t then
      n = n + 1
      local v = assert(load("return " .. t, "=literal", "t", {}))()
      local got = string.format("%016x", (string.unpack(">i8", string.pack(">d", v))))
      if got ~= h or math.type(v) ~= "float" then
        bad = bad + 1
        if bad <= 10 then print("MISMATCH " .. t .. ": C# " .. h .. ", Lua " .. got .. " (" .. tostring(math.type(v)) .. ")") end
      end
    end
  end
  print("double literals: " .. n .. ", mismatches: " .. bad)
  return bad == 0 and 0 or 1
end
