-- sortcheck.lua O|D|I|L - the cases of tests/stdcheck/sortcheck.cpp through the Lua runtime's sorts (lua/rt/containers.lua);
-- output must equal sortcheck.cpp's byte for byte. Mode O: the generic StdAlgo_Sort / StdAlgo_StableSort /
-- StdAlgo_PartialSort over an array of structs (tables). D, I or L: the same permutations from the specialisations
-- (StdAlgo_Sort__I over the ids, ordered by their keys, and so on). After perl/test/sortcheck.pl.
-- Run: python3 lua/test/runlua.py lua/test/sortcheck.lua MODE
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
return function(dir, mode)
  local E = { CWD = "/" }
  for _, n in ipairs({ "core", "strvec", "primes", "containers", "glibm_rt", "glibm", "crt", "io" }) do
    assert(loadfile(dir .. "/rt/" .. n .. ".lua", "t"))(E)
  end
  E.inherit_all()
  mode = mode or "O"
  local s = 1729
  local function rnd() local x = s; x = x ~ (x << 13); x = x ~ (x >> 7); x = x ~ (x << 17); s = x; return x end
  -- C's uint64 % m (the generator is unsigned in sortcheck.cpp)
  local function urem(x, m)
    if x >= 0 then return x % m end
    local q = ((x >> 1) // m) << 1
    local r = x - q * m
    while math.ult(m - 1, r) do r = r - m end
    return r
  end
  local run
  if mode == "O" then
    run = function(key, n, which)
      local a = { n = n }
      for i = 0, n - 1 do a[i] = { key = key[i], id = i } end
      local lt = function(x, y) return x.key < y.key end
      if which == 0 then E.StdAlgo_Sort(a, 0, n, lt) elseif which == 1 then E.StdAlgo_StableSort(a, 0, n, lt)
      else E.StdAlgo_PartialSort(a, 0, n, n, lt) end
      local r = {}
      for i = 0, n - 1 do r[#r + 1] = a[i].id end
      return r
    end
  else
    local sortf, stablef, partf = E["StdAlgo_Sort__" .. mode], E["StdAlgo_StableSort__" .. mode], E["StdAlgo_PartialSort__" .. mode]
    run = function(key, n, which)
      local a = { n = n }
      for i = 0, n - 1 do a[i] = mode == "D" and i + 0.0 or i end
      local lt = function(x, y) return key[math.tointeger(x)] < key[math.tointeger(y)] end
      if which == 0 then sortf(a, 0, n, lt) elseif which == 1 then stablef(a, 0, n, lt) else partf(a, 0, n, n, lt) end
      local r = {}
      for i = 0, n - 1 do r[#r + 1] = math.tointeger(a[i]) end
      return r
    end
  end
  local out = {}
  local sizes = {}
  for n = 0, 300 do sizes[#sizes + 1] = n end
  for _, n in ipairs({ 511, 512, 513, 1000, 4096, 10007 }) do sizes[#sizes + 1] = n end
  for _, n in ipairs(sizes) do
    for pat = 0, 6 do
      local key = {}
      for i = 0, n - 1 do
        local v
        if pat == 0 then v = urem(rnd(), 5) elseif pat == 1 then v = urem(rnd(), 1000000) elseif pat == 2 then v = i // 3
        elseif pat == 3 then v = (n - i) // 2 elseif pat == 4 then v = 7 elseif pat == 5 then v = i < n // 2 and i or n - i
        else v = (i * 7919) % 31 end
        key[i] = v
      end
      for _, tw in ipairs({ { "sort", 0 }, { "stable", 1 }, { "heap", 2 } }) do
        local r = run(key, n, tw[2])
        out[#out + 1] = tw[1] .. " " .. n .. " " .. pat .. ":" .. (#r > 0 and " " .. table.concat(r, " ") or "") .. "\n"
      end
    end
  end
  io.write(table.concat(out))
  return 0
end
