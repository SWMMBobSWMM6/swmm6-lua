-- hashcheck.lua - the operations of tests/stdcheck/hashcheck.cpp through the Lua runtime's hash tables (lua/rt/containers.lua:
-- UMap, USet, HashTable, the rehash policy, std::hash); output must equal hashcheck.cpp's: bucket counts and
-- iteration order after inserts, operator[], erases, reserve and copies, and std::hash of strings. After
-- perl/test/hashcheck.pl. Run: python3 lua/test/runlua.py lua/test/hashcheck.lua
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
return function(dir)
  local E = { CWD = "/" }
  for _, n in ipairs({ "core", "strvec", "primes", "containers", "glibm_rt", "glibm", "crt", "io" }) do
    assert(loadfile(dir .. "/rt/" .. n .. ".lua", "t"))(E)
  end
  E.inherit_all()
  local PRE = { [0] = "J", "C", "N", "OF", "P", "RG", "SUB_", "Link-", "node.", "W" }
  local s = 52024
  local function rnd() local x = s; x = x ~ (x << 13); x = x ~ (x >> 7); x = x ~ (x << 17); s = x; return x end
  local function urem(x, m)             -- C's uint64 % m
    if x >= 0 then return x % m end
    local q = ((x >> 1) // m) << 1
    local r = x - q * m
    while math.ult(m - 1, r) do r = r - m end
    return r
  end
  local function mkstr(x) return E.str_of(x) end
  local function text(x) return E.str_text(x) end
  local function name(r)
    local x = PRE[urem(r, 10)] .. tostring(urem(r >> 8, 5000))
    if urem(r >> 20, 3) == 0 then x = x .. "_" .. tostring(urem(r >> 24, 97)) end
    return mkstr(x)
  end
  local out = {}
  local function w(x) out[#out + 1] = x end
  for rd = 0, 39 do
    local m = E.NewUMap_FuncKul_FuncKKb_FuncV(nil, nil, E.MK_I)
    local mi = E.NewUMap_FuncKul_FuncKKb_FuncV(nil, nil, E.MK_I)
    local st = E.NewUSet_FuncTul_FuncTTb(nil, nil)
    local n = 1 + urem(rnd(), rd < 20 and 60 or 3000)
    if rd % 7 == 3 then m:reserve(n) end
    for i = 0, n - 1 do
      local r = rnd()
      local k = name(r)
      if urem(r, 5) == 0 then local t, kk = m:ref_Index(k); t[kk] = t[kk] + i else m:emplace_K_V(k, i) end
      mi:emplace_K_V(urem(r, 20000) - 10000, i)
      st:insert(k)
      if urem(r, 11) == 0 and not m:empty() then m:erase_K(name(rnd())) end
      if urem(r, 13) == 0 then mi:erase_K(urem(rnd(), 20000) - 10000) end
      if urem(r, 17) == 0 and not m:empty() then m:erase_MItE(m:begin()) end
    end
    local c = m:Clone()
    w("map " .. rd .. ": " .. m:bucket_count() .. " buckets " .. m:size() .. ":")
    local it = m:Items(); for j = 0, it.n - 1 do w(" " .. text(it[j].first) .. "=" .. it[j].second) end
    w("\ncopy:")
    it = c:Items(); for j = 0, it.n - 1 do w(" " .. text(it[j].first)) end
    w("\nimap " .. mi:bucket_count() .. " " .. mi:size() .. ":")
    it = mi:Items(); for j = 0, it.n - 1 do w(" " .. it[j].first .. "=" .. it[j].second) end
    w("\nset " .. st:bucket_count() .. ":")
    it = st:Items(); for j = 0, it.n - 1 do w(" " .. text(it[j])) end
    w("\n")
  end
  for _, x in ipairs({ "", "a", "abcdefg", "abcdefgh", "abcdefghi", "Junction_17", "OUTFALL-1" }) do
    local h = E.StdHash_Of_Str(mkstr(x))
    w("hash " .. x .. " " .. string.format("%u", h) .. "\n")
  end
  io.write(table.concat(out))
  return 0
end
