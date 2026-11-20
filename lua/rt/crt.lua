-- crt.lua - the C library layer (cs/runtime/CRuntime.cs and Stash.cs, by way of perl/cpp/crt.pl): NUL-terminated
-- byte strings, strtod / strtol / atoi, sscanf (glibc's scanner), the printf family, stdio files, time, and the math
-- functions. Numbers are read with tonumber, which reads a decimal or hexadecimal number with C's strtod (glibc's,
-- correctly rounded); the extent of the number, inf, nan(...) and ERANGE are glibc's rules written out. Every numeric
-- printf conversion is handed to string.format, which hands it to glibc's snprintf; what string.format refuses (a width
-- or precision over 99) is padded here from the digits glibc gives.
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and lua/README.md.
local setmetatable, getmetatable, rawequal, type, error, pairs, ipairs, tostring, tonumber, select, pcall =
  setmetatable, getmetatable, rawequal, type, error, pairs, ipairs, tostring, tonumber, select, pcall
local schar, sbyte, ssub, srep, sformat, sfind, slower, supper, spack, sunpack, sgsub, smatch =
  string.char, string.byte, string.sub, string.rep, string.format, string.find, string.lower, string.upper, string.pack, string.unpack, string.gsub, string.match
local mtype, ult, huge, mininteger, maxinteger = math.type, math.ult, math.huge, math.mininteger, math.maxinteger
local m_exp, m_log, m_sin, m_cos, m_tan, m_asin, m_acos, m_atan, m_sqrt, m_fmod, m_abs = math.exp, math.log, math.sin, math.cos, math.tan, math.asin, math.acos, math.atan, math.sqrt, math.fmod, math.abs
local tconcat, tmove, tunpack = table.concat, table.move, table.unpack
local io, os = io, os
local _ENV = ...
local newcp, newptr, cbs, bytes_str, str_bytes, zfind, signbit, i32, f32, isa_, str_of, str_text, clamp_long =
  newcp, newptr, cbs, bytes_str, str_bytes, zfind, signbit, i32, f32, isa_, str_of, str_text, clamp_long
local CPtr_ZERO = CPtr_ZERO
local DNAN, QNAN = K_DNAN, K_QNAN
local DBL_MIN = 2.2250738585072014e-308
local SPACE = { [32] = true, [9] = true, [10] = true, [11] = true, [12] = true, [13] = true }

-- ------------------------------------------------------------------------------------------------ byte strings
local function put(p, off, data)
  local n = #data
  if n == 0 then return end
  local b = p.B
  local o = p.O + off
  for i = 1, n do b[o + i - 1] = sbyte(data, i) end
  if b.n < o + n then b.n = o + n end
end
_ENV.put = put
local LITS = {}
local NLITS = 0
local function lit_bytes(s)
  local b = LITS[s]
  if b == nil then
    b = str_bytes(s, true)
    if NLITS < 200000 then LITS[s] = b; NLITS = NLITS + 1 end
  end
  return b
end
_ENV.lit_bytes = lit_bytes
local function copybuf(b) local r = { n = b.n }; tmove(b, 0, b.n - 1, 0, r) return r end
function R_Lit(s) return newcp(copybuf(lit_bytes(s)), 0) end
function R_LitN(s, n) local b = copybuf(lit_bytes(s)); for i = b.n, n - 1 do b[i] = 0 end if n > b.n then b.n = n end return newcp(b, 0) end
function R_Buf_i(n) if n < 1 then n = 1 end local b = { n = n }; for i = 0, n - 1 do b[i] = 0 end return newcp(b, 0) end
R_Buf_l = R_Buf_i; R_Buf_ul = R_Buf_i
function R_BufFrom(lit, n) local p = R_Buf_i(n); put(p, 0, ssub(cbs(lit), 1, n)); return p end
function R_Bufs(n, m) local t = { n = n }; for i = 0, n - 1 do t[i] = R_Buf_i(m) end return t end
R_NewBufs = R_Bufs
function R_BufOf(n, vals)
  local m = n > 1 and n or 1
  local b = { n = m }
  for i = 0, m - 1 do b[i] = 0 end
  local k = vals.n < m and vals.n or m
  for i = 0, k - 1 do b[i] = vals[i] & 255 end
  return newcp(b, 0)
end
function R_CopyBuf(p) if p.B ~= nil then return newcp(copybuf(p.B), p.O) end return p end
function R_Str(p) return cbs(p) end
R_Bytes = R_Str
function R_strlen(p)
  local b, i = p.B, p.O
  while true do
    local c = b[i]
    if c == nil then error(NewSysException("IndexOutOfRangeException", "strlen: no terminating NUL"), 0) end
    if c & 255 == 0 then break end
    i = i + 1
  end
  return i - p.O
end
function R_strcpy(d, s) put(d, 0, cbs(s) .. "\0"); return d end
function R_strcat(d, s) put(d, R_strlen(d), cbs(s) .. "\0"); return d end
function R_strcmp(a, b)
  local x, y = cbs(a), cbs(b)
  if x == y then return 0 end
  local n = #x < #y and #x or #y
  for i = 1, n do local d = sbyte(x, i) - sbyte(y, i); if d ~= 0 then return d end end
  return (#x > n and sbyte(x, n + 1) or 0) - (#y > n and sbyte(y, n + 1) or 0)
end
function R_strchr(s, c)
  local ch = c & 255
  local b, i = s.B, s.O
  while true do
    local x = b[i] & 255
    if x == ch then return newcp(b, i) end
    if x == 0 then return CPtr_ZERO end
    i = i + 1
  end
end
function R_strrchr(s, c)
  local ch = c & 255
  local b, i = s.B, s.O
  local r = nil
  while true do
    local x = b[i] & 255
    if x == ch then r = i end
    if x == 0 then if r ~= nil then return newcp(b, r) end return CPtr_ZERO end
    i = i + 1
  end
end
function R_strstr(h, n)
  local nb = cbs(n)
  if nb == "" then return h end
  local i = sfind(cbs(h), nb, 1, true)
  if i == nil then return CPtr_ZERO end
  return newcp(h.B, h.O + i - 1)
end
function R_strcspn(s, r)
  local sb, rb = cbs(s), cbs(r)
  for i = 1, #sb do if sfind(rb, ssub(sb, i, i), 1, true) then return i - 1 end end
  return #sb
end
local TOK = nil
function R_strtok(s, delim)
  if s.B ~= nil then TOK = { s.B, s.O } end
  if TOK == nil then return CPtr_ZERO end
  local b, p = TOK[1], TOK[2]
  local ds = {}
  local dl = cbs(delim)
  for i = 1, #dl do ds[sbyte(dl, i)] = true end
  local n = b.n
  while p < n and b[p] & 255 ~= 0 and ds[b[p] & 255] do p = p + 1 end
  if p >= n or b[p] & 255 == 0 then TOK = nil; return CPtr_ZERO end
  local start = p
  while p < n and b[p] & 255 ~= 0 and not ds[b[p] & 255] do p = p + 1 end
  if p < n and b[p] & 255 ~= 0 then b[p] = 0; TOK = { b, p + 1 } else TOK = nil end
  return newcp(b, start)
end
function R_toupper(c) if c >= 97 and c <= 122 then return c - 32 end return c end
function R_tolower(c) if c >= 65 and c <= 90 then return c + 32 end return c end
function R_isdigit(c) return (c >= 48 and c <= 57) and 1 or 0 end
function R_isalpha(c) return ((c >= 97 and c <= 122) or (c >= 65 and c <= 90)) and 1 or 0 end
function R_isalnum(c) return (R_isdigit(c) == 1 or R_isalpha(c) == 1) and 1 or 0 end
function R_isspace(c) return (c == 32 or (c >= 9 and c <= 13)) and 1 or 0 end
function R_isupper(c) return (c >= 65 and c <= 90) and 1 or 0 end
function R_islower(c) return (c >= 97 and c <= 122) and 1 or 0 end
function R_isprint(c) return (c >= 32 and c <= 126) and 1 or 0 end
function R_ispunct(c) return (R_isprint(c) == 1 and c ~= 32 and R_isalnum(c) == 0) and 1 or 0 end
function R_isxdigit(c) return (R_isdigit(c) == 1 or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)) and 1 or 0 end

-- ------------------------------------------------------------------------------------------------ strtod
local ERANGE = false
function R_get_ERange() return ERANGE end

-- decimal big integers as digit strings, for the exact underflow test: d * 2^k
local function dec_mul_small(ds, m)
  -- ds a decimal digit string, m < 2^22: the product's digits
  local out = {}
  local carry = 0
  for i = #ds, 1, -1 do
    local v = (sbyte(ds, i) - 48) * m + carry
    out[#out + 1] = v % 10
    carry = v // 10
  end
  while carry > 0 do out[#out + 1] = carry % 10; carry = carry // 10 end
  local r = {}
  for i = #out, 1, -1 do r[#r + 1] = schar(48 + out[i]) end
  local s = tconcat(r):gsub("^0+", "")
  return s == "" and "0" or s
end
local function dec_mul_pow2(ds, k)
  while k >= 20 do ds = dec_mul_small(ds, 1 << 20); k = k - 20 end
  if k > 0 then ds = dec_mul_small(ds, 1 << k) end
  return ds
end
local function dec_cmp(a, b)
  if #a ~= #b then return #a < #b and -1 or 1 end
  if a == b then return 0 end
  return a < b and -1 or 1
end
-- glibc strtod's ERANGE for a decimal whose correctly rounded value is av: overflow, or underflow (tiny after rounding
-- and inexact), decided exactly: ds the significant digits, e10 the exponent of the last one, nd = #ds
local function dec_range(ds, e10, nd, av)
  if av == huge then return true end
  if av > DBL_MIN or ds == "" then return false end
  if nd + e10 < -340 then return true end
  if e10 >= 0 then return false end
  local zeros = srep("0", -e10)
  -- not tiny when d * 10^e10 >= (2^54 - 1) * 2^-1076 (it rounds to DBL_MIN or more): d * 2^1076 >= (2^54 - 1) * 10^-e10
  if dec_cmp(dec_mul_pow2(ds, 1076), "18014398509481983" .. zeros) >= 0 then return false end
  -- exact when d * 2^1074 == m * 10^-e10, m the double's integer multiple of 2^-1074
  local m = sunpack("<i8", spack("<d", av))
  return dec_cmp(dec_mul_pow2(ds, 1074), tostring(m) .. zeros) ~= 0
end
local function hexval(c)
  if c >= 48 and c <= 57 then return c - 48 end
  local l = c | 0x20
  if l >= 97 and l <= 102 then return l - 87 end
  return -1
end
local function low(c) if c >= 65 and c <= 90 then return c | 0x20 end return c end
-- strtoull(s, 0, 0) of a whole n-char sequence: the value as 64 bits (saturating), or nil when it is not a number
local function c_unsigned(s)
  local base, d
  if smatch(s, "^0[xX]%x+$") then base = 16; d = ssub(s, 3)
  elseif smatch(s, "^0[0-7]*$") then base = 8; d = s
  elseif smatch(s, "^%d+$") then base = 10; d = s
  else return nil end
  local v = 0
  for k = 1, #d do
    local x = hexval(sbyte(d, k))
    local hi = (v >> 32) * base
    local lo = (v & 0xFFFFFFFF) * base + x
    hi = hi + (lo >> 32)
    if hi > 0xFFFFFFFF then return -1 end
    v = (hi << 32) | (lo & 0xFFFFFFFF)
  end
  return v
end
local function bits2d(b) return (sunpack("<d", spack("<i8", b))) end
local function d2bits(x) return (sunpack("<i8", spack("<d", x))) end
-- glibc's strtod on the Lua string t from 1-based index i (the end of t ends the input; skip: leading white space):
-- the value and the 1-based index after the number, or (0.0, -1) when no number was read. Sets ERANGE.
local function scan_double(t, i, skip)
  local n = #t
  local function g(k) if k > n then return 0 end return sbyte(t, k) end
  if skip then while SPACE[g(i)] do i = i + 1 end end
  local neg = false
  local c = g(i)
  if c == 43 or c == 45 then neg = c == 45; i = i + 1; c = g(i) end
  local lc = low(c)
  if lc == 105 and low(g(i + 1)) == 110 and low(g(i + 2)) == 102 then
    i = i + 3
    if low(g(i)) == 105 and low(g(i + 1)) == 110 and low(g(i + 2)) == 105 and low(g(i + 3)) == 116 and low(g(i + 4)) == 121 then i = i + 5 end
    ERANGE = false
    return neg and -huge or huge, i
  end
  if lc == 110 and low(g(i + 1)) == 97 and low(g(i + 2)) == 110 then
    i = i + 3
    local v = neg and DNAN or QNAN
    if g(i) == 40 then
      local k = i + 1
      while true do
        local x = g(k)
        if (x >= 48 and x <= 57) or (low(x) >= 97 and low(x) <= 122) or x == 95 then k = k + 1 else break end
      end
      if g(k) == 41 then
        local pl = k == i + 1 and 0 or c_unsigned(ssub(t, i + 1, k - 1))
        if pl ~= nil then
          v = bits2d(0x7FF8000000000000 | (pl & ((1 << 51) - 1)))
          if neg then v = -v end
        end
        i = k + 1
      end
    end
    ERANGE = false
    return v, i
  end
  if c == 48 and (g(i + 1) | 0x20) == 120 then
    local k, nh, nz = i + 2, 0, false
    local parts = { neg and "-0x" or "0x" }
    while hexval(g(k)) >= 0 do parts[#parts + 1] = schar(g(k)); if g(k) ~= 48 then nz = true end k = k + 1; nh = nh + 1 end
    if g(k) == 46 then
      local k2, fr = k + 1, { "." }
      while hexval(g(k2)) >= 0 do fr[#fr + 1] = schar(g(k2)); if g(k2) ~= 48 then nz = true end k2 = k2 + 1 end
      if nh + #fr - 1 > 0 then parts[#parts + 1] = tconcat(fr); nh = nh + #fr - 1; k = k2 end
    end
    if nh == 0 then ERANGE = false; return neg and -0.0 or 0.0, i + 1 end    -- "0x" with no hex digit: the "0"
    local ex = "p0"
    if (g(k) | 0x20) == 112 then
      local k2, es = k + 1, ""
      if g(k2) == 43 or g(k2) == 45 then es = g(k2) == 45 and "-" or ""; k2 = k2 + 1 end
      if g(k2) >= 48 and g(k2) <= 57 then
        local d = {}
        while g(k2) >= 48 and g(k2) <= 57 do d[#d + 1] = schar(g(k2)); k2 = k2 + 1 end
        local ed = tconcat(d):gsub("^0+", "")
        if #ed > 6 then ed = "999999" end
        ex = "p" .. es .. (ed == "" and "0" or ed)
        k = k2
      end
    end
    local v = tonumber(tconcat(parts) .. ex) + 0.0
    ERANGE = (v == 0 and nz) or v == huge or v == -huge
    return v, k
  end
  local digs = {}
  local nd, nfrac = 0, 0
  local st = i
  while g(i) >= 48 and g(i) <= 57 do digs[#digs + 1] = schar(g(i)); i = i + 1; nd = nd + 1 end
  if g(i) == 46 then
    i = i + 1
    while g(i) >= 48 and g(i) <= 57 do digs[#digs + 1] = schar(g(i)); i = i + 1; nd = nd + 1; nfrac = nfrac + 1 end
  end
  if nd == 0 then ERANGE = false; return 0.0, -1 end
  local ev = 0
  local ex = "e0"
  if low(g(i)) == 101 then
    local k = i + 1
    local es = ""
    if g(k) == 43 or g(k) == 45 then es = g(k) == 45 and "-" or ""; k = k + 1 end
    if g(k) >= 48 and g(k) <= 57 then
      local d = {}
      while g(k) >= 48 and g(k) <= 57 do d[#d + 1] = schar(g(k)); k = k + 1 end
      local ed = tconcat(d):gsub("^0+", "")
      if #ed > 9 then ed = "999999999" end
      ex = "e" .. es .. (ed == "" and "0" or ed)
      ev = tonumber(ed == "" and "0" or ed) * (es == "-" and -1 or 1)
      i = k
    end
  end
  local all = tconcat(digs)
  local v = tonumber((neg and "-" or "") .. (nfrac > 0 and (ssub(all, 1, nd - nfrac) .. "." .. ssub(all, nd - nfrac + 1)) or all) .. ex)
  if v == nil then error("strtod: " .. all .. ex) end
  local av = v < 0 and -v or v
  if av > DBL_MIN and av < huge then ERANGE = false
  else
    local ds = all:gsub("^0+", "")
    ERANGE = dec_range(ds, ev - nfrac, #ds, av)
  end
  return v, i
end
_ENV.scan_double = function(t, i, skip)
  local v, e = scan_double(t, i + 1, skip)
  if e < 0 then return v, -1 end
  return v, e - 1
end
function R_strtod_CPtr(p) local v, e = scan_double(cbs(p), 1, true); if e >= 0 then return v end return 0.0 end
function R_strtod_CPtr_CPtrr(s, et, ek)
  local v, e = scan_double(cbs(s), 1, true)
  if e < 0 then et[ek] = s; return 0.0 end
  et[ek] = newcp(s.B, s.O + e - 1)
  return v
end
R_atof = R_strtod_CPtr
-- strtol: the value (clamped to long) and the CPtr after it
function R_strtol(s, et, ek)
  local t = cbs(s)
  local a, b, sg, d = sfind(t, "^[ \t\n\v\f\r]*([+-]?)(%d+)")
  if a == nil then if et ~= nil then et[ek] = s end return 0 end
  if et ~= nil then et[ek] = newcp(s.B, s.O + b) end
  return clamp_long(d, sg == "-")
end
function R_atoi(s) return i32(R_strtol(s)) end
function R_atol(s) return R_strtol(s) end
function R_strtol0(s) return R_strtol(s) end

-- ------------------------------------------------------------------------------------------------ sscanf
local SetI = lua_class("SetI")
function SetI.Set(s, v) s.f(v) end
local SetL = lua_class("SetL", SetI); local SetD = lua_class("SetD", SetI); local SetF = lua_class("SetF", SetI)
local ScanSlot = lua_class("ScanSlot")
function R_RefI(f) return setmetatable({ f = f }, SetI) end
function R_RefL(f) return setmetatable({ f = f }, SetL) end
function R_RefD(f) return setmetatable({ f = f }, SetD) end
function R_RefF(f) return setmetatable({ f = f }, SetF) end
R_Slot = setmetatable({}, ScanSlot)
local STASH = {}
local function overflow_exc() return NewSysException("OverflowException", "Value was either too large or too small.") end
local function conv_int(v, lo, hi) if not (v >= lo and v <= hi) then error(overflow_exc(), 0) end return v end
function R_Back_i_T1r__B(n, t, k) local v = STASH[1]; if v ~= nil then t[k] = conv_int(v, -128, 255) end return n end
function R_Back_i_T1r__S(n, t, k) local v = STASH[1]; if v ~= nil then t[k] = conv_int(v, -32768, 65535) end return n end
function R_Back_i_T1r__I(n, t, k) local v = STASH[1]; if v ~= nil then t[k] = conv_int(v, -2147483648, 0xFFFFFFFF) end return n end
function R_Back_i_T1r__L(n, t, k) local v = STASH[1]; if v ~= nil then t[k] = v end return n end
function R_Back_i_T1r__D(n, t, k) local v = STASH[1]; if v ~= nil then t[k] = v end return n end
function R_Back_i_T1r__F(n, t, k) local v = STASH[1]; if v ~= nil then t[k] = f32(v) end return n end
function R_Back_i_T1r__Z(n, t, k) local v = STASH[1]; if v ~= nil then t[k] = v ~= 0 end return n end
function R_Back_i_T1r_T2r__LB(n, t, k, t2, k2)
  local v = STASH[1]; if v ~= nil then t[k] = v end
  v = STASH[2]; if v ~= nil then t2[k2] = conv_int(v, -128, 255) end
  return n
end

local SCF = {}
local function scan_compile(f)
  local out = {}
  local k, n = 1, #f
  while k <= n do
    local c = sbyte(f, k)
    if SPACE[c] then while k <= n and SPACE[sbyte(f, k)] do k = k + 1 end out[#out + 1] = { "w" }
    elseif c ~= 37 then out[#out + 1] = { "l", c }; k = k + 1
    else
      k = k + 1
      local suppress = false
      if ssub(f, k, k) == "*" then suppress = true; k = k + 1 end
      local width = 0
      while k <= n and sbyte(f, k) >= 48 and sbyte(f, k) <= 57 do width = width * 10 + sbyte(f, k) - 48; k = k + 1 end
      local lmod = 0
      while k <= n and sfind("lhLzjtq", ssub(f, k, k), 1, true) do if ssub(f, k, k) ~= "h" then lmod = lmod + 1 end k = k + 1 end
      local conv = k <= n and sbyte(f, k) or 0
      k = k + 1
      local cset
      if conv == 91 then
        local s = {}
        local neg = false
        if ssub(f, k, k) == "^" then neg = true; k = k + 1 end
        local first = true
        while k <= n and (first or ssub(f, k, k) ~= "]") do
          local ch = sbyte(f, k)
          if ch == 45 and not first and k + 1 <= n and ssub(f, k + 1, k + 1) ~= "]" and sbyte(f, k - 1) <= sbyte(f, k + 1) then
            for x = sbyte(f, k - 1), sbyte(f, k + 1) do s[x] = true end
            k = k + 2; first = false
          else s[ch] = true; k = k + 1; first = false end
        end
        if ssub(f, k, k) == "]" then k = k + 1 end
        if neg then local t = {}; for x = 1, 255 do if not s[x] then t[x] = true end end s = t end
        cset = s
      end
      out[#out + 1] = { "p", suppress, width, lmod, conv, cset }
    end
  end
  return out
end
local function wrap_lmod(v, lmod) if lmod ~= 0 then return v end return i32(v) end
local function store_int(a, v, lmod, t, k)
  if t ~= nil then t[k] = wrap_lmod(v, lmod); return end
  local mt = getmetatable(a)
  if mt == SetL then a:Set(v)
  elseif mt == SetI then a:Set(i32(v))
  elseif mt == ScanSlot then STASH[#STASH + 1] = wrap_lmod(v, lmod)
  else error("sscanf integer target") end
end
local function store_buf(a, data)
  if getmetatable(a) == Cpp_CPtr then put(a, 0, data)
  elseif isa_(a, Cpp_Ptr) then for i = 1, #data do local x = sbyte(data, i); if x > 127 then x = x - 256 end a.a[a.o + i - 1] = x end
  else error("sscanf string target") end
end
local function store_float(a, v, lmod)
  local mt = getmetatable(a)
  if mt == SetD then a:Set(v)
  elseif mt == SetF then a:Set(f32(v))
  elseif mt == ScanSlot then STASH[#STASH + 1] = lmod ~= 0 and v or f32(v)
  else error("sscanf float target") end
end
-- glibc's scanf float reader: the longest prefix of the number syntax it accepts: (end 1-based index, the text) or -1
local function scan_float(b, i, width)
  local n = #b
  local left = width > 0 and width or -1
  local p = i
  local buf = {}
  local function inchar() if p <= n then p = p + 1; return sbyte(b, p - 1) end return -1 end
  local function dec() if left > 0 then left = left - 1 end end
  local function lw(c) if c >= 65 and c <= 90 then return c | 0x20 end return c end
  local function expect(ch) if left == 0 then return false end local c = inchar(); if c < 0 or lw(c) ~= ch then return false end dec(); buf[#buf + 1] = schar(c); return true end
  local c = inchar()
  dec()
  local got_sign = 0
  if c == 45 or c == 43 then
    got_sign = 1; buf[#buf + 1] = schar(c)
    if left == 0 then return -1 end
    c = inchar()
    if c < 0 then return -1 end
    dec()
  end
  if c >= 0 and lw(c) == 110 then
    buf[#buf + 1] = schar(c)
    if not (expect(97) and expect(110)) then return -1 end
    return p, tconcat(buf)
  end
  if c >= 0 and lw(c) == 105 then
    buf[#buf + 1] = schar(c)
    if not (expect(110) and expect(102)) then return -1 end
    if left ~= 0 then
      c = inchar()
      if c >= 0 then
        if lw(c) == 105 then
          dec(); buf[#buf + 1] = schar(c)
          if not (expect(110) and expect(105) and expect(116) and expect(121)) then return -1 end
        else p = p - 1 end
      end
    end
    return p, tconcat(buf)
  end
  local exp_char = 101
  local hexa, got_digit, got_dot, got_e = false, false, false, false
  if left ~= 0 and c == 48 then
    buf[#buf + 1] = schar(c)
    c = inchar(); dec()
    if left ~= 0 and c >= 0 and lw(c) == 120 then buf[#buf + 1] = schar(c); hexa = true; exp_char = 112; c = inchar(); dec()
    else got_digit = true end
  end
  while true do
    if c >= 48 and c <= 57 then buf[#buf + 1] = schar(c); got_digit = true
    elseif not got_e and hexa and c >= 0 and lw(c) >= 97 and lw(c) <= 102 then buf[#buf + 1] = schar(c); got_digit = true
    elseif got_e and #buf > 0 and sbyte(buf[#buf], 1) == exp_char and (c == 45 or c == 43) then buf[#buf + 1] = schar(c)
    elseif got_digit and not got_e and c >= 0 and lw(c) == exp_char then buf[#buf + 1] = schar(exp_char); got_e = true; got_dot = true
    elseif not got_dot and c == 46 then buf[#buf + 1] = schar(c); got_dot = true
    else if c >= 0 then p = p - 1 end break end
    if left == 0 then break end
    c = inchar()
    if c < 0 then break end
    dec()
  end
  local s = tconcat(buf)
  if #s == got_sign or (hexa and #s == 2 + got_sign) then return -1 end
  return p, s
end
function R_sscanf(s, fmt, ...)
  local args = { ... }
  local nargs = select("#", ...)
  STASH = {}
  local b = cbs(s)
  local fb = cbs(fmt)
  local dirs = SCF[fb]
  if dirs == nil then dirs = scan_compile(fb); SCF[fb] = dirs end
  local n = #b
  local i, ai, count = 1, 1, 0
  for _, d in ipairs(dirs) do
    local op = d[1]
    if op == "w" then while i <= n and SPACE[sbyte(b, i)] do i = i + 1 end
    elseif op == "l" then
      if i > n then return count == 0 and -1 or count end
      if sbyte(b, i) ~= d[2] then return count end
      i = i + 1
    else
      local suppress, width, lmod, conv, cset = d[2], d[3], d[4], d[5], d[6]
      if conv ~= 99 and conv ~= 91 and conv ~= 110 then while i <= n and SPACE[sbyte(b, i)] do i = i + 1 end end
      if conv == 110 then
        if not suppress then store_int(args[ai], i - 1, lmod); ai = ai + 1 end
        goto next_dir
      end
      if i > n then return count == 0 and -1 or count end
      local w = width > 0 and width or (1 << 30)
      if conv == 100 or conv == 105 or conv == 117 then
        local j, lim, neg = i, i + w, false
        if j < lim and (sbyte(b, j) == 43 or sbyte(b, j) == 45) then neg = sbyte(b, j) == 45; j = j + 1 end
        local ds = j
        local e = lim < n + 1 and lim or n + 1
        while j < e and sbyte(b, j) >= 48 and sbyte(b, j) <= 57 do j = j + 1 end
        if j == ds then return count end
        local txt = ssub(b, ds, j - 1):gsub("^0+(%d)", "%1")
        i = j
        local v
        local big = #txt > 20 or (#txt == 20 and txt > "18446744073709551615")
        if conv == 117 then
          local u = big and -1 or c_unsigned(txt)
          if neg and not big then u = -u end
          v = lmod == 0 and (u & 0xFFFFFFFF) or u
        else
          v = clamp_long(txt, neg)
        end
        if not suppress then store_int(args[ai], v, lmod); ai = ai + 1; count = count + 1 end
      elseif conv == 102 or conv == 101 or conv == 69 or conv == 103 or conv == 71 or conv == 97 or conv == 65 or conv == 70 then
        local e, num = scan_float(b, i, width)
        if e < 0 then return count end
        i = e
        local v, ne = scan_double(num, 1, false)
        if ne <= 1 then return count end
        if not suppress then store_float(args[ai], v, lmod); ai = ai + 1; count = count + 1 end
      elseif conv == 115 or conv == 91 then
        local j = i
        local e = i + w < n + 1 and i + w or n + 1
        if conv == 115 then while j < e and not SPACE[sbyte(b, j)] do j = j + 1 end
        else while j < e and cset[sbyte(b, j)] do j = j + 1 end end
        if j == i then return count end
        if not suppress then store_buf(args[ai], ssub(b, i, j - 1) .. "\0"); ai = ai + 1; count = count + 1 end
        i = j
      elseif conv == 99 then
        local m = width > 0 and width or 1
        local j = i + m < n + 1 and i + m or n + 1
        if not suppress then
          local a = args[ai]; ai = ai + 1
          local c = sbyte(b, i)
          local sc = c > 127 and c - 256 or c
          local mt = getmetatable(a)
          if mt == SetI then a:Set(sc)
          elseif mt == ScanSlot then for k = i, j - 1 do local x = sbyte(b, k); STASH[#STASH + 1] = x > 127 and x - 256 or x end
          elseif mt == Cpp_CPtr or isa_(a, Cpp_Ptr) then store_buf(a, ssub(b, i, j - 1))
          else error("sscanf %c target") end
          count = count + 1
        end
        i = j
      elseif conv == 37 then
        if sbyte(b, i) ~= 37 then return count end
        i = i + 1
      else error("sscanf %" .. schar(conv)) end
    end
    ::next_dir::
  end
  return count
end

-- ------------------------------------------------------------------------------------------------ printf
local FC = {}
local function fmt_compile(fb)
  local segs = {}
  local i, n, lit = 1, #fb, 1
  while i <= n do
    if ssub(fb, i, i) ~= "%" then i = i + 1
    else
      if i > lit then segs[#segs + 1] = ssub(fb, lit, i - 1) end
      i = i + 1
      if ssub(fb, i, i) == "%" then segs[#segs + 1] = "%"; i = i + 1; lit = i
      else
        local fl = { left = false, plus = false, space = false, alt = false, zero = false }
        while i <= n do
          local c = ssub(fb, i, i)
          if c == "-" then fl.left = true elseif c == "+" then fl.plus = true elseif c == " " then fl.space = true
          elseif c == "#" then fl.alt = true elseif c == "0" then fl.zero = true else break end
          i = i + 1
        end
        local width = 0
        if ssub(fb, i, i) == "*" then width = -1; i = i + 1
        else while i <= n and sbyte(fb, i) >= 48 and sbyte(fb, i) <= 57 do width = width * 10 + sbyte(fb, i) - 48; i = i + 1 end end
        local prec = -1
        if ssub(fb, i, i) == "." then
          i = i + 1; prec = 0
          if ssub(fb, i, i) == "*" then prec = -2; i = i + 1
          else while i <= n and sbyte(fb, i) >= 48 and sbyte(fb, i) <= 57 do prec = prec * 10 + sbyte(fb, i) - 48; i = i + 1 end end
        end
        local size = 32
        while i <= n do
          local c = ssub(fb, i, i)
          if c == "h" then size = size == 16 and 8 or 16
          elseif sfind("lLqjzt", c, 1, true) then size = 64
          else break end
          i = i + 1
        end
        local conv = i <= n and ssub(fb, i, i) or ""
        i = i + 1; lit = i
        fl.width = width; fl.prec = prec; fl.size = size; fl.conv = conv
        segs[#segs + 1] = fl
      end
    end
  end
  if lit <= n then segs[#segs + 1] = ssub(fb, lit, n) end
  return segs
end
local function argint(a)
  if type(a) == "table" then
    local v = a.v
    if type(v) == "boolean" then return v and 1 or 0 end
    if mtype(v) == "float" then return f2i64(v) end
    return v
  end
  if type(a) == "boolean" then return a and 1 or 0 end
  if mtype(a) == "float" then return f2i64(a) end
  return a
end
local function argf(a) if type(a) == "table" then return a.v end if mtype(a) == "integer" then return a + 0.0 end return a end
local function argstr(a)
  if a == nil then return nil end
  if type(a) == "string" then return a end
  local mt = getmetatable(a)
  if mt == Cpp_CPtr then if a.B ~= nil then return cbs(a) end return nil end
  if mt == Cpp_Str then return str_text(a) end
  if isa_(a, Cpp_Ptr) then if a.a ~= nil then return cbs(newcp(a.a, a.o)) end return nil end
  error("printf: string argument")
end
local function sgn_n(v, size)
  if size == 64 then return v end
  local m = (1 << size) - 1
  v = v & m
  local h = 1 << (size - 1)
  if v >= h then return v - (m + 1) end
  return v
end
-- the spec string.format accepts for the flags in allowed (width and precision at most 99)
local function spec(fl, allowed, width, prec, conv)
  local f = { "%" }
  if fl.left and sfind(allowed, "-", 1, true) then f[#f + 1] = "-" end
  if fl.plus and sfind(allowed, "+", 1, true) then f[#f + 1] = "+" end
  if fl.space and sfind(allowed, " ", 1, true) then f[#f + 1] = " " end
  if fl.alt and sfind(allowed, "#", 1, true) then f[#f + 1] = "#" end
  if fl.zero and sfind(allowed, "0", 1, true) then f[#f + 1] = "0" end
  if width > 0 then f[#f + 1] = tostring(width) end
  if prec >= 0 then f[#f + 1] = "." .. prec end
  f[#f + 1] = conv
  return tconcat(f)
end
local function pad(fl, width, body, numeric)
  -- body includes its sign and prefix; zero padding goes after them (numeric)
  local m = #body
  if m >= width then return body end
  if fl.left then return body .. srep(" ", width - m) end
  if fl.zero and numeric then
    local k = 0
    local c = ssub(body, 1, 1)
    if c == "-" or c == "+" or c == " " then k = 1 end
    if ssub(body, k + 1, k + 2) == "0x" or ssub(body, k + 1, k + 2) == "0X" then k = k + 2 end
    return ssub(body, 1, k) .. srep("0", width - m) .. ssub(body, k + 1)
  end
  return srep(" ", width - m) .. body
end
function fmt_float(v, prec, conv) return sformat("%." .. prec .. conv, v) end
local function format_c(fmt, args, na)
  local fb = type(fmt) == "string" and fmt or cbs(fmt)
  local segs = FC[fb]
  if segs == nil then segs = fmt_compile(fb); FC[fb] = segs end
  local out = {}
  local ai = 1
  for _, seg in ipairs(segs) do
    if type(seg) == "string" then out[#out + 1] = seg
    else
      local width, prec, size, conv = seg.width, seg.prec, seg.size, seg.conv
      local fl = seg
      if width == -1 then
        width = i32(argint(args[ai])); ai = ai + 1
        if width < 0 then fl = setmetatable({ left = true }, { __index = seg }); width = -width end
      end
      if prec == -2 then prec = i32(argint(args[ai])); ai = ai + 1; if prec < 0 then prec = -1 end end
      if ai > na and conv ~= "" then error(NewSysException("IndexOutOfRangeException", "printf: too few arguments"), 0) end
      local a = args[ai]; ai = ai + 1
      local wide = width > 99 or prec > 99
      local s
      if conv == "d" or conv == "i" then
        local v = sgn_n(argint(a), size)
        if wide then
          s = sformat(spec(fl, "+ ", 0, prec > 99 and -1 or prec, "d"), v)
          if prec > 99 then
            local sg, d = smatch(s, "^([-+ ]?)(%d*)$")
            if prec == 0 and v == 0 then d = "" end
            if #d < prec then d = srep("0", prec - #d) .. d end
            s = sg .. d
          end
          s = pad(fl, width, s, prec < 0)
        else s = sformat(spec(fl, "-+ 0", width, prec, "d"), v) end
      elseif conv == "u" or conv == "x" or conv == "X" or conv == "o" then
        local u = argint(a)
        if size ~= 64 then u = u & ((1 << size) - 1) end
        if wide then
          s = sformat(spec(fl, "#", 0, prec > 99 and -1 or prec, conv), u)
          if prec > 99 then
            local pre, d = smatch(s, "^(0?[xX]?)(%x*)$")
            if #d < prec then d = srep("0", prec - #d) .. d end
            s = pre .. d
          end
          s = pad(fl, width, s, prec < 0)
        else s = sformat(spec(fl, conv == "u" and "-0" or "-#0", width, prec, conv), u) end
      elseif conv == "c" then
        s = pad(fl, width, schar(argint(a) & 255), false)
      elseif conv == "s" then
        local p = argstr(a)
        local body
        if p == nil then body = (prec < 0 or prec >= 6) and "(null)" or "" elseif prec >= 0 then body = ssub(p, 1, prec) else body = p end
        s = pad(fl, width, body, false)
      elseif conv ~= "" and sfind("fFeEgGaA", conv, 1, true) then
        local v = argf(a)
        if wide then
          s = sformat(spec(fl, "+ #", 0, prec, conv), v)        -- glibc's digits: string.format passes any precision through
          s = pad(fl, width, s, v == v and v ~= huge and v ~= -huge)
        else s = sformat(spec(fl, "-+ #0", width, prec, conv), v) end
      else error("printf %" .. conv) end
      out[#out + 1] = s
    end
  end
  return tconcat(out)
end
_ENV.format_c = format_c
function R_Format(fmt, ...) return format_c(fmt, { ... }, select("#", ...)) end
function R_fprintf(f, fmt, ...)
  local b = format_c(fmt, { ... }, select("#", ...))
  if f == nil then return -1 end
  f:write(b)
  return #b
end
function R_snprintf_CPtr_ul_CPtr_oA(buf, n, fmt, ...)
  local b = format_c(fmt, { ... }, select("#", ...))
  if n ~= 0 then
    local m = #b
    if ult(n - 1, m) then m = n - 1 end
    put(buf, 0, ssub(b, 1, m) .. "\0")
  end
  return #b
end
R_snprintf_CPtr_l_CPtr_oA = R_snprintf_CPtr_ul_CPtr_oA
R_snprintf_CPtr_i_CPtr_oA = function(buf, n, fmt, ...) return R_snprintf_CPtr_ul_CPtr_oA(buf, n, fmt, ...) end
function R_sprintf(buf, fmt, ...)
  local b = format_c(fmt, { ... }, select("#", ...))
  if buf.O + #b + 1 > buf.B.n then
    error(NewSysException("ArgumentException", "Destination array was not long enough. Check the destination index, length, and the array's lower bounds. (Parameter 'destinationArray')"), 0)
  end
  put(buf, 0, b .. "\0")
  return #b
end

-- ------------------------------------------------------------------------------------------------ stdio
-- a FILE*: { fh (a Lua file), eof, std, floor, dir, err, pend (bytes read ahead by fgets) }
local CFile = lua_class("CFile")
Cpp_CFile = CFile
local OPEN = setmetatable({}, { __mode = "k" })
local function cfile(fh, std)
  local f = setmetatable({ fh = fh, eof = false, std = std or 0, floor = 0, dir = false, err = false, pend = "" }, CFile)
  if not std then OPEN[f] = true end
  return f
end
function CFile.ReadFailed(f) if f.dir then f.err = true else f.eof = true end end
function CFile.write(f, b)
  if f.fh == nil then return #b end
  if #f.pend > 0 then f.fh:seek("cur", -#f.pend); f.pend = "" end
  f.fh:write(b)
  return #b
end
function CFile.read(f, n)
  if f.fh == nil then return nil end
  local r = ""
  if #f.pend > 0 then r = ssub(f.pend, 1, n); f.pend = ssub(f.pend, #r + 1); n = n - #r end
  if n > 0 then local x = f.fh:read(n); if x then r = r .. x end end
  if #r > 0 then return r end
  return nil
end
function CFile.gets(f, limit)
  if f.fh == nil then return nil end
  local line = f.pend
  f.pend = ""
  if not sfind(line, "\n", 1, true) and #line < limit then
    local more = f.fh:read("L")
    if more then line = line .. more end
  end
  if line == "" then return nil end
  local k = sfind(line, "\n", 1, true)
  local take
  if k ~= nil and k <= limit then take = k else take = limit < #line and limit or #line end
  f.pend = ssub(line, take + 1)
  return ssub(line, 1, take)
end
function CFile.pos(f) if f.fh ~= nil then return f.fh:seek("cur") - #f.pend end return 0 end
function CFile.seek_(f, p, wh)
  f.pend = ""
  if f.fh == nil then return false end
  local r = f.fh:seek(wh == 2 and "end" or (wh == 1 and "cur" or "set"), p)
  return r ~= nil
end
function CFile.flush(f) if f.fh ~= nil then f.fh:flush() end end
function CFile.close(f) if f.fh ~= nil then f.fh:close(); f.fh = nil end OPEN[f] = nil end
R_stdout_ = cfile(io.stdout, 1)
R_stderr_ = cfile(io.stderr, 2)
io.stdout:setvbuf("full")
-- whether a path names a directory: it opens for reading, and reading it fails with EISDIR
local function is_dir(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local ok, _, code = f:read(1)
  f:close()
  return ok == nil and code == 21
end
_ENV.is_dir = is_dir
function R_fopen(name, mode)
  local fn, m = cbs(name), cbs(mode)
  if m == "" then return nil end
  local plus = sfind(m, "+", 1, true) ~= nil
  local c = ssub(m, 1, 1)
  if c == "r" and not plus and is_dir(fn) then local d = cfile(nil); d.dir = true; return d end
  local fh
  if c == "r" then fh = io.open(fn, plus and "r+b" or "rb")
  elseif c == "w" then fh = io.open(fn, plus and "w+b" or "wb")
  elseif c == "a" then if is_dir(fn) then return nil end fh = io.open(fn, "ab")
  else return nil end
  if not fh then return nil end
  local f = cfile(fh)
  if c == "a" then f.floor = fh:seek("end") end
  return f
end
function R_fclose(f) if f == nil then return -1 end if f.std ~= 0 then f:flush() else f:close() end return 0 end
function R_FlushAll() for f in pairs(OPEN) do pcall(CFile.flush, f) end R_stdout_:flush() end
function R_fflush(f) if f == nil then R_FlushAll() else f:flush() end return 0 end
function R_feof(f) return f.eof and 1 or 0 end
function R_ferror(f) return (f ~= nil and f.err) and 1 or 0 end
function R_rewind(f) f:seek_(0, 0); f.eof = false end
function R_fseek_CFile_l_i(f, off, wh)
  local p
  if wh == 0 then p = off elseif wh == 1 then p = f:pos() + off else f:seek_(0, 2); p = f.fh:seek("cur") + off end
  if p < f.floor then return -1 end
  if not f:seek_(p, 0) then return -1 end
  f.eof = false
  return 0
end
R_fseek_CFile_i_i = R_fseek_CFile_l_i
function R_ftell(f) return f:pos() end
function R_fgets(buf, n, f)
  if n <= 1 then return CPtr_ZERO end
  local line = f:gets(n - 1)
  if line == nil or (#line < n - 1 and ssub(line, -1) ~= "\n") then f:ReadFailed() end
  if line == nil or line == "" then return CPtr_ZERO end
  put(buf, 0, line .. "\0")
  return buf
end
function R_fgetc(f) local b = f:read(1); if b == nil then f:ReadFailed(); return -1 end return sbyte(b) end
function R_fileno() return 3 end
function R_setvbuf() return 0 end
function R_remove(p) if os.remove(cbs(p)) then return 0 end return -1 end
function R_rename(a, b) if os.rename(cbs(a), cbs(b)) then return 0 end return -1 end
-- the four bytes of C's (float) of a double: a NaN keeps its sign and the top of its payload, quieted (cvtsd2ss)
function float_bytes(x)
  if x == x then return spack("<f", x) end
  local b = sunpack("<i8", spack("<d", x))
  return spack("<I4", ((b >> 32) & 0x80000000) | 0x7FC00000 | ((b >> 29) & 0x3FFFFF))
end
local float_bytes = float_bytes
function R_fwriteF1(v, f) f:write(float_bytes(f32(v))); return 1 end
function R_fwriteD1(v, f) f:write(spack("<d", v)); return 1 end
function R_fwriteI1(v, f) f:write(spack("<I4", v & 0xFFFFFFFF)); return 1 end
function R_fwriteL1(v, f) f:write(spack("<i8", v)); return 1 end
local function read_exact(f, n) local b = f:read(n); if b == nil or #b < n then f:ReadFailed(); return nil end return b end
function R_freadF1(t, k, f) local b = read_exact(f, 4); if b == nil then return 0 end t[k] = (sunpack("<f", b)); return 1 end
function R_freadD1(t, k, f) local b = read_exact(f, 8); if b == nil then return 0 end t[k] = (sunpack("<d", b)); return 1 end
function R_freadI1(t, k, f) local b = read_exact(f, 4); if b == nil then return 0 end t[k] = (sunpack("<i4", b)); return 1 end
function R_freadL1(t, k, f) local b = read_exact(f, 8); if b == nil then return 0 end t[k] = (sunpack("<i8", b)); return 1 end
function R_time() return os.time() end
function R_time_Ptrl(p) local t = os.time(); if not p:get_IsNull() then p:set_Item_i(0, t) end return t end
function R_time_o() return os.time() end
function R_difftime(a, b) return (a - b) + 0.0 end
function R_ctime_l(t) return R_Lit(os.date("%a %b %e %H:%M:%S %Y\n", t)) end
function R_ctime_Ptrl(p) return R_ctime_l(p:get_Item_i(0)) end
function R_getenv(p) local v = os.getenv(cbs(p)); if v ~= nil then return newcp(str_bytes(v, true), 0) end return CPtr_ZERO end
function R_strncpy(d, s, n)
  local m = i32(n)
  if m <= 0 then return d end
  local db, dO, sb, sO = d.B, d.O, s.B, s.O
  local i = 0
  while i < m and sb[sO + i] & 255 ~= 0 do db[dO + i] = sb[sO + i] & 255; i = i + 1 end
  while i < m do db[dO + i] = 0; i = i + 1 end
  return d
end
function R_strncmp(a, b, n)
  local m = i32(n)
  for i = 0, m - 1 do
    local x = a.B[a.O + i] & 255; local y = b.B[b.O + i] & 255
    if x ~= y then return x - y end
    if x == 0 then return 0 end
  end
  return 0
end
function R_memcmp(a, b, n)
  local m = i32(n)
  for i = 0, m - 1 do local p = a.B[a.O + i] & 255; local q = b.B[b.O + i] & 255; if p ~= q then return p - q end end
  return 0
end
function R_memcpyBuf(d, s)
  local k = d.B.n - d.O
  local k2 = s.B.n - s.O
  if k2 < k then k = k2 end
  if k <= 0 then return end
  tmove(s.B, s.O, s.O + k - 1, d.O, d.B)
end

-- ------------------------------------------------------------------------------------------------ math
-- Lua's math functions call the C library. lupa's Lua refers to them without symbol versions, so the dynamic linker
-- binds each to its oldest version: exp, sin, cos, tan, asin, acos, sqrt, atan2 and log10 are the symbols the C++ engine
-- imports, or (exp) a compatibility wrapper that changes no value; log, log2 and fmod are the older SVID-compatible
-- versions, which differ only where corrected here (a negative argument of log and log2; the NaN fmod returns), and
-- pow's older version gives the same values (lua/results/libm_tests.txt). pow with the exponent 2 (Lua's ^ is x * x
-- then), atan (Lua's math.atan(x) is atan2(x, 1)) and the functions Lua 5.4 does not have (sinh, cosh, tanh, expm1,
-- log1p, cbrt, hypot) are glibc's own code translated (glibm.lua). The NaN a function of two arguments returns when
-- both are NaNs is the one glibc's code gives on x86 (fmod: x's; remainder, nextafter: y's), written out here.
local quiet = GlibmRT.quiet
local TWO52 = 4503599627370496.0
function Math_Sqrt_d(x) return m_sqrt(x) end
function Math_Log_d(x) if x < 0 then return DNAN end return m_log(x) end
LibM_log = Math_Log_d
function Math_Log10_d(x) return m_log(x, 10) end
function Math_Log2_d(x) if x < 0 then return DNAN end return m_log(x, 2) end
function Math_Exp_d(x) return m_exp(x) end
function Math_Sin_d(x) return m_sin(x) end
function Math_Cos_d(x) return m_cos(x) end
function Math_Tan_d(x) return m_tan(x) end
function Math_Asin_d(x) return m_asin(x) end
function Math_Acos_d(x) return m_acos(x) end
function Math_Atan2_d(y, x) return m_atan(y, x) end
function Math_Atan_d(x) return Glibm_atan(x) end
function Math_Pow_d(x, y) if y == 2 then return Glibm_pow(x, y) end return x ^ y end
function Math_Sinh_d(x) return Glibm_sinh(x) end
function Math_Cosh_d(x) return Glibm_cosh(x) end
function Math_Tanh_d(x) return Glibm_tanh(x) end
function Math_Cbrt_d(x) return Glibm_cbrt(x) end
function LibM_expm1(x) return Glibm_expm1(x) end
function LibM_log1p(x) return Glibm_log1p(x) end
function LibM_hypot(x, y) return Glibm_hypot(x, y) end
-- C's fmod (fmod@GLIBC_2.38): a NaN argument comes back quieted, x's when both are NaNs; (x * 1.0: never Lua's integer %)
function LibM_fmod(x, y)
  if x ~= x then return quiet(x) end
  if y ~= y then return quiet(y) end
  return m_fmod(x * 1.0, y)
end
L_math_exp, L_math_sin, L_math_cos, L_math_sqrt, L_math_abs, L_math_fmod = m_exp, m_sin, m_cos, m_sqrt, m_abs, LibM_fmod
function Math_CopySign_d(x, y) if signbit(x) == signbit(y) then return x end return -x end
function Math_Floor_d(x) return x // 1.0 end
function Math_Ceiling_d(x) return -((-x) // 1.0) end
function Math_Truncate_d(x) if x >= 0 then return x // 1.0 end return -((-x) // 1.0) end
-- C#'s Math.Round: to the nearest integer, ties to even
function Math_Round_d(x)
  if not (x > -TWO52 and x < TWO52) then return x + 0.0 end
  local r = (x + 0.5) // 1.0
  if r - x == 0.5 and m_fmod(r, 2.0) ~= 0 then r = r - 1.0 end
  if r == 0 then return signbit(x) and -0.0 or 0.0 end
  return r
end
function Math_Max_d_d(a, b) if a ~= a then return a end if b ~= b then return b end if a == b then if signbit(a) then return b end return a end if a > b then return a end return b end
function Math_Min_d_d(a, b) if a ~= a then return a end if b ~= b then return b end if a == b then if signbit(a) then return a end return b end if a < b then return a end return b end
function Math_Abs_d(x) return m_abs(x) end
function Math_Abs_i(x) if x < 0 then return -x end return x end
-- C's round: to the nearest integer, ties away from zero
function LibM_round(x)
  if not (x > -TWO52 and x < TWO52) then return x + 0.0 end
  local t = x >= 0 and x // 1.0 or -((-x) // 1.0)
  local d = x - t
  if d >= 0.5 then t = t + 1.0 elseif d <= -0.5 then t = t - 1.0 end
  if t == 0 then return signbit(x) and -0.0 or 0.0 end
  return t
end
function LibM_lround(x)
  local r = LibM_round(x)
  if r ~= r or r >= 9223372036854775808.0 or r < -9223372036854775808.0 then return mininteger end
  return f2i64(r)
end
LibM_llround = LibM_lround
-- C's nextafter: the next double after x toward y (exact bit arithmetic)
function LibM_nextafter(x, y)
  if y ~= y then return quiet(y) end           -- glibc's x + y: y's NaN when both are NaNs
  if x ~= x then return quiet(x) end
  if x == y then return y end
  if x == 0 then return y > 0 and bits2d(1) or bits2d(mininteger | 1) end
  local b = d2bits(x)
  if (x < y) == (x > 0) then b = b + 1 else b = b - 1 end
  return bits2d(b)
end
-- C's remainder (IEEE): x - n * y, n the integer nearest x / y (ties to even), exact; glibc's e_remainder.c's steps
function LibM_remainder(x, y)
  if y ~= y then return quiet(y) end           -- glibc's NaN result: y's when both are NaNs
  if x ~= x then return quiet(x) end
  if y == 0 or x == huge or x == -huge then return (x * y) / (x * y) end
  local ay = y < 0 and -y or y
  local sx = signbit(x)
  local ax = x < 0 and -x or x
  if ay <= 8.9884656743115785e307 then ax = m_fmod(ax, ay + ay) end
  if ay < 4.4501477170144028e-308 then
    if ax + ax > ay then ax = ax - ay; if ax + ax >= ay then ax = ax - ay end end
  else
    local yh = 0.5 * ay
    if ax > yh then ax = ax - ay; if ax >= yh then ax = ax - ay end end
  end
  if ax == 0 then ax = 0.0 end
  if sx then return -ax end
  return ax
end
