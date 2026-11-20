-- strvec.lua - std::string (Str), the C++ exceptions, std::vector (Vec, VecD, VecI, ...), std::optional (Opt),
-- std::pair (Pair), std::min/max (M), the array helpers (Arr), destructors, Defer and moves (Mv) of the Lua runtime.
-- From cs/runtime/Str.cs, Std.cs and Misc.cs by way of perl/cpp/strvec.pl.
-- A Str is { b = bytes (0..255 at 0 .. n - 1, room for a NUL; b.n is the room), n = length }; a vector is
-- { a = elements (a.n is the capacity, grown as libstdc++ grows it), n = count }; slots past n hold the default.
-- A size_t is a Lua integer read as unsigned: npos is -1 (0xFFFFFFFFFFFFFFFF), compared with math.ult.
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and lua/README.md.
local setmetatable, getmetatable, rawequal, type, error, pairs, ipairs, tostring, select = setmetatable, getmetatable, rawequal, type, error, pairs, ipairs, tostring, select
local schar, sbyte, sfind, ssub, srep, sformat = string.char, string.byte, string.find, string.sub, string.rep, string.format
local ult, mtype, math = math.ult, math.type, math
local tmove, tunpack, tconcat = table.move, table.unpack, table.concat
local _ENV = ...
local newcp, newptr, newit, newrit, isa_, copy, deep, is_icopy, made, elem_eq, elem_less, bytes_str, str_bytes, zfind, cbs =
  newcp, newptr, newit, newrit, isa_, copy, deep, is_icopy, made, elem_eq, elem_less, bytes_str, str_bytes, zfind, cbs
local IMMUT, newA = IMMUT, newA
local NPOS = -1
NPOS_ = NPOS
Str_npos = NPOS

-- the bytes of a C string at a CPtr (a new table at 0 .. m - 1, n = m), and those of a range of a buffer
local function cb(p)
  local b, o = p.B, p.O
  local e = zfind(b, o)
  local r = { n = e - o }
  for i = o, e - 1 do r[i - o] = b[i] & 255 end
  return r
end
_ENV.cb = cb
function buf_bytes(b, o, m)
  if o < 0 or o + m > b.n then error(NewSysException("IndexOutOfRangeException", "cpp: byte range " .. o .. "+" .. m .. " outside a buffer"), 0) end
  local r = { n = m }
  for i = 0, m - 1 do r[i] = b[o + i] & 255 end
  return r
end
local buf_bytes = buf_bytes

-- ------------------------------------------------------------------------------------------------ Str
local Str = lua_class("Str", nil, { Cpp_ICopy })
Cpp_Str = Str
local function over(b, n) return setmetatable({ b = b, n = n }, Str) end
_ENV.str_over = over
-- a byte table (0 .. m - 1) with a NUL after it, as a Str's own bytes
local function own(src, m)
  local b = { n = m + 1 }
  if m > 0 then tmove(src, 0, m - 1, 0, b) end
  b[m] = 0
  return b
end
local function newstr() local b = { n = 16 }; for i = 0, 15 do b[i] = 0 end return over(b, 0) end
local function reserve(s, need)
  local b = s.b
  local lb = b.n
  if need + 1 <= lb then return b end
  local cap = lb * 2
  if cap < need + 1 then cap = need + 1 end
  for i = lb, cap - 1 do b[i] = 0 end
  b.n = cap
  return b
end
-- a Lua string as a Str
local function str_of(s)
  local b = str_bytes(s, true)
  return over(b, #s)
end
_ENV.str_of = str_of
local function text(s) return bytes_str(s.b, 0, s.n) end
_ENV.str_text = text

function Str.size(s) return s.n end
Str.length = Str.size
function Str.empty(s) return s.n == 0 end
function Str.clear(s) s.n = 0 end
function Str.c_str(s) local n = s.n; if n + 1 > s.b.n then reserve(s, n) end s.b[n] = 0; return newcp(s.b, 0) end
Str.data = Str.c_str
function Str.at(s, i)
  if not ult(i, s.n) then error(NewOutOfRange("basic_string::at: __n (which is " .. sformat("%u", i) .. ") >= this->size() (which is " .. s.n .. ")"), 0) end
  return s.b[i]
end
function Str.front(s) return s.b[0] end
function Str.back(s) return s.b[s.n - 1] end
function Str.ref_front(s) return s.b, 0 end
function Str.ref_back(s) return s.b, s.n - 1 end
function Str.get_Item(s, i) return s.b[i] end
function Str.set_Item(s, i, v) s.b[i] = v & 255 end
function Str.ref_Item(s, i) return s.b, i end
Str.get_Item_ul = Str.get_Item; Str.get_Item_l = Str.get_Item; Str.get_Item_i = Str.get_Item
Str.set_Item_ul = Str.set_Item; Str.set_Item_l = Str.set_Item; Str.set_Item_i = Str.set_Item
Str.ref_Item_ul = Str.ref_Item; Str.ref_Item_l = Str.ref_Item; Str.ref_Item_i = Str.ref_Item
function Str.Char(s, i) local x = s.b[i]; if x > 127 then x = x - 256 end return x end
function Str.text(s) return text(s) end
function Str.Clone(s) return over(own(s.b, s.n), s.n) end
function Str.Assign_Str(s, o)
  if rawequal(s, o) then return end
  local m = o.n
  local b = s.b
  if m + 1 > b.n then b = reserve(s, m) end
  if m > 0 then tmove(o.b, 0, m - 1, 0, b) end
  s.n = m
end
Str.Assign = Str.Assign_Str
function Str.Assign_CPtr(s, p) local src = cb(p); s.b = own(src, src.n); s.n = src.n end
function Str.Assign_i(s, ch) local b = s.b; if b.n < 2 then b = reserve(s, 1) end b[0] = ch & 255; s.n = 1 end
function Str.MoveFrom(s, o)
  if rawequal(s, o) then return end
  s.b = o.b; s.n = o.n
  local b = { n = 16 }; for i = 0, 15 do b[i] = 0 end
  o.b = b; o.n = 0
end
Str.MoveFrom_Str = Str.MoveFrom
function Str.assign_Str(s, o) s:Assign_Str(o); return s end
function Str.assign_CPtr(s, p) s:Assign_CPtr(p); return s end
function Str.assign_CPtr_ul(s, p, ln)
  local src = ln ~= 0 and buf_bytes(p.B, p.O, ln) or { n = 0 }
  s.b = own(src, ln); s.n = ln
  return s
end
function Str.assign_CPtr_CPtr(s, p, q) return s:assign_CPtr_ul(p, q.O - p.O) end
function Str.assign_Ptrc_Ptrc(s, p, q) return s:assign_CPtr_ul(newcp(p.a, p.o), q.o - p.o) end
function Str.assign_ul_i(s, c, ch)
  local b = reserve(s, c)
  local v = ch & 255
  for i = 0, c - 1 do b[i] = v end
  s.n = c
  return s
end
-- append the bytes src[o .. o + m - 1]
local function app(s, src, o, m)
  if m <= 0 then return s end
  local n = s.n
  local b = s.b
  if n + m + 1 > b.n then b = reserve(s, n + m) end
  tmove(src, o, o + m - 1, n, b)
  s.n = n + m
  return s
end
function Str.append_Str(s, o) if rawequal(s, o) then local c = own(o.b, o.n); return app(s, c, 0, o.n) end return app(s, o.b, 0, o.n) end
function Str.append_Str_ul_ul(s, o, pos, ln)
  local m = o.n - pos
  if m < 0 then error(NewOutOfRange("basic_string::append"), 0) end
  if ult(ln, m) then m = ln end
  return app(s, own(o.b, o.n), pos, m)
end
function Str.append_CPtr(s, p) local src = cb(p); return app(s, src, 0, src.n) end
function Str.append_CPtr_ul(s, p, ln) if ln == 0 then return s end local src = buf_bytes(p.B, p.O, ln); return app(s, src, 0, ln) end
function Str.append_bytes(s, data) local src = str_bytes(data, false); return app(s, src, 0, src.n) end
function Str.append_ul_i(s, c, ch) local src = { n = c }; local v = ch & 255; for i = 0, c - 1 do src[i] = v end return app(s, src, 0, c) end
function Str.append_i(s, ch)
  local n = s.n
  local b = s.b
  if n + 2 > b.n then b = reserve(s, n + 1) end
  b[n] = ch & 255
  s.n = n + 1
  return s
end
function Str.push_back(s, ch)
  local n = s.n
  local b = s.b
  if n + 2 > b.n then b = reserve(s, n + 1) end
  b[n] = ch & 255
  s.n = n + 1
end
function Str.pop_back(s) s.n = s.n - 1 end
function Str.resize(s, m, ch)
  ch = ch or 0
  local n = s.n
  local b = reserve(s, m)
  local v = ch & 255
  for i = n, m - 1 do b[i] = v end
  s.n = m
end
Str.resize_ul_i = Str.resize; Str.resize_ul = Str.resize
function Str.reserve(s, c) reserve(s, c) end
function Str.shrink_to_fit(s) end
function Str.remove_prefix(s, k)
  local n = s.n
  local b = s.b
  if k > 0 then tmove(b, k, b.n - 1, 0); for i = b.n - k, b.n - 1 do b[i] = 0 end end
  n = n - k
  b[n] = 0
  s.n = n
end
function Str.remove_suffix(s, k) local n = s.n - k; s.b[n] = 0; s.n = n end
function Str.substr(s, pos, ln)
  pos = pos or 0; ln = ln or NPOS
  local n = s.n
  if ult(n, pos) then error(NewOutOfRange("basic_string::substr: __pos (which is " .. sformat("%u", pos) .. ") > this->size() (which is " .. n .. ")"), 0) end
  local m = n - pos
  if ult(ln, m) then m = ln end
  local b = { n = m + 1 }
  if m > 0 then tmove(s.b, pos, pos + m - 1, 0, b) end
  b[m] = 0
  return over(b, m)
end
function Str.erase(s, pos, ln)
  pos = pos or 0; ln = ln or NPOS
  local n = s.n
  local m = n - pos
  if ult(ln, m) then m = ln end
  local b = s.b
  if m > 0 then
    tmove(b, pos + m, b.n - 1, pos)
    for i = b.n - m, b.n - 1 do b[i] = 0 end
  end
  s.n = n - m
  return s
end
function Str.insert_ul_Str(s, pos, o)
  local sn = o.n
  local t = text(s)
  local r = t:sub(1, pos) .. text(o) .. t:sub(pos + 1)
  local nb = str_bytes(r, true)
  s.b = nb; s.n = #r
  return s
end
function Str.insert_ul_CPtr(s, pos, p) return s:insert_ul_Str(pos, str_cptr(p)) end
function Str.insert_ul_ul_i(s, pos, c, ch) return s:insert_ul_Str(pos, str_fill(c, ch)) end
function Str.replace_ul_ul_Str(s, pos, ln, o)
  local n = s.n
  local m = n - pos
  if ult(ln, m) then m = ln end
  local t = text(s)
  local r = t:sub(1, pos) .. text(o) .. t:sub(pos + m + 1)
  s.b = str_bytes(r, true); s.n = #r
  return s
end
function Str.replace_ul_ul_CPtr(s, pos, ln, p) return s:replace_ul_ul_Str(pos, ln, str_cptr(p)) end
-- find: the first index at or after pos where sub (a Lua string) starts, or npos
local function find_(s, sub, pos)
  local n = s.n
  if #sub == 0 then if not ult(n, pos) then return pos end return NPOS end
  if ult(n, pos) then return NPOS end
  local r = sfind(text(s), sub, pos + 1, true)
  return r and (r - 1) or NPOS
end
function Str.find_Str_ul(s, o, pos) return find_(s, text(o), pos or 0) end
function Str.find_CPtr_ul(s, p, pos) return find_(s, cbs(p), pos or 0) end
function Str.find_i_ul(s, ch, pos)
  pos = pos or 0
  local n = s.n
  if not ult(pos, n) then return NPOS end
  local c = ch & 255
  local b = s.b
  for i = pos, n - 1 do if b[i] == c then return i end end
  return NPOS
end
local function rfind_(s, sub, pos)
  local n, m = s.n, #sub
  if m > n then return NPOS end
  local st = n - m
  if ult(pos, st) then st = pos end
  local t = text(s)
  for i = st, 0, -1 do
    if ssub(t, i + 1, i + m) == sub then return i end
  end
  return NPOS
end
function Str.rfind_Str_ul(s, o, pos) return rfind_(s, text(o), pos or NPOS) end
function Str.rfind_CPtr_ul(s, p, pos) return rfind_(s, cbs(p), pos or NPOS) end
function Str.rfind_i_ul(s, ch, pos)
  pos = pos or NPOS
  local n = s.n
  if n == 0 then return NPOS end
  local i = n - 1
  if ult(pos, i) then i = pos end
  local c = ch & 255
  local b = s.b
  while i >= 0 do if b[i] == c then return i end i = i - 1 end
  return NPOS
end
local function set_of(bytes)
  local h = {}
  for i = 0, bytes.n - 1 do h[bytes[i]] = true end
  return h
end
local function first_of(s, h, pos, neg)
  local b = s.b
  if pos < 0 then return NPOS end
  for i = pos, s.n - 1 do
    local inn = h[b[i]] == true
    if inn ~= neg then return i end
  end
  return NPOS
end
local function last_of(s, h, pos, neg)
  local n = s.n
  if n == 0 then return NPOS end
  local i = n - 1
  if ult(pos, i) then i = pos end
  local b = s.b
  while i >= 0 do
    local inn = h[b[i]] == true
    if inn ~= neg then return i end
    i = i - 1
  end
  return NPOS
end
local function sb(o) local r = { n = o.n }; for i = 0, o.n - 1 do r[i] = o.b[i] end return r end
function Str.find_first_of_Str_ul(s, o, pos) return first_of(s, set_of(sb(o)), pos or 0, false) end
function Str.find_first_of_CPtr_ul(s, p, pos) return first_of(s, set_of(cb(p)), pos or 0, false) end
function Str.find_first_of_i_ul(s, ch, pos) return s:find_i_ul(ch, pos) end
function Str.find_first_not_of_Str_ul(s, o, pos) return first_of(s, set_of(sb(o)), pos or 0, true) end
function Str.find_first_not_of_CPtr_ul(s, p, pos) return first_of(s, set_of(cb(p)), pos or 0, true) end
function Str.find_first_not_of_i_ul(s, ch, pos) return first_of(s, { [ch & 255] = true }, pos or 0, true) end
function Str.find_last_of_Str_ul(s, o, pos) return last_of(s, set_of(sb(o)), pos or NPOS, false) end
function Str.find_last_of_CPtr_ul(s, p, pos) return last_of(s, set_of(cb(p)), pos or NPOS, false) end
function Str.find_last_of_i_ul(s, ch, pos) return s:rfind_i_ul(ch, pos) end
function Str.find_last_not_of_Str_ul(s, o, pos) return last_of(s, set_of(sb(o)), pos or NPOS, true) end
function Str.find_last_not_of_CPtr_ul(s, p, pos) return last_of(s, set_of(cb(p)), pos or NPOS, true) end
function Str.find_last_not_of_i_ul(s, ch, pos) return last_of(s, { [ch & 255] = true }, pos or NPOS, true) end
function Str.starts_with_Str(s, o) return o.n <= s.n and ssub(text(s), 1, o.n) == text(o) end
function Str.starts_with_CPtr(s, p) local sub = cbs(p); return #sub <= s.n and ssub(text(s), 1, #sub) == sub end
function Str.starts_with_i(s, ch) return s.n > 0 and s.b[0] == (ch & 255) end
function Str.ends_with_Str(s, o) return o.n <= s.n and ssub(text(s), s.n - o.n + 1) == text(o) end
function Str.ends_with_CPtr(s, p) local sub = cbs(p); return #sub <= s.n and ssub(text(s), s.n - #sub + 1) == sub end
function Str.ends_with_i(s, ch) return s.n > 0 and s.b[s.n - 1] == (ch & 255) end
function Str.contains_Str(s, o) return s:find_Str_ul(o, 0) ~= NPOS end
function Str.contains_i(s, ch) return s:find_i_ul(ch, 0) ~= NPOS end
Str.contains = Str.contains_Str
-- compare: memcmp of the common prefix (bytes unsigned), then the length difference clamped to int
function cmp_(x, y)
  local nx, ny = #x, #y
  local m = nx < ny and nx or ny
  if ssub(x, 1, m) ~= ssub(y, 1, m) then return (ssub(x, 1, m) < ssub(y, 1, m)) and -1 or 1 end
  local d = nx - ny
  if d > 2147483647 then return 2147483647 end
  if d < -2147483648 then return -2147483648 end
  return d
end
local cmp_ = cmp_
function Str.compare_Str(s, o) return cmp_(text(s), text(o)) end
Str.compare = Str.compare_Str
function Str.compare_CPtr(s, p) return cmp_(text(s), cbs(p)) end
function Str.compare_ul_ul_Str(s, pos, ln, o) return s:substr(pos, ln):compare_Str(o) end
function Str.CompareTo(s, o) return s:compare_Str(o) end
function Str.Equals_Str(s, o)
  if o == nil then return false end
  if rawequal(s, o) then return true end
  local n = s.n
  if o.n ~= n then return false end
  local a, b = s.b, o.b
  for i = 0, n - 1 do if a[i] ~= b[i] then return false end end
  return true
end
function Str.Equals(s, o) return isa_(o, Str) and s:Equals_Str(o) end
Str.Equals_o = Str.Equals
function Str.GetHashCode(s)
  local h = s.n
  local b = s.b
  for i = 0, s.n - 1 do h = (h * 31 + b[i]) & 0xFFFFFFFF end
  if h > 0x7FFFFFFF then h = h - 0x100000000 end
  return h
end
function Str.EqLit(s, p) local sub = cbs(p); return #sub == s.n and sub == text(s) end
function Str.ToString(s) return text(s) end
function Str.begin(s) return newit(nil, s.b, 0) end
Str.end_ = function(s) return newit(nil, s.b, s.n) end
Str.cbegin = Str.begin; Str.cend = Str.end_
function Str.swap(s, o) s.b, o.b = o.b, s.b; s.n, o.n = o.n, s.n end

function NewStr() return newstr() end
function NewStr_Str(s) return s:Clone() end
function str_cptr(p)
  local b, o = p.B, p.O
  local e = zfind(b, o)
  local t = { n = e - o + 1 }
  for i = o, e do t[i - o] = b[i] & 255 end
  return over(t, e - o)
end
local str_cptr = str_cptr
NewStr_CPtr = str_cptr; Str_from_CPtr = str_cptr
function NewStr_CPtr_ul(p, ln) local src = ln ~= 0 and buf_bytes(p.B, p.O, ln) or { n = 0 }; return over(own(src, ln), ln) end
function str_fill(c, ch) local t = { n = c + 1 }; local v = ch & 255; for i = 0, c - 1 do t[i] = v end t[c] = 0; return over(t, c) end
NewStr_ul_i = str_fill
function NewStr_Str_ul_ul(s, pos, ln)
  ln = ln or NPOS
  local m = s.n - pos
  if ult(ln, m) then m = ln end
  local t = { n = m + 1 }
  if m > 0 then tmove(s.b, pos, pos + m - 1, 0, t) end
  t[m] = 0
  return over(t, m)
end
function NewStr_ucA_i_i(src, off, ln) local b = ln ~= 0 and buf_bytes(src, off, ln) or { n = 0 }; return over(own(b, ln), ln) end
NewStr_str = str_of; Str_of = str_of
function Str_FromBytes(x) local m = x.n; return over(own(buf_bytes(x, 0, m), m), m) end
function Str_Cat_Str_Str(x, y) return str_of(text(x) .. text(y)) end
function Str_Cat_Str_CPtr(x, y) return str_of(text(x) .. cbs(y)) end
function Str_Cat_CPtr_Str(x, y) return str_of(cbs(x) .. text(y)) end
function Str_Cat_Str_i(x, ch) return str_of(text(x) .. schar(ch & 255)) end
function Str_Cat_i_Str(ch, y) return str_of(schar(ch & 255) .. text(y)) end
function Str_to_string_i(v) return str_of(sformat("%d", v)) end
Str_to_string_l = Str_to_string_i; Str_to_string_u = Str_to_string_i
function Str_to_string_ul(v) return str_of(sformat("%u", v)) end
function Str_to_string_d(v) return str_of(fmt_float(v, 6, "f")) end
Str_to_string_f = Str_to_string_d
function Str_stod(s, idx)
  local p = s:c_str()
  local v, e = scan_double(cbs(p), 0, true)
  if e < 0 then error(NewInvalidArgument("stod"), 0) end
  if R_get_ERange() then error(NewOutOfRange("stod"), 0) end
  if idx ~= nil and not idx:get_IsNull() then idx:set_Deref(e) end
  return v
end
-- strtol on the bytes from a CPtr: the value (clamped to long) and the index after the digits, or nil
local function strtol_p(p)
  local b, i = p.B, p.O
  while b[i] ~= nil and (b[i] == 32 or (b[i] >= 9 and b[i] <= 13)) do i = i + 1 end
  local neg = false
  if b[i] ~= nil and (b[i] == 43 or b[i] == 45) then neg = b[i] == 45; i = i + 1 end
  local st = i
  local digits = {}
  while b[i] ~= nil and b[i] >= 48 and b[i] <= 57 do digits[#digits + 1] = schar(b[i]); i = i + 1 end
  if i == st then return 0, nil end
  return clamp_long(tconcat(digits), neg), i
end
function Str_stoi(s, idx)
  local p = s:c_str()
  local v, e = strtol_p(p)
  if e == nil then error(NewInvalidArgument("stoi"), 0) end
  if v < -2147483648 or v > 2147483647 then error(NewOutOfRange("stoi"), 0) end
  if idx ~= nil and not idx:get_IsNull() then idx:set_Deref(e - p.O) end
  return v
end
function Str_stol(s, idx)
  local p = s:c_str()
  local v, e = strtol_p(p)
  if e == nil then error(NewInvalidArgument("stol"), 0) end
  if idx ~= nil and not idx:get_IsNull() then idx:set_Deref(e - p.O) end
  return v
end
-- a decimal digit string as a long: clamped to the range (strtol's rule)
function clamp_long(d, neg)
  d = d:gsub("^0+(%d)", "%1")
  local lim = neg and "9223372036854775808" or "9223372036854775807"
  if #d > 19 or (#d == 19 and d > lim) then return neg and math.mininteger or math.maxinteger end
  local v = 0
  for i = 1, #d do v = v * 10 + (sbyte(d, i) - 48) end
  return neg and -v or v
end

-- ------------------------------------------------------------------------------------------------ C++ exceptions
local CppException = lua_class("CppException", Cpp_Exception)
Cpp_CppException = CppException
CppException.DEFAULT = "std::exception"
function CppException._alloc(c) return setmetatable({}, c) end
local function exc_new(c, m)
  local o = setmetatable({}, c)
  if m == nil then o.msg = str_of(c.DEFAULT) elseif type(m) == "string" then o.msg = str_of(m) else o.msg = m:Clone() end
  return o
end
function CppException._ctor_Str(s, m) s.msg = m:Clone() end
function CppException.what(s) local m = s.msg; if m == nil then m = str_of(s.DEFAULT) end return m:c_str() end
function CppException.Message(s) if s.msg ~= nil then return text(s.msg) end return s.DEFAULT end
function CppException.ToString(s) return s:Message() end
for _, p in ipairs({ { "LogicError", "CppException" }, { "RuntimeError", "CppException" }, { "InvalidArgument", "LogicError" },
    { "OutOfRange", "LogicError" }, { "LengthError", "LogicError" }, { "DomainError", "LogicError" }, { "RangeError", "RuntimeError" },
    { "OverflowError", "RuntimeError" }, { "BadAlloc", "CppException", "std::bad_alloc" }, { "BadOptionalAccess", "CppException", "bad optional access" },
    { "BadFunctionCall", "CppException", "bad_function_call" }, { "BadVariantAccess", "CppException", "std::get: wrong index for variant" } }) do
  local n, base, d = p[1], p[2], p[3]
  local c = lua_class(n, _ENV["Cpp_" .. base])
  if d then c.DEFAULT = d end
  _ENV["Cpp_" .. n] = c
  local f = function(m) return exc_new(c, m) end
  _ENV["New" .. n .. "_Str"] = f; _ENV["New" .. n .. "_str"] = f; _ENV["New" .. n] = f
end
function NewCppException(m) return exc_new(CppException, m) end
NewCppException_Str = NewCppException

-- ------------------------------------------------------------------------------------------------ vectors
local ZEROS = { D = 0.0, F = 0.0, I = 0, L = 0, B = 0, Z = false, S = 0, C = 0 }

local VecBase = lua_class("VecBase", nil, { Cpp_ICopy, Cpp_IDestroyElems })
function VecBase.size(v) return v.n end
function VecBase.empty(v) return v.n == 0 end
function VecBase.capacity(v) return v.a.n end
function VecBase.at(v, i)
  if not ult(i, v.n) then error(NewOutOfRange("vector::_M_range_check: __n (which is " .. sformat("%u", i) .. ") >= this->size() (which is " .. v.n .. ")"), 0) end
  return v.a[i]
end
function VecBase.ref_at(v, i)
  if not ult(i, v.n) then error(NewOutOfRange("vector::_M_range_check: __n (which is " .. sformat("%u", i) .. ") >= this->size() (which is " .. v.n .. ")"), 0) end
  return v.a, i
end
function VecBase.front(v) return v.a[0] end
function VecBase.back(v) return v.a[v.n - 1] end
function VecBase.ref_front(v) return v.a, 0 end
function VecBase.ref_back(v) return v.a, v.n - 1 end
function VecBase.data(v) if v.a.n > 0 then return newptr(v.a, 0) end return Ptr_ZERO end
function VecBase.get_Item(v, i) return v.a[i] end
function VecBase.set_Item(v, i, x) v.a[i] = x end
function VecBase.ref_Item(v, i) return v.a, i end
VecBase.get_Item_ul = VecBase.get_Item; VecBase.get_Item_l = VecBase.get_Item; VecBase.get_Item_i = VecBase.get_Item
VecBase.set_Item_ul = VecBase.set_Item; VecBase.set_Item_l = VecBase.set_Item; VecBase.set_Item_i = VecBase.set_Item
VecBase.ref_Item_ul = VecBase.ref_Item; VecBase.ref_Item_l = VecBase.ref_Item; VecBase.ref_Item_i = VecBase.ref_Item
-- libstdc++'s new capacity: size + max(size, 1), at least need (the array grows in place)
local function grow(v, need)
  local a = v.a
  local la = a.n
  if need <= la then return a end
  local n = v.n
  local cap = n + (n > 1 and n or 1)
  if cap < need then cap = need end
  local z = v._z
  for i = la, cap - 1 do a[i] = z end
  a.n = cap
  return a
end
function VecBase.reserve(v, c)
  local a = v.a
  if c > a.n then local z = v._z; for i = a.n, c - 1 do a[i] = z end a.n = c end
end
function VecBase.shrink_to_fit(v)
  local a = v.a
  if a.n ~= v.n then for i = v.n, a.n - 1 do a[i] = nil end a.n = v.n end
end
function VecBase.push_back(v, x)
  local n = v.n
  local a = v.a
  if n == a.n then a = grow(v, n + 1) end
  a[n] = x
  v.n = n + 1
end
function VecBase.emplace_back(v, x) v:push_back(x); return x end
function VecBase.ref_emplace_back(v, x) v:push_back(x); return v.a, v.n - 1 end
function VecBase.pop_back(v) local n = v.n - 1; v.n = n; v.a[n] = v._z end
function VecBase.clear(v)
  local n = v.n
  if n > 0 then local z = v._z; local a = v.a; for i = 0, n - 1 do a[i] = z end end
  v.n = 0
end
function VecBase.swap(v, o) v.a, o.a = o.a, v.a; v.n, o.n = o.n, v.n end
function VecBase.begin(v) return newit(v, v.a, 0) end
VecBase.end_ = function(v) return newit(v, v.a, v.n) end
VecBase.cbegin = VecBase.begin; VecBase.cend = VecBase.end_
function VecBase.rbegin(v) return newrit(v, v.n) end
function VecBase.rend(v) return newrit(v, 0) end
function VecBase.elems(v) local a = v.a; local n = v.n; local r = {}; if n > 0 then tmove(a, 0, n - 1, 1, r) end return r, n end
-- insert the elements of tmp (0 .. m - 1) at p
local function insert_(v, p, tmp)
  local m = tmp.n
  local n = v.n
  local a = grow(v, n + m)
  if m > 0 then
    tmove(a, p, n - 1, p + m)
    tmove(tmp, 0, m - 1, p, a)
  end
  v.n = n + m
  return newit(v, a, p)
end
function VecBase.insert_IterT_T(v, pos, x)
  local tmp = { [0] = x, n = 1 }
  return insert_(v, pos.i, tmp)
end
function VecBase.insert_IterT_IterT_IterT(v, pos, b, e) return insert_(v, pos.i, v:_copy_range(b.a, b.i, e.i - b.i)) end
function VecBase.insert_IterT_TA(v, pos, arr) return insert_(v, pos.i, v:_copy_range(arr, 0, arr.n)) end
function VecBase.insert_IterT_PtrT_PtrT(v, pos, b, e) return insert_(v, pos.i, v:_copy_range(b.a, b.o, e.o - b.o)) end
function VecBase.insert_IterT_ul_T(v, pos, c, x) return insert_(v, pos.i, v:_fill_copies(x, c)) end
function VecBase.erase_IterT(v, pos)
  local p = pos.i
  local a = v.a
  local n = v.n
  tmove(a, p + 1, a.n - 1, p)
  a[a.n - 1] = v._z
  v.n = n - 1
  return newit(v, a, p)
end
function VecBase.erase_IterT_IterT(v, b, e)
  local p, q = b.i, e.i
  local a = v.a
  local m = q - p
  if m > 0 then
    tmove(a, q, a.n - 1, p)
    local z = v._z
    for i = a.n - m, a.n - 1 do a[i] = z end
  end
  v.n = v.n - m
  return newit(v, a, p)
end
function VecBase.assign_ul_T(v, c, x)
  local a = v.a
  local z = v._z
  if c > a.n then a = newA(c, z); v.a = a else for i = 0, a.n - 1 do a[i] = z end end
  local f = v:_fill_copies(x, c)
  for i = 0, c - 1 do a[i] = f[i] end
  v.n = c
end
function VecBase.assign_IterT_IterT(v, b, e) local m = e.i - b.i; v.a = v:_copy_range(b.a, b.i, m); v.n = m end
function VecBase.assign_TA(v, il) v.a = v:_copy_range(il, 0, il.n); v.n = il.n end
VecBase.Assign_TA = VecBase.assign_TA; VecBase.MoveFrom_TA = VecBase.assign_TA
function VecBase.resize_ul_T(v, c, x)
  local n = v.n
  if c > n then
    local a = grow(v, c)
    local f = v:_fill_copies(x, c - n)
    for i = n, c - 1 do a[i] = f[i - n] end
  elseif c < n then
    local z = v._z
    local a = v.a
    for i = c, n - 1 do a[i] = z end
  end
  v.n = c
end

local VecP = lua_class("VecP", VecBase)        -- a vector of numbers or bools (VecD, VecI, ...)
function VecP._copy_range(v, src, o, m)
  if o < 0 or o + m > src.n then error(NewSysException("IndexOutOfRangeException", "cpp.Vec: range outside its array"), 0) end
  local r = { n = m }
  if m > 0 then tmove(src, o, o + m - 1, 0, r) end
  return r
end
function VecP._fill_copies(v, x, m) return newA(m, x) end
function VecP.resize_ul(v, c)
  local n = v.n
  if c > n then grow(v, c)
  elseif c < n then local z = v._z; local a = v.a; for i = c, n - 1 do a[i] = z end end
  v.n = c
end
VecP.resize = VecP.resize_ul
function VecP.DestroyElems(v) end
function VecP.Clone(v)
  local n = v.n
  local a = { n = n }
  if n > 0 then tmove(v.a, 0, n - 1, 0, a) end
  return setmetatable({ a = a, n = n }, getmetatable(v))
end
function VecP.Assign_VecT(v, o)
  if rawequal(v, o) then return end
  local n = o.n
  local a = { n = n }
  if n > 0 then tmove(o.a, 0, n - 1, 0, a) end
  v.a = a; v.n = n
end
function VecP.MoveFrom_VecT(v, o)
  if rawequal(v, o) then return end
  v.a = o.a; v.n = o.n
  o.a = { n = 0 }; o.n = 0
end
local function is_array(x) return type(x) == "table" and getmetatable(x) == nil end
function VecP.Assign(v, o) if is_array(o) then return v:assign_TA(o) end return v:Assign_VecT(o) end
function VecP.MoveFrom(v, o) if is_array(o) then return v:assign_TA(o) end return v:MoveFrom_VecT(o) end

local Vec = lua_class("Vec", VecBase)           -- a vector of objects (element maker mk: default T, as C#'s Elem<T>.Make)
Cpp_Vec = Vec
Vec._z = nil
local function copies(src, o, m)
  local r = { n = m }
  for i = 0, m - 1 do r[i] = copy(src[o + i]) end
  return r
end
_ENV.copies = copies
function Vec._copy_range(v, src, o, m)
  if o < 0 or o + m > src.n then error(NewSysException("IndexOutOfRangeException", "cpp.Vec: range outside its array"), 0) end
  return copies(src, o, m)
end
function Vec._fill_copies(v, x, m)
  local r = { n = m }
  if type(x) == "table" and (getmetatable(x) == nil or is_icopy(x)) then
    for i = 0, m - 1 do r[i] = copy(x) end
  else
    for i = 0, m - 1 do r[i] = x end
  end
  return r
end
function Vec.resize_ul(v, c)
  local n = v.n
  if c > n then
    local a = grow(v, c)
    local mk = v.mk
    if mk == nil then for i = n, c - 1 do a[i] = nil end
    elseif IMMUT[mk] then local x = mk(); for i = n, c - 1 do a[i] = x end
    else for i = n, c - 1 do a[i] = mk() end end
  elseif c < n then local a = v.a; for i = c, n - 1 do a[i] = nil end end
  v.n = c
end
Vec.resize = Vec.resize_ul
function Vec.DestroyElems(v) local a = v.a; for i = 0, v.n - 1 do dtor(a[i]) end end
function Vec.Clone(v) return setmetatable({ a = copies(v.a, 0, v.n), n = v.n, mk = v.mk, mkx = v.mkx }, Vec) end
local function adopt(v, o) if not v.mkx and o.mkx then v.mk = o.mk; v.mkx = true end end
function Vec.Assign_VecT(v, o)
  if rawequal(v, o) then return end
  v.a = copies(o.a, 0, o.n); v.n = o.n; adopt(v, o)
end
function Vec.MoveFrom_VecT(v, o)
  if rawequal(v, o) then return end
  v.a = o.a; v.n = o.n; adopt(v, o)
  o.a = { n = 0 }; o.n = 0
end
function Vec.Assign(v, o) if is_array(o) then return v:assign_TA(o) end return v:Assign_VecT(o) end
function Vec.MoveFrom(v, o) if is_array(o) then return v:assign_TA(o) end return v:MoveFrom_VecT(o) end

function vec_eq_plain(x, y)
  local n = x.n
  if n ~= y.n then return false end
  local a, b = x.a, y.a
  for i = 0, n - 1 do if a[i] ~= b[i] then return false end end
  return true
end
function vec_eq_double(x, y)
  local n = x.n
  if n ~= y.n then return false end
  local a, b = x.a, y.a
  for i = 0, n - 1 do local p, q = a[i], b[i]; if p ~= q and (p == p or q == q) then return false end end
  return true
end
VEC_CLASSES = {}
for c, z in pairs(ZEROS) do
  local k = lua_class("Vec" .. c, VecP)
  k._z = z
  _ENV["Cpp_Vec" .. c] = k
  VEC_CLASSES[c] = k
  _ENV["NewVec" .. c] = function() return setmetatable({ a = { n = 0 }, n = 0 }, k) end
  _ENV["NewVec" .. c .. "_ul"] = function(n) return setmetatable({ a = newA(n, z), n = n }, k) end
  _ENV["NewVec" .. c .. "_ul_T"] = function(n, x) return setmetatable({ a = newA(n, x), n = n }, k) end
  _ENV["NewVec" .. c .. "_TA"] = function(arr) local a = { n = arr.n }; if arr.n > 0 then tmove(arr, 0, arr.n - 1, 0, a) end return setmetatable({ a = a, n = arr.n }, k) end
  _ENV["Vec" .. c .. "_Adopt"] = function(arr) return setmetatable({ a = arr, n = arr.n }, k) end
  _ENV["Vec" .. c .. "_Eq"] = (c == "D" or c == "F") and vec_eq_double or vec_eq_plain
end
function NewVec(mk) return setmetatable({ a = { n = 0 }, n = 0, mk = mk, mkx = false }, Vec) end
function NewVec_FuncT(mk) return setmetatable({ a = { n = 0 }, n = 0, mk = mk, mkx = true }, Vec) end
function NewVec_ul(c, mk) return setmetatable({ a = made(mk, c), n = c, mk = mk, mkx = false }, Vec) end
function NewVec_ul_FuncT(c, mk) local v = NewVec_ul(c, mk); v.mkx = true; return v end
function NewVec_ul_T(c, x, mk)
  local v = setmetatable({ a = { n = 0 }, n = 0, mk = mk, mkx = false }, Vec)
  v.a = v:_fill_copies(x, c); v.n = c
  return v
end
function NewVec_TA(init, mk) return setmetatable({ a = copies(init, 0, init.n), n = init.n, mk = mk, mkx = false }, Vec) end
function Vec_Adopt(arr, mk) return setmetatable({ a = arr, n = arr.n, mk = mk, mkx = false }, Vec) end
function Vec_Eq(x, y)
  local n = x.n
  if n ~= y.n then return false end
  for i = 0, n - 1 do if not elem_eq(x.a[i], y.a[i]) then return false end end
  return true
end

-- ------------------------------------------------------------------------------------------------ std::optional
local Opt = lua_class("Opt", nil, { Cpp_ICopy, Cpp_IDestroyElems })
Cpp_Opt = Opt
Opt._z = nil
function Opt.DestroyElems(s) if s.has then dtor(s.val) end end
function Opt.has_value(s) return s.has end
function Opt.value(s) if not s.has then error(NewBadOptionalAccess(), 0) end return s.val end
function Opt.ref_value(s) if not s.has then error(NewBadOptionalAccess(), 0) end return s, "val" end
function Opt.get_Deref(s) return s.val end
function Opt.set_Deref(s, v) s.val = v end
function Opt.ref_Deref(s) return s, "val" end
function Opt.value_or(s, d) if s.has then return s.val end return d end
function Opt.reset(s) s.has = false; s.val = s._z end
function Opt.MoveFrom(s, o) if rawequal(s, o) then return end s.has = o.has; s.val = o.val end
function Opt.emplace(s, v) s.has = true; s.val = v end
function Opt.ref_emplace(s, v) s.has = true; s.val = v; return s, "val" end
function Opt.Clone(s) return setmetatable({ has = s.has, val = s.has and copy(s.val) or s._z }, getmetatable(s)) end
function Opt.Assign(s, o) s.has = o.has; if o.has then s.val = copy(o.val) else s.val = s._z end end
function Opt.Set(s, v) s.has = true; s.val = v end
function NewOpt() return setmetatable({ has = false }, Opt) end
function NewOpt_T(v) return setmetatable({ has = true, val = v }, Opt) end
for c, z in pairs(ZEROS) do
  local k = lua_class("Opt" .. c, Opt)
  k._z = z
  _ENV["NewOpt" .. c] = function() return setmetatable({ has = false, val = z }, k) end
  _ENV["NewOpt" .. c .. "_T"] = function(v) return setmetatable({ has = true, val = v }, k) end
end

-- ------------------------------------------------------------------------------------------------ std::pair
local Pair = lua_class("Pair", nil, { Cpp_ICopy })
Cpp_Pair = Pair
local function newpair(a, b) return setmetatable({ first = a, second = b }, Pair) end
_ENV.newpair = newpair
function Pair.Clone(s) return newpair(copy(s.first), copy(s.second)) end
function Pair.Assign(s, o) s.first = copy(o.first); s.second = copy(o.second) end
function Pair.ref_first(s) return s, "first" end
function Pair.ref_second(s) return s, "second" end
function Pair.CompareTo(s, o)
  if elem_less(s.first, o.first) then return -1 end
  if elem_less(o.first, s.first) then return 1 end
  if elem_less(s.second, o.second) then return -1 end
  if elem_less(o.second, s.second) then return 1 end
  return 0
end
function NewPair(mka, mkb) return newpair(mka(), mkb()) end
function NewPair_A_B(a, b) return newpair(a, b) end
function Pair_Eq(x, y) return elem_eq(x.first, y.first) and elem_eq(x.second, y.second) end
function Pair_op_Lt(x, y) return x:CompareTo(y) < 0 end
function Pair_op_Gt(x, y) return x:CompareTo(y) > 0 end
function Pair_op_Le(x, y) return x:CompareTo(y) <= 0 end
function Pair_op_Ge(x, y) return x:CompareTo(y) >= 0 end

-- ------------------------------------------------------------------------------------------------ min/max, arrays
function M_min(a, b) if b < a then return b end return a end
function M_max(a, b) if a < b then return b end return a end
function M_min_T_T_FuncTTb(a, b, f) if f(b, a) then return b end return a end
function M_max_T_T_FuncTTb(a, b, f) if f(a, b) then return b end return a end
function M_clamp(v, lo, hi) if v < lo then return lo end if hi < v then return hi end return v end
function M_min_dA(il) local r = il[0]; for i = 1, il.n - 1 do if il[i] < r then r = il[i] end end return r end
function M_max_dA(il) local r = il[0]; for i = 1, il.n - 1 do if r < il[i] then r = il[i] end end return r end
M_min_iA = M_min_dA; M_max_iA = M_max_dA
function Arr_Make(n, mk) return made(mk, n) end
function Arr_MakeWith(n, mk) local t = { n = n }; for i = 0, n - 1 do t[i] = mk() end return t end
function Arr_Make2(n, m, mk) local t = { n = n }; for i = 0, n - 1 do t[i] = made(mk, m) end return t end
function Arr_Clone(a)
  if a == nil then return nil end
  local r = { n = a.n }
  for i = 0, a.n - 1 do local x = a[i]; if is_icopy(x) then x = x:Clone() end r[i] = x end
  return r
end
function Arr_Assign(d, s) for i = 0, s.n - 1 do if is_icopy(d[i]) then d[i]:Assign(s[i]) else d[i] = s[i] end end end
function Arr_Fill(a, b, e, v) for i = b, e - 1 do a[i] = copy(v) end end
function Arr_Eq(x, y) if x.n ~= y.n then return false end for i = 0, x.n - 1 do if not elem_eq(x[i], y[i]) then return false end end return true end
function Array_Fill(l, v) for i = 0, l.n - 1 do l[i] = v end end
for c, z in pairs(ZEROS) do
  _ENV["Arr_Make__" .. c] = function(n) return newA(n, z) end
  _ENV["Arr_Make2__" .. c] = function(n, m) local t = { n = n }; for i = 0, n - 1 do t[i] = newA(m, z) end return t end
  _ENV["Arr_Clone__" .. c] = function(a) if a == nil then return nil end local r = { n = a.n }; if a.n > 0 then tmove(a, 0, a.n - 1, 0, r) end return r end
  _ENV["Arr_Assign__" .. c] = function(d, s) if s.n > 0 then tmove(s, 0, s.n - 1, 0, d) end end
  _ENV["Arr_Fill__" .. c] = function(a, b, e, v) for i = b, e - 1 do a[i] = v end end
  _ENV["Arr_Eq__" .. c] = (c == "D" or c == "F")
    and function(x, y) if x.n ~= y.n then return false end for i = 0, x.n - 1 do local p, q = x[i], y[i]; if not (p == q or (p ~= p and q ~= q)) then return false end end return true end
    or function(x, y) if x.n ~= y.n then return false end for i = 0, x.n - 1 do if x[i] ~= y[i] then return false end end return true end
end

-- ------------------------------------------------------------------------------------------------ destructors, moves
local IDisposable, IDestroyElems = Cpp_IDisposable, Cpp_IDestroyElems
function dtor(o)
  if type(o) ~= "table" then return end
  local mt = getmetatable(o)
  if mt == nil then for i = 0, (o.n or 0) - 1 do if type(o[i]) == "table" then dtor(o[i]) end end return end
  local s = mt.__isa
  if s == nil then return end
  if s[IDisposable] then o:Dispose() elseif s[IDestroyElems] then o:DestroyElems() end
end
local dtor = dtor
Dtor_Run = dtor

local Defer = lua_class("Defer", nil, { Cpp_IDisposable })
function Defer.Cancel(s) s.a = nil end
function Defer.Dispose(s) local x = s.a; s.a = nil; if x ~= nil then x() end end
function NewDefer(f) return setmetatable({ a = f }, Defer) end

function Mv_Reset(t, k, q) local old = t[k]; t[k] = q; if old ~= nil and not rawequal(old, q) then dtor(old) end end
function Mv_Back(v, t, k, box) t[k] = box[0]; return v end
function Mv_Back_U(v, t, k, box) t[k] = box[0] & 0xFFFFFFFF; return v end
function Mv_Back_Q(v, t, k, box) t[k] = box[0]; return v end
function Mv_Take(t, k, mk) local r = t[k]; t[k] = mk(); return r end
function Mv_TakeRef(t, k) local r = t[k]; t[k] = nil; return r end
function Mv_PostStep_PtrTr_i(t, k, d) local r = t[k]; t[k] = r:add(d); return r end
function Mv_PostStep_IterTr_i(t, k, d) local r = t[k]; t[k] = Iter_op_Add(r, d); return r end
function Mv_PostStep_CPtrr_i(t, k, d) local r = t[k]; t[k] = newcp(r.B, r.O + d); return r end
function Mv_PostStep_RevIterTr_i(t, k, d) local r = t[k]; t[k] = newrit(r.v, r.i - 1); return r end
function Mv_PostStep_MItEr_i(t, k, d) local r = t[k]; if d > 0 then t[k] = MIt_op_Increment(r) else t[k] = MIt_op_Decrement(r) end return r end
function Mv_Delete(o) if isa_(o, IDisposable) then o:Dispose() end end
for _, c in ipairs({ "", "D", "F", "I", "L", "B", "Z", "S", "C" }) do
  if c ~= "" then
    for _, n in ipairs({ "Mv_PostStep_PtrTr_i", "Mv_PostStep_IterTr_i", "Mv_PostStep_RevIterTr_i", "Mv_Reset", "Mv_TakeRef" }) do _ENV[n .. "__" .. c] = _ENV[n] end
    local z = ZEROS[c]
    _ENV["Mv_Take__" .. c] = function(t, k) local r = t[k]; t[k] = z; return r end
  end
  for _, c2 in ipairs({ "O", "D", "F", "I", "L", "B", "Z", "S", "C" }) do
    local n = "Mv_Back__" .. (c == "" and "O" or c) .. c2
    if _ENV[n] == nil then _ENV[n] = Mv_Back end
  end
end
for _, c in ipairs({ "O", "D", "F", "I", "L", "B", "Z", "S", "C" }) do _ENV["Mv_Back__" .. c .. "U"] = Mv_Back_U; _ENV["Mv_Back__" .. c .. "Q"] = Mv_Back_Q end
