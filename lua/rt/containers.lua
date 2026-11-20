-- containers.lua - the C++ standard library's containers and algorithms as the engine uses them: unordered_map and
-- unordered_set with libstdc++'s node order and bucket growth (HashTable, UMap, USet, UMapC, USetC), map and set
-- (sorted arrays), stack, queue, the map iterator MIt, std::hash (_Hash_bytes), std::less, the <algorithm> functions
-- (Algo_*) and std::sort / std::stable_sort step for step (introsort as libstdc++ writes it).
-- From cs/runtime/Containers.cs and StdAlgo.cs by way of perl/cpp/containers.pl.
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and lua/README.md.
local setmetatable, getmetatable, rawequal, type, error, pairs, ipairs, next, select = setmetatable, getmetatable, rawequal, type, error, pairs, ipairs, next, select
local sbyte, ssub, spack, sunpack = string.byte, string.sub, string.pack, string.unpack
local ult, mtype, ceil = math.ult, math.type, math.ceil
local tmove, tsort = table.move, table.sort
local _ENV = ...
local newpair, newit, newptr, copy, is_icopy, elem_eq, str_text, str_of, signbit, addr_of, newA =
  newpair, newit, newptr, copy, is_icopy, elem_eq, str_text, str_of, signbit, addr_of, newA
local Str, Pair = Cpp_Str, Cpp_Pair
local NPOS = -1

local HB_MUL = 0xc6a4a7935bd1e995
local HB_SEED = 0xc70f6907

-- libstdc++'s _Hash_bytes (64-bit murmur): Lua's integers wrap as uint64_t does, and its >> is logical
function hash_bytes(s, seed)
  local ln = #s
  local h = seed ~ (ln * HB_MUL)
  local words = ln >> 3
  for w = 0, words - 1 do
    local d = sunpack("<i8", s, w * 8 + 1) * HB_MUL
    d = d ~ (d >> 47)
    d = d * HB_MUL
    h = (h ~ d) * HB_MUL
  end
  local r = ln & 7
  if r ~= 0 then
    local t = 0
    local p = words << 3
    for k = r - 1, 0, -1 do t = (t << 8) | sbyte(s, p + k + 1) end
    h = (h ~ t) * HB_MUL
  end
  h = h ~ (h >> 47)
  h = h * HB_MUL
  return h ~ (h >> 47)
end
local hash_bytes = hash_bytes
function StdHash_HashBytes(b, off, ln, seed) return hash_bytes(bytes_str(b, off, ln), seed) end
local HBC, HBCN = {}, 0
local function hash_content(cb)
  local h = HBC[cb]
  if h ~= nil then return h end
  if HBCN >= 262144 then HBC = {}; HBCN = 0 end
  h = hash_bytes(cb, HB_SEED)
  HBC[cb] = h; HBCN = HBCN + 1
  return h
end
_ENV.hash_content = hash_content
function StdHash_Of_Str(s) return hash_content(str_text(s)) end
function StdHash_Of_i(x) return x end
StdHash_Of_l = StdHash_Of_i; StdHash_Of_u = StdHash_Of_i; StdHash_Of_ul = StdHash_Of_i
local function std_hash(k)
  if type(k) ~= "table" then return k end
  if getmetatable(k) == Str then return hash_content(str_text(k)) end
  return addr_of(k)
end
_ENV.std_hash = std_hash
STD_HASH = std_hash
function StdHash_For() return std_hash end
-- the key of a node in the table's dictionary (C# keys' identity): an integer, a string's bytes ("S" and the
-- bytes), an object itself
local function dk(k)
  if type(k) ~= "table" then return k end
  if getmetatable(k) == Str then return "S" .. str_text(k) end
  return k
end
local function code_of_dk(d)
  if type(d) == "string" then return hash_content(ssub(d, 2)) end
  if type(d) == "table" then return addr_of(d) end
  return d
end
local function deq(a, b)
  if type(a) ~= "table" then
    if a == nil then return b == nil end
    return b ~= nil and (a == b or (a ~= a and b ~= b))
  end
  local mt = getmetatable(a)
  if mt == Str then return getmetatable(b) == Str and a.n == b.n and str_text(a) == str_text(b) end
  if b == nil or mt == Pair then return rawequal(a, b) end
  local eq = a.Equals
  if eq then return eq(a, b) and true or false end
  return rawequal(a, b)
end
_ENV.deq = deq
STD_EQ = deq
local Hash_ = lua_class("Hash", nil, { Cpp_ICopy })
function Hash_.op_Call(s, k) return std_hash(k) end
function Hash_.Clone(s) return setmetatable({}, Hash_) end
function Hash_.Assign(s) end
local EqualTo = lua_class("EqualTo", nil, { Cpp_ICopy })
function EqualTo.op_Call(s, a, b) return deq(a, b) end
function EqualTo.Clone(s) return setmetatable({}, EqualTo) end
function EqualTo.Assign(s) end
function NewHash() return setmetatable({}, Hash_) end
function Hash_Of(k) return std_hash(k) end
function NewEqualTo() return setmetatable({}, EqualTo) end

local function less_fn(a, b)
  if type(a) ~= "table" then
    if a == nil then return false end
    return a < b
  end
  local mt = getmetatable(a)
  if mt == Str then return cmp_(str_text(a), str_text(b)) < 0 end
  if mt == Pair then
    local x, y = a.first, b.first
    if less_fn(x, y) then return true end
    if less_fn(y, x) then return false end
    return less_fn(a.second, b.second)
  end
  if b == nil then return false end
  if a.CompareTo then return a:CompareTo(b) < 0 end
  return addr_of(a) < addr_of(b)
end
_ENV.less_fn = less_fn
LESS_FN = less_fn
Less_Fn = less_fn
local Less = lua_class("Less", nil, { Cpp_ICopy })
function Less.op_Call(s, a, b) return less_fn(a, b) end
function Less.Clone(s) return setmetatable({}, Less) end
function Less.Assign(s) end
function NewLess() return setmetatable({}, Less) end

local FAST_BKT = { [0] = 2, 2, 2, 3, 5, 5, 7, 7, 11, 11, 11, 11, 13, 13 }
local PRIMES = PRIMES
local PLAST = PRIMES.n - 1
local function prime_at_least(n, lo, hi)
  while lo < hi do
    local mid = (lo + hi) >> 1
    if ult(PRIMES[mid], n) then lo = mid + 1 else hi = mid end
  end
  return lo
end
-- code modulo the bucket count, the code read as unsigned
local function bkt(code, nb)
  if code >= 0 then return code % nb end
  return ((code >> 1) % nb * 2 + (code & 1)) % nb
end

local function key_copy(x)
  if type(x) ~= "table" then return x end
  if getmetatable(x) == Str then return x:Clone() end
  if is_icopy(x) then return x:Clone() end
  return x
end
_ENV.key_copy = key_copy
KeyCopy_Of = key_copy
local function ecopy(x)
  if type(x) ~= "table" then return x end
  if getmetatable(x) == nil then local r = { n = x.n }; for i = 0, x.n - 1 do r[i] = ecopy(x[i]) end return r end
  if is_icopy(x) then return x:Clone() end
  return x
end
_ENV.ecopy = ecopy
local KF_FIRST = function(v) return v.first end
local KF_IDENT = function(v) return v end
local PAIR_CLONE = function(v) return v:Clone() end

-- ---- the hash table: nodes { next, val, code, dk, same } in libstdc++'s singly linked order, buckets b (each the
-- node before its first node, or the before-begin node bb), a dictionary d from key (or, with a hash function of the
-- engine's, from hash code to a chain of nodes through same) to node
local HashTable = lua_class("HashTable", nil, { Cpp_ICopy })
local function ht_init(s, key, hash, eq, cache)
  s.kf = key
  s.cm = hash == nil and eq == nil
  s.hash = hash or std_hash
  s.eq = eq or deq
  s.b = { [0] = false, n = 1 }        -- false: an empty bucket
  s.bb = { next = false }
  s.cnt = 0; s.nr = 0
  s.d = {}
  if cache and not s.cm then s.pc = {}; s.nc = {}; s.ncn = 0 else s.pc = false end
  s.lck = false; s.lcode = false; s.lk = false
  return s
end
local function ht_lookup(s, k)
  if s.cm then
    local ck = dk(k)
    local n = s.d[ck]
    if n == nil then s.lck = ck end
    return n
  end
  local pc = s.pc
  local ck = false
  if pc and getmetatable(k) == Str then
    ck = str_text(k)
    local n = pc[ck]
    if n ~= nil then return n end
    if s.nc[ck] then s.lck = ck; s.lcode = false; s.lk = k; return nil end
  end
  local code = s.hash(k)
  local n = s.d[code]
  if n ~= nil then
    local eq, kf = s.eq, s.kf
    while n ~= nil and not eq(k, kf(n.val)) do n = n.same end
  end
  if ck then
    if n == nil then
      if s.ncn >= 65536 then s.nc = {}; s.ncn = 0 end
      s.nc[ck] = true; s.ncn = s.ncn + 1
    else pc[ck] = n end
  end
  if n == nil then s.lck = ck; s.lcode = code; s.lk = k end
  return n
end
local function next_bkt(s, n)
  if n < 14 then
    if n == 0 then return 1 end
    s.nr = FAST_BKT[n]
    return FAST_BKT[n]
  end
  local lo = prime_at_least(n, 6, PLAST)
  s.nr = lo == PLAST and NPOS or PRIMES[lo]
  return PRIMES[lo]
end
local function rehash_to(s, n)
  local nb = { n = n }
  for i = 0, n - 1 do nb[i] = false end
  local bb = s.bb
  local p = bb.next
  bb.next = false
  local bbeg = 0
  while p do
    local nxt = p.next
    local i = bkt(p.code, n)
    local q = nb[i]
    if not q then
      p.next = bb.next
      bb.next = p
      nb[i] = bb
      if p.next then nb[bbeg] = p end
      bbeg = i
    else
      p.next = q.next
      q.next = p
    end
    p = nxt
  end
  s.b = nb
end
local function ht_grow(s, need)
  local nr = s.nr
  local nbk = s.b.n
  local floor = nr ~= 0 and 0 or 11
  local min_bkts = need > floor and need or floor
  if min_bkts >= nbk then
    local m = min_bkts + 1
    if m < nbk * 2 then m = nbk * 2 end
    rehash_to(s, next_bkt(s, m))
  else s.nr = nbk end
end
local function ht_add(s, e)
  local code, d
  if s.cm then
    d = s.lck
    if type(d) == "table" then d = s.kf(e) end
    code = code_of_dk(d)
  else
    code = s.lcode
    if not code then code = s.hash(s.lk) end
    d = code
    s.lk = false
  end
  local n1 = s.cnt + 1
  if ult(s.nr, n1) then ht_grow(s, n1) end
  local node = { next = false, val = e, code = code, dk = d, same = false }
  local b = s.b
  local nb = b.n
  local i = bkt(code, nb)
  local before = b[i]
  if not before then
    local bb = s.bb
    local nx = bb.next
    node.next = nx
    bb.next = node
    if nx then b[bkt(nx.code, nb)] = node end
    b[i] = bb
  else
    node.next = before.next
    before.next = node
  end
  s.cnt = n1
  if s.cm then s.d[d] = node
  else
    node.same = s.d[code] or false
    s.d[code] = node
    local pc = s.pc
    if pc then
      if next(s.nc) ~= nil then s.nc = {}; s.ncn = 0 end
      local ck = s.lck
      if ck then pc[ck] = node end
    end
  end
  return node
end
local function erase_node(s, i, prev, n)
  local b = s.b
  local nb = b.n
  if rawequal(prev, b[i]) then
    local nx = n.next
    local nbk = nx and bkt(nx.code, nb) or 0
    if not nx or nbk ~= i then
      if nx then b[nbk] = b[i] end
      if rawequal(b[i], s.bb) then s.bb.next = nx end
      b[i] = false
    end
  elseif n.next then
    local nbk = bkt(n.next.code, nb)
    if nbk ~= i then b[nbk] = prev end
  end
  prev.next = n.next
  s.cnt = s.cnt - 1
  if s.cm then s.d[n.dk] = nil
  else
    local code = n.code
    local f = s.d[code]
    if rawequal(f, n) then
      if n.same then s.d[code] = n.same else s.d[code] = nil end
    else
      while not rawequal(f.same, n) do f = f.same end
      f.same = n.same
    end
    if s.pc then s.pc = {} end
  end
end
local function erase_at(s, n)
  local i = bkt(n.code, s.b.n)
  local prev = s.b[i]
  while not rawequal(prev.next, n) do prev = prev.next end
  erase_node(s, i, prev, n)
end
HashTable.EraseAt = erase_at
function HashTable.size(s) return s.cnt end
function HashTable.empty(s) return s.cnt == 0 end
function HashTable.clear(s)
  local n = s.b.n
  local nb = { n = n }
  for i = 0, n - 1 do nb[i] = false end
  s.b = nb
  s.bb.next = false; s.cnt = 0; s.d = {}
  if s.pc then s.pc = {}; s.nc = {}; s.ncn = 0 end
end
function HashTable.bucket_count(s) return s.b.n end
function HashTable.rehash(s, n)
  local m = s.cnt + 1
  if n > m then m = n end
  local want = next_bkt(s, m)
  if want ~= s.b.n then rehash_to(s, want) end
end
function HashTable.reserve(s, n) s:rehash(n) end
function HashTable.Items(s)
  local r = { n = 0 }
  local p = s.bb.next
  local k = 0
  while p do r[k] = p.val; k = k + 1; p = p.next end
  r.n = k
  return r
end
function HashTable.elems(s)
  local r = {}
  local p = s.bb.next
  local k = 0
  while p do k = k + 1; r[k] = p.val; p = p.next end
  return r, k
end
function HashTable.begin(s) return mit_node(s.bb.next or nil) end
HashTable.end_ = function(s) return MIT_END end
function HashTable.find(s, k) local n = ht_lookup(s, k); if n ~= nil then return mit_node(n) end return MIT_END end
function HashTable.count(s, k) return ht_lookup(s, k) ~= nil and 1 or 0 end
HashTable.count_ = HashTable.count
function HashTable.contains(s, k) return ht_lookup(s, k) ~= nil end
function HashTable.erase_K(s, k) local n = ht_lookup(s, k); if n == nil then return 0 end erase_at(s, n); return 1 end
function HashTable.erase_MItE(s, it) local n = it.node; local nx = n.next; erase_at(s, n); return mit_node(nx or nil) end
local function copy_from(s, o, cp)
  local nbk = o.b.n
  local b = { n = nbk }
  for i = 0, nbk - 1 do b[i] = false end
  local bb = s.bb
  bb.next = false
  s.nr = o.nr
  local cm, kf = s.cm, s.kf
  local d = {}
  local prev = bb
  local c = 0
  local p = o.bb.next
  while p do
    local v = cp and cp(p.val) or p.val
    local code = p.code
    local q = { next = false, val = v, code = code, dk = false, same = false }
    prev.next = q
    local i = bkt(code, nbk)
    if not b[i] then b[i] = prev end
    if cm then local kk = dk(kf(v)); q.dk = kk; d[kk] = q
    else q.dk = code; q.same = d[code] or false; d[code] = q end
    prev = q; c = c + 1
    p = p.next
  end
  s.b = b; s.cnt = c; s.d = d
  if s.pc then s.pc = {}; s.nc = {}; s.ncn = 0 end
end

-- ---- the map iterator: a node of a hash table, or a position in a sorted map's item list
local MIt = lua_class("MIt")
Cpp_MIt = MIt
local function mit_new(node, list, pos) return setmetatable({ node = node, list = list, pos = pos or 0 }, MIt) end
function mit_node(n) return setmetatable({ node = n, pos = 0 }, MIt) end
local mit_node = mit_node
function mit_at(l, p) return setmetatable({ list = l, pos = p }, MIt) end
local mit_at = mit_at
function MIt.Clone(s) return s end
function MIt.get_Deref(s) if s.list ~= nil then return s.list[s.pos] end return s.node.val end
local function mit_eq(a, b)
  local al, bl = a.list, b.list
  if al ~= nil or bl ~= nil then
    local pa = al ~= nil and a.pos or 0x7FFFFFFF
    local pb = bl ~= nil and b.pos or 0x7FFFFFFF
    return pa == pb
  end
  return rawequal(a.node, b.node)
end
function MIt.Equals(s, o) return isa_(o, MIt) and mit_eq(s, o) end
function MIt.GetHashCode(s) return s.pos end
MIT_END = mit_new(nil, nil, 0)
MIt_ZERO = MIT_END
MK_MIt = function() return MIT_END end
IMMUT[MK_MIt] = true
function NewMIt_HNodeE(n) return mit_node(n) end
function NewMIt_ListE_i(l, i) return mit_at(l, i) end
function MIt_op_Increment(x) if x.list ~= nil then return mit_at(x.list, x.pos + 1) end return mit_node(x.node.next or nil) end
function MIt_op_Decrement(x) return mit_at(x.list, x.pos - 1) end
function MIt_op_Eq(a, b) return mit_eq(a, b) end
function MIt_op_Ne(a, b) return not mit_eq(a, b) end

local UMap = lua_class("UMap", HashTable)
Cpp_UMap = UMap
local function umap_new(c, h, eq, mk, cache) local s = setmetatable({}, c); ht_init(s, KF_FIRST, h, eq, cache); s.mk = mk; return s end
local function makev(s) local mk = s.mk; if mk ~= nil then return mk() end return nil end
local function unode(s, k)
  local n = ht_lookup(s, k)
  if n == nil then n = ht_add(s, newpair(key_copy(k), makev(s))) end
  return n
end
function UMap.Index(s, k) return unode(s, k).val.second end
function UMap.ref_Index(s, k) return unode(s, k).val, "second" end
local function uat(s, k) local n = ht_lookup(s, k); if n == nil then error(NewOutOfRange("_Map_base::at"), 0) end return n end
function UMap.at(s, k) return uat(s, k).val.second end
function UMap.ref_at(s, k) return uat(s, k).val, "second" end
local function insert_kv(s, k, v)
  local n = ht_lookup(s, k)
  if n ~= nil then return newpair(mit_node(n), false) end
  return newpair(mit_node(ht_add(s, newpair(key_copy(k), v))), true)
end
function UMap.insert(s, p) return insert_kv(s, p.first, p.second) end
function UMap.emplace_K_V(s, k, v) return insert_kv(s, k, v) end
UMap.try_emplace_K_V = UMap.emplace_K_V
function UMap.emplace_PairKV(s, p) return insert_kv(s, p.first, p.second) end
function UMap.try_emplace_K(s, k)
  local n = ht_lookup(s, k)
  if n ~= nil then return newpair(mit_node(n), false) end
  return newpair(mit_node(ht_add(s, newpair(key_copy(k), makev(s)))), true)
end
function UMap.insert_or_assign(s, k, v)
  local n = ht_lookup(s, k)
  if n ~= nil then n.val.second = v; return newpair(mit_node(n), false) end
  return newpair(mit_node(ht_add(s, newpair(key_copy(k), v))), true)
end
function UMap._init_list(s, il) for i = 0, il.n - 1 do local p = il[i]; if ht_lookup(s, p.first) == nil then ht_add(s, p:Clone()) end end end
function UMap.Clone(s) local m = umap_new(UMap, (not s.cm) and s.hash or nil, (not s.cm) and s.eq or nil, s.mk); copy_from(m, s, PAIR_CLONE); return m end
function UMap.Assign(s, o) if not rawequal(s, o) then copy_from(s, o, PAIR_CLONE) end end
function UMap.MoveFrom(s, o) if rawequal(s, o) then return end copy_from(s, o, nil); o:clear() end
function NewUMap_FuncKul_FuncKKb_FuncV(h, eq, mk, mk2) if mk == nil then mk = mk2 end return umap_new(UMap, h, eq, mk) end
function NewUMap_PairKVA_FuncKul_FuncKKb(il, h, eq, mk) local m = umap_new(UMap, h, eq, mk); m:_init_list(il); return m end

local USet = lua_class("USet", HashTable)
Cpp_USet = USet
local function uset_new(c, h, eq, cache) local s = setmetatable({}, c); ht_init(s, KF_IDENT, h, eq, cache); return s end
function USet.insert(s, x)
  local n = ht_lookup(s, x)
  if n ~= nil then return newpair(mit_node(n), false) end
  return newpair(mit_node(ht_add(s, key_copy(x))), true)
end
USet.emplace = USet.insert
function USet._init_list(s, il) for i = 0, il.n - 1 do local x = il[i]; if ht_lookup(s, x) == nil then ht_add(s, x) end end end
function USet.Clone(s) local m = uset_new(USet, (not s.cm) and s.hash or nil, (not s.cm) and s.eq or nil); copy_from(m, s, ecopy); return m end
function USet.Assign(s, o) if not rawequal(s, o) then copy_from(s, o, ecopy) end end
function USet.MoveFrom(s, o) if rawequal(s, o) then return end copy_from(s, o, nil); o:clear() end
function NewUSet_FuncTul_FuncTTb(h, eq) return uset_new(USet, h, eq) end
function NewUSet_TA_FuncTul_FuncTTb(il, h, eq) local m = uset_new(USet, h, eq); m:_init_list(il); return m end

-- UMapC / USetC: keyed with the engine's case-insensitive hash and equality (the one engine class implementing
-- IHashFn and the one implementing IBinFn)
local StdEq = lua_class("StdEq", nil, { Cpp_IBinFn, Cpp_ICopy })
function StdEq.Call2(s, a, b) return deq(a, b) end
function StdEq.Clone(s) return setmetatable({}, StdEq) end
function StdEq.Assign(s) end
function NewStdEq() return setmetatable({}, StdEq) end
local ENGINE_FNS
function engine_fns()
  if ENGINE_FNS then return ENGINE_FNS end
  local h, e = {}, {}
  for _, c in ipairs(ENGINE_CLASSES or {}) do
    local isa = c.__isa
    if isa[Cpp_IHashFn] then h[#h + 1] = c end
    if isa[Cpp_IBinFn] and c ~= StdEq then e[#e + 1] = c end
  end
  local function pick(l, nm)
    if #l == 1 then return l[1] end
    local m = {}
    for _, c in ipairs(l) do if c.__name:sub(-#nm) == nm then m[#m + 1] = c end end
    if #m == 1 then return m[1] end
    error("Cpp.UMapC: cannot tell which hash or equality class is meant")
  end
  local hc, ec = pick(h, "CiHash"), pick(e, "CiEqual")
  local ho, eo = hc._new(), ec._new()
  ENGINE_FNS = { function(k) return ho:HashOf(k) end, function(a, b) return eo:Call2(a, b) end }
  return ENGINE_FNS
end
local UMapC = lua_class("UMapC", UMap)
local function umapc_new(mk, fns) fns = fns or engine_fns(); return umap_new(UMapC, fns[1], fns[2], mk, true) end
function UMapC.Clone(s) local m = umapc_new(s.mk, { s.hash, s.eq }); copy_from(m, s, PAIR_CLONE); return m end
function NewUMapC_FuncV(mk, mk2) if mk == nil then mk = mk2 end return umapc_new(mk) end
function NewUMapC_PairKVA(il, mk) local m = umapc_new(mk); m:_init_list(il); return m end
local USetC = lua_class("USetC", USet)
local function usetc_new(fns) fns = fns or engine_fns(); return uset_new(USetC, fns[1], fns[2], true) end
function USetC.Clone(s) local m = usetc_new({ s.hash, s.eq }); copy_from(m, s, ecopy); return m end
function NewUSetC() return usetc_new() end
function NewUSetC_TA(il) local m = usetc_new(); m:_init_list(il); return m end

-- ---- map and set: sorted item lists (0 .. n - 1); with std::less on strings or numbers a parallel list of sort keys
-- (kt "s" for byte strings, "n" for numbers) is bisected instead of calling the comparison
local function sk(k)
  if type(k) ~= "table" then
    if k ~= nil and k == k then return "n", k end
    return nil, nil
  end
  if getmetatable(k) == Str then return "s", str_text(k) end
  return nil, nil
end
local SortedBase = lua_class("SortedBase", nil, { Cpp_ICopy })
local function kof_ident(x) return x end
local function kof_first(x) return x.first end
local function sb_lower(s, k)
  local keys = s.keys
  if keys then
    local t, ck = sk(k)
    if t ~= nil and (s.kt == nil or s.kt == t) then
      if s.kt == nil then s.kt = t end
      local lo, hi = 0, keys.n
      while lo < hi do
        local mid = (lo + hi) >> 1
        if keys[mid] < ck then lo = mid + 1 else hi = mid end
      end
      return lo, ck
    end
    s.keys = false
  end
  local lt, items, kof = s.lt, s.items, s.kof
  local lo, hi = 0, items.n
  while lo < hi do
    local mid = (lo + hi) >> 1
    if lt(kof(items[mid]), k) then lo = mid + 1 else hi = mid end
  end
  return lo, nil
end
local function at_key(s, i, k, ck)
  if i >= s.items.n then return false end
  if ck ~= nil then return not (ck < s.keys[i]) end
  return not s.lt(k, s.kof(s.items[i]))
end
local function lput(l, i, x) local n = l.n; if i < n then tmove(l, i, n - 1, i + 1) end l[i] = x; l.n = n + 1 end
local function ldel(l, i) local n = l.n; tmove(l, i + 1, n - 1, i); l[n - 1] = nil; l.n = n - 1 end
local function sb_put(s, i, ck, p) lput(s.items, i, p); if s.keys then lput(s.keys, i, ck) end end
local function sb_del(s, i) ldel(s.items, i); if s.keys then ldel(s.keys, i) end end
local function sb_find(s, k) local i, ck = sb_lower(s, k); if at_key(s, i, k, ck) then return i end return -1 end
local function is_std(s) return rawequal(s.lt, less_fn) end
function SortedBase.size(s) return s.items.n end
function SortedBase.empty(s) return s.items.n == 0 end
function SortedBase.clear(s) s.items = { n = 0 }; s.keys = is_std(s) and { n = 0 } or false; s.kt = nil end
function SortedBase.begin(s) return mit_at(s.items, 0) end
SortedBase.end_ = function(s) return mit_at(s.items, s.items.n) end
function SortedBase.Items(s) return s.items end
function SortedBase.elems(s) local r = {}; local n = s.items.n; if n > 0 then tmove(s.items, 0, n - 1, 1, r) end return r, n end
function SortedBase.count(s, k) return sb_find(s, k) >= 0 and 1 or 0 end
function SortedBase.contains(s, k) return sb_find(s, k) >= 0 end
function SortedBase.find(s, k) local i = sb_find(s, k); return mit_at(s.items, i < 0 and s.items.n or i) end
function SortedBase.lower_bound(s, k) local i = sb_lower(s, k); return mit_at(s.items, i) end
function SortedBase.upper_bound(s, k) local i, ck = sb_lower(s, k); while at_key(s, i, k, ck) do i = i + 1 end return mit_at(s.items, i) end
local function keys_of(s, o)
  if o.keys and is_std(s) then local r = { n = o.keys.n }; if r.n > 0 then tmove(o.keys, 0, r.n - 1, 0, r) end return r end
  return false
end
local function clone_list(l, f) local r = { n = l.n }; for i = 0, l.n - 1 do r[i] = f(l[i]) end return r end

local Map = lua_class("Map", SortedBase)
Cpp_Map = Map
local function map_new(less, mk)
  less = less or less_fn
  return setmetatable({ lt = less, items = { n = 0 }, keys = rawequal(less, less_fn) and { n = 0 } or false, kt = nil, mk = mk, kof = kof_first }, Map)
end
local function map_index(s, k)
  local i, ck = sb_lower(s, k)
  if not at_key(s, i, k, ck) then sb_put(s, i, ck, newpair(key_copy(k), s.mk ~= nil and s.mk() or nil)) end
  return s.items[i]
end
function Map.Index(s, k) return map_index(s, k).second end
function Map.ref_Index(s, k) return map_index(s, k), "second" end
function Map.at(s, k) local i = sb_find(s, k); if i < 0 then error(NewOutOfRange("map::at"), 0) end return s.items[i].second end
function Map.ref_at(s, k) local i = sb_find(s, k); if i < 0 then error(NewOutOfRange("map::at"), 0) end return s.items[i], "second" end
function Map.insert(s, p)
  local i, ck = sb_lower(s, p.first)
  if at_key(s, i, p.first, ck) then return newpair(mit_at(s.items, i), false) end
  sb_put(s, i, ck, newpair(key_copy(p.first), p.second))
  return newpair(mit_at(s.items, i), true)
end
function Map.emplace_K_V(s, k, v) return s:insert(newpair(k, v)) end
Map.try_emplace_K_V = Map.emplace_K_V
function Map.emplace_PairKV(s, p) return s:insert(p) end
function Map.insert_or_assign(s, k, v)
  local i = sb_find(s, k)
  if i >= 0 then s.items[i].second = v; return newpair(mit_at(s.items, i), false) end
  return s:insert(newpair(k, v))
end
function Map.erase_K(s, k) local i = sb_find(s, k); if i < 0 then return 0 end sb_del(s, i); return 1 end
function Map.erase_MItPairKV(s, it) sb_del(s, it.pos); return mit_at(s.items, it.pos) end
Map.erase_MItE = Map.erase_MItPairKV
function Map.Clone(s) local m = map_new(s.lt, s.mk); m.items = clone_list(s.items, PAIR_CLONE); m.keys = keys_of(m, s); m.kt = s.kt; return m end
function Map.Assign(s, o) if rawequal(s, o) then return end s.items = clone_list(o.items, PAIR_CLONE); s.keys = keys_of(s, o); s.kt = o.kt end
function Map.MoveFrom(s, o)
  if rawequal(s, o) then return end
  s.items = o.items; s.keys = keys_of(s, o); s.kt = o.kt
  o.items = { n = 0 }; o.keys = is_std(o) and { n = 0 } or false; o.kt = nil
end
function NewMap_FuncKKb_FuncV(less, mk, mk2) if mk == nil then mk = mk2 end return map_new(less, mk) end
function NewMap_PairKVA_FuncKKb(il, less, mk) local m = map_new(less, mk); for i = 0, il.n - 1 do m:insert(il[i]:Clone()) end return m end

local Set_ = lua_class("Set", SortedBase)
Cpp_Set = Set_
local function set_new(less)
  less = less or less_fn
  return setmetatable({ lt = less, items = { n = 0 }, keys = rawequal(less, less_fn) and { n = 0 } or false, kt = nil, kof = kof_ident }, Set_)
end
function Set_.insert(s, x)
  local i, ck = sb_lower(s, x)
  if at_key(s, i, x, ck) then return newpair(mit_at(s.items, i), false) end
  sb_put(s, i, ck, key_copy(x))
  return newpair(mit_at(s.items, i), true)
end
Set_.emplace = Set_.insert
function Set_.erase_T(s, k) local i = sb_find(s, k); if i < 0 then return 0 end sb_del(s, i); return 1 end
function Set_.erase_MItT(s, it) sb_del(s, it.pos); return mit_at(s.items, it.pos) end
function Set_.Clone(s) local m = set_new(s.lt); m.items = clone_list(s.items, ecopy); m.keys = keys_of(m, s); m.kt = s.kt; return m end
function Set_.Assign(s, o) if rawequal(s, o) then return end s.items = clone_list(o.items, ecopy); s.keys = keys_of(s, o); s.kt = o.kt end
function Set_.MoveFrom(s, o)
  if rawequal(s, o) then return end
  s.items = o.items; s.keys = keys_of(s, o); s.kt = o.kt
  o.items = { n = 0 }; o.keys = is_std(o) and { n = 0 } or false; o.kt = nil
end
function NewSet_FuncTTb(less) return set_new(less) end
function NewSet_TA_FuncTTb(il, less) local m = set_new(less); for i = 0, il.n - 1 do m:insert(il[i]) end return m end

local Stk = lua_class("Stk", nil, { Cpp_ICopy })
function Stk.push(s, x) local it = s.items; it.n = it.n + 1; it[it.n - 1] = x end
function Stk.pop(s) local it = s.items; it.n = it.n - 1; it[it.n] = nil end
function Stk.top(s) return s.items[s.items.n - 1] end
function Stk.ref_top(s) return s.items, s.items.n - 1 end
function Stk.empty(s) return s.items.n == 0 end
function Stk.size(s) return s.items.n end
function Stk.Clone(s) return setmetatable({ items = clone_list(s.items, ecopy) }, Stk) end
function Stk.Assign(s, o) if not rawequal(s, o) then s.items = clone_list(o.items, ecopy) end end
function Stk.MoveFrom(s, o) if rawequal(s, o) then return end s.items = o.items; o.items = { n = 0 } end
function NewStk() return setmetatable({ items = { n = 0 } }, Stk) end

local Que = lua_class("Que", nil, { Cpp_ICopy })
function Que.push(s, x) local it = s.items; it[it.n] = x; it.n = it.n + 1 end
function Que.pop(s)
  local it = s.items
  it[s.head] = nil
  s.head = s.head + 1
  if s.head > 64 and s.head * 2 > it.n then
    local m = it.n - s.head
    local r = { n = m }
    if m > 0 then tmove(it, s.head, it.n - 1, 0, r) end
    s.items = r; s.head = 0
  end
end
function Que.front(s) return s.items[s.head] end
function Que.ref_front(s) return s.items, s.head end
function Que.back(s) return s.items[s.items.n - 1] end
function Que.ref_back(s) return s.items, s.items.n - 1 end
function Que.empty(s) return s.items.n == s.head end
function Que.size(s) return s.items.n - s.head end
local function que_rest(s) local it = s.items; local r = { n = it.n - s.head }; for i = s.head, it.n - 1 do r[i - s.head] = ecopy(it[i]) end return r end
function Que.Clone(s) return setmetatable({ items = que_rest(s), head = 0 }, Que) end
function Que.Assign(s, o) if rawequal(s, o) then return end s.items = que_rest(o); s.head = 0 end
function Que.MoveFrom(s, o)
  if rawequal(s, o) then return end
  local it = o.items
  local r = { n = it.n - o.head }
  for i = o.head, it.n - 1 do r[i - o.head] = it[i] end
  s.items = r; s.head = 0; o.items = { n = 0 }; o.head = 0
end
function NewQue() return setmetatable({ items = { n = 0 }, head = 0 }, Que) end

-- ------------------------------------------------------------------------------------------------ <algorithm>
local function iadd(b, n) local v = b.v; if v ~= nil then return newit(v, v.a, b.i + n) end return newit(nil, b.a, b.i + n) end
local function fill_into(a, i0, n, v, cp)
  if n <= 0 then return end
  if not cp then for i = i0, i0 + n - 1 do a[i] = v end
  else for i = i0, i0 + n - 1 do a[i] = ecopy(v) end end
end
local function copy_into(src, s0, n, dst, d0, cp)
  if n <= 0 then return end
  local seg = {}
  for i = 0, n - 1 do seg[i] = src[s0 + i] end
  for i = 0, n - 1 do local x = seg[i]; if cp then x = ecopy(x) end dst[d0 + i] = x end
end
local PLT = function(a, b) return a < b end
_ENV.PLT = PLT
local function lower_bound(b, e, v, lt)
  local a = b.a; local first = b.i; local ln = e.i - first
  while ln > 0 do
    local half = ln >> 1
    local mid = first + half
    if lt(a[mid], v) then first = mid + 1; ln = ln - half - 1 else ln = half end
  end
  return iadd(b, first - b.i)
end
local function upper_bound(b, e, v, lt)
  local a = b.a; local first = b.i; local ln = e.i - first
  while ln > 0 do
    local half = ln >> 1
    local mid = first + half
    if lt(v, a[mid]) then ln = half else first = mid + 1; ln = ln - half - 1 end
  end
  return iadd(b, first - b.i)
end
local function unique(b, e, eq)
  if b.i == e.i then return e end
  local a = b.a; local first = b.i; local last = e.i; local nxt = first + 1
  while nxt ~= last do
    if eq(a[first], a[nxt]) then break end
    first = nxt; nxt = nxt + 1
  end
  if nxt == last then return e end
  local dest = first
  first = nxt + 1
  while first ~= last do
    if not eq(a[dest], a[first]) then dest = dest + 1; a[dest] = a[first] end
    first = first + 1
  end
  return iadd(b, dest + 1 - b.i)
end
local function vec_of(c, src, items)
  if c == "O" then
    local mk = src.v ~= nil and src.v.mk or nil
    local v = NewVec(mk or MK_N); v.a = items; v.n = items.n
    return v
  end
  return setmetatable({ a = items, n = items.n }, VEC_CLASSES[c])
end
for _, c in ipairs({ "O", "D", "F", "I", "L", "B", "S", "C", "Z" }) do
  local cp = c == "O"
  local eq = c == "O" and deq or ((c == "D" or c == "F") and function(x, y) return x == y or (x ~= x and y ~= y) end or function(x, y) return x == y end)
  local lt0 = c == "O" and less_fn or PLT
  local function nm(n) if c == "O" then return n end return n .. "__" .. c end
  _ENV[nm("Algo_fill_IterT_IterT_T")] = function(b, e, v) fill_into(b.a, b.i, e.i - b.i, v, cp) end
  _ENV[nm("Algo_fill_PtrT_PtrT_T")] = function(b, e, v) fill_into(b.a, b.o, e.o - b.o, v, cp) end
  _ENV[nm("Algo_fill_n_IterT_ul_T")] = function(b, n, v) fill_into(b.a, b.i, n, v, cp); return iadd(b, n) end
  _ENV[nm("Algo_fill_n_PtrT_ul_T")] = function(b, n, v) fill_into(b.a, b.o, n, v, cp); return b:add(n) end
  _ENV[nm("Algo_any_of")] = function(b, e, f) local a = b.a; for i = b.i, e.i - 1 do if f(a[i]) then return true end end return false end
  _ENV[nm("Algo_all_of")] = function(b, e, f) local a = b.a; for i = b.i, e.i - 1 do if not f(a[i]) then return false end end return true end
  _ENV[nm("Algo_none_of")] = function(b, e, f) local a = b.a; for i = b.i, e.i - 1 do if f(a[i]) then return false end end return true end
  _ENV[nm("Algo_find")] = function(b, e, v) local a = b.a; for i = b.i, e.i - 1 do if eq(a[i], v) then return iadd(b, i - b.i) end end return e end
  _ENV[nm("Algo_find_if")] = function(b, e, f) local a = b.a; for i = b.i, e.i - 1 do if f(a[i]) then return iadd(b, i - b.i) end end return e end
  _ENV[nm("Algo_find_if_not")] = function(b, e, f) local a = b.a; for i = b.i, e.i - 1 do if not f(a[i]) then return iadd(b, i - b.i) end end return e end
  _ENV[nm("Algo_count")] = function(b, e, v) local a = b.a; local n = 0; for i = b.i, e.i - 1 do if eq(a[i], v) then n = n + 1 end end return n end
  _ENV[nm("Algo_count_if")] = function(b, e, f) local a = b.a; local n = 0; for i = b.i, e.i - 1 do if f(a[i]) then n = n + 1 end end return n end
  _ENV[nm("Algo_lower_bound_IterT_IterT_T")] = function(b, e, v) return lower_bound(b, e, v, lt0) end
  _ENV[nm("Algo_lower_bound_IterT_IterT_T_FuncTTb")] = lower_bound
  _ENV[nm("Algo_upper_bound_IterT_IterT_T")] = function(b, e, v) return upper_bound(b, e, v, lt0) end
  _ENV[nm("Algo_upper_bound_IterT_IterT_T_FuncTTb")] = upper_bound
  _ENV[nm("Algo_binary_search")] = function(b, e, v) local f = lower_bound(b, e, v, lt0).i; return f ~= e.i and not lt0(v, b.a[f]) end
  _ENV[nm("Algo_is_sorted_IterT_IterT")] = function(b, e) local a = b.a; for i = b.i + 1, e.i - 1 do if lt0(a[i], a[i - 1]) then return false end end return true end
  _ENV[nm("Algo_unique_IterT_IterT")] = function(b, e) return unique(b, e, eq) end
  _ENV[nm("Algo_max_element_IterT_IterT")] = function(b, e)
    if b.i == e.i then return e end
    local a = b.a; local best = b.i
    for i = b.i + 1, e.i - 1 do if lt0(a[best], a[i]) then best = i end end
    return iadd(b, best - b.i)
  end
  _ENV[nm("Algo_min_element_IterT_IterT")] = function(b, e)
    if b.i == e.i then return e end
    local a = b.a; local best = b.i
    for i = b.i + 1, e.i - 1 do if lt0(a[i], a[best]) then best = i end end
    return iadd(b, best - b.i)
  end
  _ENV[nm("Algo_copy_IterT_IterT_IterT")] = function(b, e, o) local n = e.i - b.i; copy_into(b.a, b.i, n, o.a, o.i, cp); return iadd(o, n) end
  _ENV[nm("Algo_copy_IterT_IterT_PtrT")] = function(b, e, o) local n = e.i - b.i; copy_into(b.a, b.i, n, o.a, o.o, cp); return o:add(n) end
  _ENV[nm("Algo_copy_PtrT_PtrT_PtrT")] = function(b, e, o) local n = e.o - b.o; copy_into(b.a, b.o, n, o.a, o.o, cp); return o:add(n) end
  _ENV[nm("Algo_copy_n_PtrT_ul_PtrT")] = function(b, n, o) copy_into(b.a, b.o, n, o.a, o.o, cp); return o:add(n) end
  _ENV[nm("Algo_copy_n_IterT_ul_IterT")] = function(b, n, o) copy_into(b.a, b.i, n, o.a, o.i, cp); return iadd(o, n) end
  _ENV[nm("Algo_replace")] = function(b, e, old, nw) local a = b.a; for i = b.i, e.i - 1 do if eq(a[i], old) then a[i] = nw end end end
  _ENV[nm("Algo_VecFrom")] = function(b, e)
    local n = e.i - b.i
    local seg = { n = n }
    for i = 0, n - 1 do local x = b.a[b.i + i]; if cp then x = ecopy(x) end seg[i] = x end
    return vec_of(c, b, seg)
  end
  _ENV[nm("Algo_begin_TA")] = function(a) return newit(nil, a, 0) end
  _ENV[nm("Algo_end_TA")] = function(a) return newit(nil, a, a.n) end
  for _, c2 in ipairs({ "O", "D", "F", "I", "L", "B", "S", "C", "Z" }) do
    local n2 = (c == "O" and c2 == "O") and "" or ("__" .. c .. c2)
    _ENV["Algo_lower_bound_IterT_IterT_V_FuncTVb" .. n2] = lower_bound
    _ENV["Algo_upper_bound_IterT_IterT_V_FuncVTb" .. n2] = upper_bound
    _ENV["Algo_transform_IterT_IterT_IterU_FuncTU" .. n2] = function(b, e, o, f)
      local a, oa = b.a, o.a
      local d = o.i - b.i
      for i = b.i, e.i - 1 do oa[i + d] = f(a[i]) end
      return iadd(o, e.i - b.i)
    end
  end
end
function Algo_accumulate_Iterd_Iterd_d(b, e, init) local a = b.a; for i = b.i, e.i - 1 do init = init + a[i] end return init end
function Algo_transform_Iteruc_Iteruc_Iteruc_Funcucc(b, e, o, f)
  local a, oa = b.a, o.a
  local d = o.i - b.i
  for i = b.i, e.i - 1 do oa[i + d] = f(a[i]) & 255 end
  return iadd(o, e.i - b.i)
end
Algo_transform_Iteruc_Iteruc_Iteruc_Funcuci = Algo_transform_Iteruc_Iteruc_Iteruc_Funcucc
function Algo_iota_Iteri_Iteri_i(b, e, v) local a = b.a; for i = b.i, e.i - 1 do a[i] = v; v = ((v + 1 + 0x80000000) & 0xFFFFFFFF) - 0x80000000 end end
function Algo_iota_Iterul_Iterul_ul(b, e, v) local a = b.a; for i = b.i, e.i - 1 do a[i] = v; v = v + 1 end end

-- ------------------------------------------------------------------------------------------------ std::sort
local THRESHOLD = 16
local function bit_length(n) local b = 0; while n ~= 0 do b = b + 1; n = n >> 1 end return b end
local adjust_heap, make_heap, sort_heap, heap_select, partial_sort, insertion_sort, final_insertion_sort, introsort_loop
function adjust_heap(a, first, hole, ln, value, comp)
  local top = hole
  local second = hole
  local lim = ln >= 1 and (ln - 1) // 2 or 0
  while second < lim do
    second = 2 * (second + 1)
    if comp(a[first + second], a[first + (second - 1)]) then second = second - 1 end
    a[first + hole] = a[first + second]
    hole = second
  end
  if (ln & 1) == 0 and second == (ln - 2) // 2 then
    second = 2 * (second + 1)
    a[first + hole] = a[first + (second - 1)]
    hole = second - 1
  end
  local parent = (hole - 1) // 2
  while hole > top and comp(a[first + parent], value) do
    a[first + hole] = a[first + parent]
    hole = parent
    parent = (hole - 1) // 2
  end
  a[first + hole] = value
end
function make_heap(a, first, last, comp)
  if last - first < 2 then return end
  local ln = last - first
  local parent = (ln - 2) // 2
  while true do
    adjust_heap(a, first, parent, ln, a[first + parent], comp)
    if parent == 0 then return end
    parent = parent - 1
  end
end
function sort_heap(a, first, last, comp)
  while last - first > 1 do
    last = last - 1
    local value = a[last]
    a[last] = a[first]
    adjust_heap(a, first, 0, last - first, value, comp)
  end
end
function heap_select(a, first, middle, last, comp)
  make_heap(a, first, middle, comp)
  for i = middle, last - 1 do
    if comp(a[i], a[first]) then
      local value = a[i]
      a[i] = a[first]
      adjust_heap(a, first, 0, middle - first, value, comp)
    end
  end
end
function partial_sort(a, first, middle, last, comp) heap_select(a, first, middle, last, comp); sort_heap(a, first, middle, comp) end
function insertion_sort(a, first, last, comp)
  if first == last then return end
  for i = first + 1, last - 1 do
    local val = a[i]
    if comp(val, a[first]) then
      tmove(a, first, i - 1, first + 1)
      a[first] = val
    else
      local nxt = i - 1
      while comp(val, a[nxt]) do a[nxt + 1] = a[nxt]; nxt = nxt - 1 end
      a[nxt + 1] = val
    end
  end
end
function final_insertion_sort(a, first, last, comp)
  if last - first > THRESHOLD then
    insertion_sort(a, first, first + THRESHOLD, comp)
    for i = first + THRESHOLD, last - 1 do
      local val = a[i]
      local nxt = i - 1
      while comp(val, a[nxt]) do a[nxt + 1] = a[nxt]; nxt = nxt - 1 end
      a[nxt + 1] = val
    end
  else insertion_sort(a, first, last, comp) end
end
function introsort_loop(a, first, last, depth, comp)
  while last - first > THRESHOLD do
    if depth == 0 then partial_sort(a, first, last, last, comp); return end
    depth = depth - 1
    local mid = first + (last - first) // 2
    local ia, ic = first + 1, last - 1
    local xa, xb, xc = a[ia], a[mid], a[ic]
    local j
    if comp(xa, xb) then
      if comp(xb, xc) then j = mid elseif comp(xa, xc) then j = ic else j = ia end
    else
      if comp(xa, xc) then j = ia elseif comp(xb, xc) then j = ic else j = mid end
    end
    local pv = a[j]; a[j] = a[first]; a[first] = pv
    local lo, hi = ia, last
    while true do
      while comp(a[lo], pv) do lo = lo + 1 end
      hi = hi - 1
      while comp(pv, a[hi]) do hi = hi - 1 end
      if not (lo < hi) then break end
      a[lo], a[hi] = a[hi], a[lo]
      lo = lo + 1
    end
    introsort_loop(a, lo, last, depth, comp)
    last = lo
  end
end
local function sort_(a, first, last, comp)
  if first == last then return end
  introsort_loop(a, first, last, (bit_length(last - first) - 1) * 2, comp)
  final_insertion_sort(a, first, last, comp)
end
local function merge_sort(a, lo, hi, buf, comp)
  if hi - lo < 2 then return end
  local mid = lo + (hi - lo) // 2
  merge_sort(a, lo, mid, buf, comp)
  merge_sort(a, mid, hi, buf, comp)
  local i, j, k = lo, mid, 0
  while i < mid and j < hi do
    local y, x = a[j], a[i]
    if comp(y, x) then buf[k] = y; k = k + 1; j = j + 1 else buf[k] = x; k = k + 1; i = i + 1 end
  end
  while i < mid do buf[k] = a[i]; k = k + 1; i = i + 1 end
  while j < hi do buf[k] = a[j]; k = k + 1; j = j + 1 end
  tmove(buf, 0, k - 1, lo, a)
end
local function stable_sort(a, first, last, comp) if last - first < 2 then return end merge_sort(a, first, last, {}, comp) end
local function plain_doubles(a, f, l)
  local zs = 0
  for i = f, l - 1 do
    local x = a[i]
    if x ~= x then return false end
    if x == 0 then zs = zs | (signbit(x) and 2 or 1) end
  end
  return zs ~= 3
end
-- numbers in a total order with no two equal values told apart: any correct sort leaves them as libstdc++ does
local function plain_sort(a, f, l)
  local t = {}
  tmove(a, f, l - 1, 1, t)
  tsort(t)
  tmove(t, 1, l - f, f, a)
end
function StdAlgo_Sort(a, f, l, comp) if l - f < 2 then return end sort_(a, f, l, comp) end
function StdAlgo_StableSort(a, f, l, comp) if l - f < 2 then return end stable_sort(a, f, l, comp) end
function StdAlgo_PartialSort(a, f, m, l, comp) partial_sort(a, f, m, l, comp) end
local function int_sort(a, f, l, comp, stable)
  if l - f < 2 then return end
  if rawequal(comp, less_fn) then plain_sort(a, f, l)
  elseif stable then stable_sort(a, f, l, comp) else sort_(a, f, l, comp) end
end
local function dbl_sort(a, f, l, comp, stable)
  if l - f < 2 then return end
  if rawequal(comp, less_fn) then
    if plain_doubles(a, f, l) then plain_sort(a, f, l); return end
    comp = PLT
  end
  if stable then stable_sort(a, f, l, comp) else sort_(a, f, l, comp) end
end
for _, c in ipairs({ "D", "F" }) do
  _ENV["StdAlgo_Sort__" .. c] = function(a, f, l, comp) dbl_sort(a, f, l, comp, false) end
  _ENV["StdAlgo_StableSort__" .. c] = function(a, f, l, comp) dbl_sort(a, f, l, comp, true) end
end
for _, c in ipairs({ "I", "L", "B", "S", "C" }) do
  _ENV["StdAlgo_Sort__" .. c] = function(a, f, l, comp) int_sort(a, f, l, comp, false) end
  _ENV["StdAlgo_StableSort__" .. c] = function(a, f, l, comp) int_sort(a, f, l, comp, true) end
end
StdAlgo_Sort__Z = StdAlgo_Sort; StdAlgo_StableSort__Z = StdAlgo_StableSort
for _, c in ipairs({ "D", "F", "I", "L", "B", "S", "C", "Z" }) do
  _ENV["StdAlgo_PartialSort__" .. c] = function(a, f, m, l, comp) partial_sort(a, f, m, l, rawequal(comp, less_fn) and PLT or comp) end
end
