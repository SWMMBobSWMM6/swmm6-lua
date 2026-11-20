-- core.lua - numbers, classes, references, pointers, iterators, exceptions and C strings of the Lua runtime of the
-- SWMM6 port. From cs/runtime (Misc.cs, Std.cs, CRuntime.cs) by way of the Perl port's perl/cpp/core.pl, whose names
-- (the Python, Ruby and Perl ports' runtime contract) the engine calls.
-- Every runtime file is a chunk run with the shared environment E (the engine's _ENV) as its _ENV: what it defines
-- globally is what the engine sees. Objects are tables whose metatable is their class table (lua_class); a C# array
-- is a table with the elements at 0 .. n - 1 and the length in the field n; a C# ref is two values, a table and a key.
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and lua/README.md.
local setmetatable, getmetatable, rawget, rawset, rawequal, type, error, pairs, ipairs, tostring, tonumber, select, pcall =
  setmetatable, getmetatable, rawget, rawset, rawequal, type, error, pairs, ipairs, tostring, tonumber, select, pcall
local spack, sunpack, schar, sbyte, sformat = string.pack, string.unpack, string.char, string.byte, string.format
local mtype, ult, floor, huge, mininteger = math.type, math.ult, math.floor, math.huge, mininteger
local tunpack, tconcat, tmove = table.unpack, table.concat, table.move
local os, io, math, string, table = os, io, math, string, table
local _ENV = ...

-- ------------------------------------------------------------------------------------------------ classes
local CLASSES = {}
ENGINE_CLASSES = CLASSES
-- a class table: its own __index (so it serves as its objects' metatable), its name, the set of classes and
-- interfaces it is (__isa, keyed by class table), its base; inherit_all copies base methods down when all are defined
function lua_class(name, base, ifaces)
  local c = { __name = name, __base = base }
  c.__index = c
  local isa = { [c] = true }
  if base then for k in pairs(base.__isa) do isa[k] = true end end
  if ifaces then for i = 1, #ifaces do isa[ifaces[i]] = true end end
  c.__isa = isa
  CLASSES[#CLASSES + 1] = c
  return c
end

local SPECIAL = { __index = true, __name = true, __isa = true, __base = true }
function inherit_all()
  for i = 1, #CLASSES do
    local c = CLASSES[i]
    local b = c.__base
    if b then
      for k, v in pairs(b) do
        if not SPECIAL[k] and rawget(c, k) == nil then rawset(c, k, v) end
      end
    end
  end
end

-- the class tables of the runtime's interfaces, used only as marks in __isa
Cpp_ICopy = lua_class("ICopy"); Cpp_IDisposable = lua_class("IDisposable"); Cpp_IDestroyElems = lua_class("IDestroyElems")
Cpp_IHashFn = lua_class("IHashFn"); Cpp_IBinFn = lua_class("IBinFn")

function isa_(x, c)
  local mt = getmetatable(x)
  if mt == nil or type(mt) ~= "table" then return false end
  local s = rawget(mt, "__isa")
  return s ~= nil and s[c] == true
end
local isa_ = isa_

-- the strict guard's declarations: a global whose value is nil may still be read (declare_global)
DECLARED = {}
function declare_global(n) DECLARED[n] = true end

-- ------------------------------------------------------------------------------------------------ numbers
K_INF = huge
K_NZERO = -0.0
local DNAN = sunpack("<d", spack("<I8", 0xFFF8000000000000))   -- x86's default NaN (0/0); glibc prints it "-nan"
local QNAN = sunpack("<d", spack("<I8", 0x7FF8000000000000))
K_DNAN = DNAN; K_QNAN = QNAN
Std_QNaN = QNAN

function f64_from_bits(b) return (sunpack("<d", spack("<i8", b))) end
function f64_to_bits_signed(x) return (sunpack("<i8", spack("<d", x))) end
function signbit(x) return sbyte(spack("<d", x), 8) >= 128 end
local signbit = signbit
function is_nan(x) return x ~= x end
function is_inf(x) return x == huge or x == -huge end
function is_finite(x) return x == x and x ~= huge and x ~= -huge end

-- C# integer division and remainder (truncating); Lua's // and % floor. A zero divisor raises Lua's error, which
-- exc_of reads as .NET's DivideByZeroException.
function idiv(a, b)
  local q = a // b
  if q < 0 and q * b ~= a then q = q + 1 end
  return q
end
function imod(a, b)
  local r = a % b
  if r ~= 0 and (r ~ a) < 0 then r = r - b end
  return r
end
-- C#'s >> of a signed 64-bit value (arithmetic); Lua's >> is logical
function sar(x, n)
  if x >= 0 then return x >> n end
  return ~((~x) >> n)
end
_ENV.ult = math.ult
-- C# ulong / and %: the bits of a Lua integer read as unsigned
function udiv64(a, b)
  if b == 0 then error(NewSysException("DivideByZeroException", "Attempted to divide by zero."), 0) end
  if a >= 0 and b > 0 then return a // b end
  if b < 0 then return ult(a, b) and 0 or 1 end
  -- a >= 2^63, 0 < b < 2^63: halve, divide, correct
  local q = ((a >> 1) // b) << 1
  local r = a - q * b
  if not ult(r, b) then q = q + 1 end
  return q
end
function umod64(a, b)
  local q = udiv64(a, b)
  return a - q * b
end
local udiv64 = udiv64
-- C# (double) of a ulong: the nearest double to the unsigned value
function u2d(x)
  if x >= 0 then return x + 0.0 end
  -- 2^63 <= x < 2^64: halve with the low bit kept as sticky (round to odd), convert, double
  return ((x >> 1) | (x & 1)) * 2.0
end
-- C# (double) of a long: Lua's int-to-float conversion rounds to the nearest, as cvtsi2sd does
function i2d(x) return x + 0.0 end

-- C#'s (float): IEEE single precision, by C's cast in string.pack (cvtsd2ss: overflow to infinity, NaN quieted)
local FLT_MAX = 3.4028234663852886e38
function f32(x)
  if mtype(x) == "integer" then
    if x > -9007199254740992 and x < 9007199254740992 then x = x + 0.0 else return f32_int(x) end
  end
  return (sunpack("<f", spack("<f", x)))
end
local f32 = f32
-- (float) of an integer beyond 2^53: rounded once from its exact value (C#'s (float)long)
function f32_int(x)
  local neg = x < 0
  local m = neg and -x or x
  if m < 0 then return neg and -9.2233720368547758e18 or 9.2233720368547758e18 end   -- the minimum long: -2^63 exactly
  local bl = 0; local t = m; while t ~= 0 do bl = bl + 1; t = t >> 1 end
  local e = bl - 24
  local q = m >> e
  local r = m & ((1 << e) - 1)
  local half = 1 << (e - 1)
  if r > half or (r == half and (q & 1) == 1) then q = q + 1 end
  local v = q * (2.0 ^ e)
  return (sunpack("<f", spack("<f", neg and -v or v)))
end
function f32_u64(x)
  if x >= 0 then return f32(x) end
  local bl = 64
  local e = bl - 24
  local q = x >> e
  local r = x & ((1 << e) - 1)
  local half = 1 << (e - 1)
  if ult(half, r) or (r == half and (q & 1) == 1) then q = q + 1 end
  return (sunpack("<f", spack("<f", q * (2.0 ^ e))))
end

-- x86's cvttsd2si: truncation; NaN and out-of-range values give the integer indefinite
function f2i32(x)
  if x > -2147483649.0 and x < 2147483648.0 then
    if x >= 0 then return (x // 1.0) | 0 end
    return -((-x) // 1.0) | 0
  end
  return -2147483648
end
local f2i32 = f2i32
function f2i64(x)
  if x >= -9223372036854775808.0 and x < 9223372036854775808.0 then
    if x >= 0 then return (x // 1.0) | 0 end
    return -((-x) // 1.0) | 0
  end
  return mininteger
end
local f2i64 = f2i64
-- (ulong) of a double as the C++ reference computes it (gcc's cvttsd2si of x, or of x - 2^63 with the top bit set):
-- NaN and too-large values give 2^63 (lesson 44)
function f2u64(x)
  if x < 9223372036854775808.0 then
    if x >= -9223372036854775808.0 then return f2i64(x) end
    return mininteger
  end
  if x ~= x then return mininteger end
  return f2i64(x - 9223372036854775808.0) ~ mininteger
end
function f2u32(x) return f2i64(x) & 0xFFFFFFFF end
function f2i16(x) local v = f2i32(x) & 0xFFFF; if v >= 0x8000 then v = v - 0x10000 end return v end
function f2u16(x) return f2i32(x) & 0xFFFF end
function f2i8(x) local v = f2i32(x) & 0xFF; if v >= 0x80 then v = v - 0x100 end return v end
function f2u8(x) return f2i32(x) & 0xFF end
Conv_D2I = f2i32; Conv_D2L = f2i64; Conv_D2UL = f2u64; Conv_D2U = f2u32
Conv_D2S = f2i16; Conv_D2US = f2u16; Conv_D2SB = f2i8; Conv_D2B = f2u8
function i32(v) return ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000 end

-- C#'s non-short-circuit & | ^ of bools: both operands are evaluated (they are arguments)
function bAnd(a, b) return a and b end
function bOr(a, b) return a or b end
function bXor(a, b) return a ~= b end

-- the value through a reference that a call returned (two values)
function deref2(t, k) return t[k] end

-- a C# array of n elements, each the given value (a number, a bool or an immutable struct)
function newA(n, d)
  local t = { n = n }
  for i = 0, n - 1 do t[i] = d end
  return t
end
local newA = newA
-- the elements of a C# array, as a list of values (a params array passed on)
function L_unpackA(a) return tunpack(a, 0, a.n - 1) end
function aLen(a) return a.n end

-- typed boxes for params object[] arguments (printf must know a value's C# width)
local TBox = lua_class("TBox")
Cpp_TBox = TBox
for _, b in ipairs({ "I64", "U32", "U64", "I16", "U16", "I8", "U8", "Ch", "F32", "Bool" }) do
  local c = lua_class("Box" .. b, TBox)
  c.kind_ = b
  _ENV[b] = function(v) return setmetatable({ v = v }, c) end
end

-- ------------------------------------------------------------------------------------------------ references
-- a cell: a one-element table (a ref to its element is (cell, 1))
function cell(v) return { v } end

-- a proxy whose every key reads and writes through functions (a reference that is not a storage location)
function fn_ref(get, set)
  return setmetatable({}, { __index = function() return get() end, __newindex = function(_, _, v) set(v) end }), 0
end

-- ------------------------------------------------------------------------------------------------ copies, equality
local ICopy = Cpp_ICopy
local function is_icopy(x)
  local mt = getmetatable(x)
  if mt == nil then return false end
  local s = rawget(mt, "__isa")
  return s ~= nil and s[ICopy] == true
end
_ENV.is_icopy = is_icopy

-- a deep copy of a C# array (elements that are arrays copied, ICopy objects cloned)
local function deep(a)
  local r = { n = a.n }
  for i = 0, a.n - 1 do
    local x = a[i]
    if type(x) == "table" then
      if getmetatable(x) == nil then x = deep(x) elseif is_icopy(x) then x = x:Clone() end
    end
    r[i] = x
  end
  return r
end
_ENV.deep = deep
function copy(x)
  if type(x) ~= "table" then return x end
  if getmetatable(x) == nil then return deep(x) end
  if is_icopy(x) then return x:Clone() end
  return x
end
local copy = copy
Elem_Copy = copy; Elem_Deep = deep
function Elem_NeedsCopy(x) return type(x) == "table" and (getmetatable(x) == nil or is_icopy(x)) end

function elem_eq(a, b)
  if type(a) == "table" then
    if rawequal(a, b) then return true end
    if b == nil then return false end
    local eq = a.Equals
    if eq then return eq(a, b) and true or false end
    return false
  end
  if a == nil then return b == nil end
  if b == nil or type(b) == "table" then return false end
  return a == b or (a ~= a and b ~= b)
end
local elem_eq = elem_eq
Elem_Eq = elem_eq; cs_equals = elem_eq

function elem_compare(a, b)
  if a == nil then return b ~= nil and -1 or 0 end
  if b == nil then return 1 end
  if type(a) == "table" then
    local c = a:CompareTo(b)
    return c < 0 and -1 or (c > 0 and 1 or 0)
  end
  if a < b then return -1 end
  if a > b then return 1 end
  if a == b then return 0 end
  if a ~= a then return (b ~= b) and 0 or -1 end
  return 1
end
local elem_compare = elem_compare
Elem_Compare = elem_compare
function elem_less(a, b)
  if type(a) == "table" then return elem_compare(a, b) < 0 end
  return a < b or (a ~= a and b == b)
end
Elem_Less = elem_less

MK_I = function() return 0 end
MK_D = function() return 0.0 end
MK_Z = function() return false end
MK_N = function() return nil end
IMMUT = { [MK_I] = true, [MK_D] = true, [MK_Z] = true, [MK_N] = true }
-- a C# array of n elements each made by mk (the same value when mk makes an immutable one)
function made(mk, n)
  if mk == nil then return { n = n } end
  if IMMUT[mk] then return newA(n, mk()) end
  local t = { n = n }
  for i = 0, n - 1 do t[i] = mk() end
  return t
end

-- .NET's double.ToString() ("R": the shortest round-trip digits)
function net_double(x)
  if x ~= x then return "NaN" end
  if x == huge then return "Infinity" end
  if x == -huge then return "-Infinity" end
  if x == 0 then return signbit(x) and "-0" or "0" end
  local r
  for p = 1, 17 do r = sformat("%." .. (p - 1) .. "e", x); if tonumber(r) == x then break end end
  local neg = r:sub(1, 1) == "-"
  if neg then r = r:sub(2) end
  local mant, ex = r:match("^([^e]+)e([-+]%d+)$")
  local digs = mant:gsub("%.", ""):gsub("0+$", "")
  if digs == "" then digs = "0" end
  local scale = tonumber(ex) + 1
  local t
  if scale > 15 or scale < -4 then
    local e = scale - 1
    t = digs:sub(1, 1) .. (#digs > 1 and ("." .. digs:sub(2)) or "") .. (e >= 0 and "E+" or "E-") .. sformat("%02d", e < 0 and -e or e)
  elseif scale <= 0 then t = "0." .. ("0"):rep(-scale) .. digs
  elseif scale >= #digs then t = digs .. ("0"):rep(scale - #digs)
  else t = digs:sub(1, scale) .. "." .. digs:sub(scale + 1) end
  return neg and ("-" .. t) or t
end
cs_tostring_d = net_double
function cs_tostring(v)
  if v == nil then return "" end
  if type(v) == "table" then return v:ToString() end
  if mtype(v) == "float" then return net_double(v) end
  if type(v) == "boolean" then return v and "True" or "False" end
  return tostring(v)
end
function cs_tostring_u64(v) return sformat("%u", v) end
function cs_chr(c) if c < 256 then return schar(c) end return "?" end

-- ------------------------------------------------------------------------------------------------ exceptions
Cpp_Exception = lua_class("Exception")                  -- the root of every exception the engine raises or catches
Cpp_SysException = lua_class("SysException", Cpp_Exception)   -- a .NET exception the C# throws itself (kind, message)
function NewSysException(k, m) return setmetatable({ kind = k, message = m }, Cpp_SysException) end
function Cpp_SysException.Message(s) return s.message end
function Cpp_SysException.ToString(s) return s.kind .. ": " .. s.message end
function throw_(e) error(e, 0) end

-- the exception a pcall caught: a Lua error (a string) stands for the .NET exception the C# would raise
local TRACE = os.getenv("SWMM6_LUA_TRACE")
function exc_of(e)
  if isa_(e, Cpp_Exception) then return e end
  local m = tostring(e)
  local k = "Exception"
  if m:find("'n//0'", 1, true) or m:find("'n%%0'", 1, true) or m:find("(zero)", 1, true) then k = "DivideByZeroException"
  elseif m:find("nil value", 1, true) or m:find("a nil", 1, true) then k = "NullReferenceException"
  elseif m:find("stack overflow", 1, true) then k = "StackOverflowException" end
  if TRACE then io.stderr:write("[lua error caught as " .. k .. "] " .. m .. "\n") end
  return NewSysException(k, m)
end
function exc_message(e)
  if type(e) == "table" and e.Message then return e:Message() end
  return tostring(e)
end
function Dbg_Caught(e) if TRACE then io.stderr:write("[caught] " .. exc_message(e) .. "\n") end end

-- ------------------------------------------------------------------------------------------------ C strings
-- a byte buffer is a table of bytes at 0 .. n - 1 with its length in n; a CPtr is a buffer and an offset. A byte may
-- be held as 0..255 or (from an sbyte array) as -128..127: every reader takes its low eight bits.
local function zfind(b, o)
  local i = o
  while true do
    local c = b[i]
    if c == nil then error(NewSysException("IndexOutOfRangeException", "cpp: no NUL in a C string buffer"), 0) end
    if c == 0 then return i end
    i = i + 1
  end
end
_ENV.zfind = zfind

-- the bytes b[o .. o + m - 1] as a Lua string
local function bytes_str(b, o, m)
  if m <= 0 then return "" end
  if m <= 4000 then
    local ok, s = pcall(schar, tunpack(b, o, o + m - 1))
    if ok then return s end
  end
  local parts = {}
  for i = o, o + m - 1 do parts[#parts + 1] = schar(b[i] & 255) end
  return tconcat(parts)
end
_ENV.bytes_str = bytes_str

-- a Lua string as a new byte buffer (with a NUL after it when nul)
local function str_bytes(s, nul)
  local n = #s
  local b
  if n <= 4000 then
    b = { sbyte(s, 1, n) }
    if n > 0 then tmove(b, 1, n, 0) end
    b[n] = nil
  else
    b = {}
    for i = 1, n do b[i - 1] = sbyte(s, i) end
  end
  if nul then b[n] = 0; b.n = n + 1 else b.n = n end
  return b
end
_ENV.str_bytes = str_bytes

-- the C string at a CPtr, as a Lua string
function cbs(p)
  local b, o = p.B, p.O
  local e = o
  local n = b.n
  while e < n do
    local c = b[e]
    if c == nil or c & 255 == 0 then break end
    e = e + 1
  end
  return bytes_str(b, o, e - o)
end
local cbs = cbs
function cstr_len(p) return zfind(p.B, p.O) - p.O end

-- ------------------------------------------------------------------------------------------------ CPtr
local CPtr = lua_class("CPtr")
Cpp_CPtr = CPtr
local function newcp(b, o) return setmetatable({ B = b, O = o }, CPtr) end
_ENV.newcp = newcp
function CPtr.Clone(s) return s end
function CPtr.get_IsNull(s) return s.B == nil end
function CPtr.get(s, i) local x = s.B[s.O + i] & 255; if x > 127 then x = x - 256 end return x end
function CPtr.set(s, i, v) s.B[s.O + i] = v & 255 end
function CPtr.assign(s, i, v) s.B[s.O + i] = v & 255; return v end
-- a reference to the sbyte at i: a proxy table that reads the byte signed and stores its low eight bits
function CPtr.ref(s, i)
  local b, k = s.B, s.O + i
  return setmetatable({}, { __index = function() local x = b[k] & 255; if x > 127 then x = x - 256 end return x end,
    __newindex = function(_, _, v) b[k] = v & 255 end }), 0
end
function CPtr.preInc(s, i) local k = s.O + i; local x = s.B[k] & 255; if x > 127 then x = x - 256 end x = x + 1; s.B[k] = x & 255; if x > 127 then x = x - 256 end return x end
function CPtr.preDec(s, i) local k = s.O + i; local x = s.B[k] & 255; if x > 127 then x = x - 256 end x = x - 1; s.B[k] = x & 255; if x < -128 then x = x + 256 end return x end
function CPtr.postInc(s, i) local k = s.O + i; local x = s.B[k] & 255; if x > 127 then x = x - 256 end s.B[k] = (x + 1) & 255; return x end
function CPtr.postDec(s, i) local k = s.O + i; local x = s.B[k] & 255; if x > 127 then x = x - 256 end s.B[k] = (x - 1) & 255; return x end
CPtr.get_Item = CPtr.get; CPtr.get_Item_i = CPtr.get; CPtr.set_Item = CPtr.set; CPtr.set_Item_i = CPtr.set
CPtr.ref_Item = CPtr.ref; CPtr.ref_Item_i = CPtr.ref
function CPtr.Equals(s, o) return isa_(o, CPtr) and CPtr_op_Eq(s, o) end
CPtr.Equals_CPtr = CPtr.Equals; CPtr.Equals_o = CPtr.Equals
local ADDR = setmetatable({}, { __mode = "k" })
local NEXT_ADDR = 0
function addr_of(t)
  local a = ADDR[t]
  if a == nil then NEXT_ADDR = NEXT_ADDR + 16; a = NEXT_ADDR; ADDR[t] = a end
  return a
end
local addr_of = addr_of
function CPtr.GetHashCode(s) return ((s.B ~= nil and addr_of(s.B) or 0) ~ s.O) & 0x7FFFFFFF end
function CPtr.ToString(s) if s.B ~= nil then return cbs(s) end return "(null)" end
CPtr_ZERO = newcp(nil, 0)
CPtr_Null = CPtr_ZERO
MK_CPtr = function() return CPtr_ZERO end
IMMUT[MK_CPtr] = true
function CPtr_from_Ptrc(p) return newcp(p.a, p.o) end
CPtr_from_Ptruc = CPtr_from_Ptrc
function CPtr_op_Add_CPtr_i(p, k) return newcp(p.B, p.O + k) end
CPtr_op_Add_CPtr_l = CPtr_op_Add_CPtr_i; CPtr_op_Add_CPtr_ul = CPtr_op_Add_CPtr_i; CPtr_op_Add = CPtr_op_Add_CPtr_i
function CPtr_op_Sub(p, k) return newcp(p.B, p.O - k) end
CPtr_op_Sub_CPtr_i = CPtr_op_Sub
function CPtr_op_Increment(p) return newcp(p.B, p.O + 1) end
function CPtr_op_Decrement(p) return newcp(p.B, p.O - 1) end
function CPtr_op_Eq(a, b) return rawequal(a.B, b.B) and (a.B == nil or a.O == b.O) end
function CPtr_op_Ne(a, b) return not CPtr_op_Eq(a, b) end
function CPtr_op_Lt(a, b) return a.O < b.O end
function CPtr_op_Gt(a, b) return a.O > b.O end
function CPtr_op_Le(a, b) return a.O <= b.O end
function CPtr_op_Ge(a, b) return a.O >= b.O end
function CPtr_Diff(a, b) return a.O - b.O end

-- ------------------------------------------------------------------------------------------------ Ptr<T>
-- an array and an offset; a FieldPtr (a pointer to one field, through a RefAt function) has a proxy array whose
-- every element is the field
local Ptr = lua_class("Ptr")
Cpp_Ptr = Ptr
local function newptr(a, o) return setmetatable({ a = a, o = o }, Ptr) end
_ENV.newptr = newptr
function Ptr.Clone(s) return s end
function Ptr.get_IsNull(s) return s.a == nil end
function Ptr.add(s, k) return newptr(s.a, s.o + k) end
function Ptr.get_Item_i(s, i) return s.a[s.o + i] end
function Ptr.set_Item_i(s, i, v) s.a[s.o + i] = v end
function Ptr.ref_Item_i(s, i) return s.a, s.o + i end
Ptr.get_Item_l = Ptr.get_Item_i; Ptr.get_Item_ul = Ptr.get_Item_i; Ptr.get_Item = Ptr.get_Item_i
Ptr.set_Item_l = Ptr.set_Item_i; Ptr.set_Item_ul = Ptr.set_Item_i; Ptr.set_Item = Ptr.set_Item_i
Ptr.ref_Item_l = Ptr.ref_Item_i; Ptr.ref_Item_ul = Ptr.ref_Item_i; Ptr.ref_Item = Ptr.ref_Item_i
function Ptr.get_Deref(s) return s.a[s.o] end
function Ptr.set_Deref(s, v) s.a[s.o] = v end
function Ptr.ref_Deref(s) return s.a, s.o end
function Ptr.Equals(s, o) return isa_(o, Ptr) and ptr_eq(s, o) end
Ptr.Equals_PtrT = Ptr.Equals; Ptr.Equals_o = Ptr.Equals
function Ptr.GetHashCode(s) return i32(s.o) end

local FieldPtr = lua_class("FieldPtr", Ptr)
local function field_proxy(ob, at)
  return setmetatable({ n = 1 }, { __index = function(_, k) local t, kk = at(ob); return t[kk] end,
    __newindex = function(_, k, v) local t, kk = at(ob); t[kk] = v end })
end
function new_fieldptr(o, ob, at) return setmetatable({ a = field_proxy(ob, at), o = o, ob = ob, at = at }, FieldPtr) end
function FieldPtr.get_IsNull(s) return false end
function FieldPtr.add(s, k) return new_fieldptr(s.o + k, s.ob, s.at) end
function ptr_eq(p, q)
  local pa, qa = p.at, q.at
  if pa or qa then return pa ~= nil and qa ~= nil and rawequal(p.ob, q.ob) and rawequal(pa, qa) and p.o == q.o end
  return rawequal(p.a, q.a) and (p.a == nil or p.o == q.o)
end
local ptr_eq = ptr_eq
Ptr_ZERO = newptr(nil, 0)
MK_Ptr = function() return Ptr_ZERO end
IMMUT[MK_Ptr] = true
function NewPtr_TA_l(a, o) return newptr(a, o) end
function NewPtr_o_RefAtT(ob, at) return new_fieldptr(0, ob, at) end
function Ptr_op_Add_PtrT_l(p, k) return p:add(k) end
Ptr_op_Add_PtrT_ul = Ptr_op_Add_PtrT_l
function Ptr_op_Sub_PtrT_l(p, k) return p:add(-k) end
function Ptr_op_Sub_PtrT_PtrT(p, q) return p.o - q.o end
function Ptr_op_Increment(p) return p:add(1) end
function Ptr_op_Decrement(p) return p:add(-1) end
function Ptr_op_Eq(p, q) return ptr_eq(p, q) end
function Ptr_op_Ne(p, q) return not ptr_eq(p, q) end
function Ptr_op_Lt(p, q) return p.o < q.o end
function Ptr_op_Gt(p, q) return p.o > q.o end
function Ptr_op_Le(p, q) return p.o <= q.o end
function Ptr_op_Ge(p, q) return p.o >= q.o end
function Ptr_from_IterT(it) return newptr(it.a, it.i) end

-- ------------------------------------------------------------------------------------------------ iterators
local Iter = lua_class("Iter")
Cpp_Iter = Iter
local function newit(v, a, i) return setmetatable({ v = v, a = a, i = i }, Iter) end
_ENV.newit = newit
function Iter.Clone(s) return s end
function Iter.get_Deref(s) return s.a[s.i] end
function Iter.set_Deref(s, v) s.a[s.i] = v end
function Iter.ref_Deref(s) return s.a, s.i end
function Iter.get_Item(s, k) return s.a[s.i + k] end
function Iter.set_Item(s, k, v) s.a[s.i + k] = v end
function Iter.ref_Item(s, k) return s.a, s.i + k end
Iter.get_Item_l = Iter.get_Item; Iter.set_Item_l = Iter.set_Item; Iter.ref_Item_l = Iter.ref_Item
function Iter.Equals(s, o) return isa_(o, Iter) and o.i == s.i end
Iter.Equals_IterT = Iter.Equals; Iter.Equals_o = Iter.Equals
function Iter.GetHashCode(s) return i32(s.i) end
Iter_ZERO = newit(nil, nil, 0)
MK_Iter = function() return Iter_ZERO end
IMMUT[MK_Iter] = true
function NewIter_TA_l(a, i) return newit(nil, a, i) end
function NewIter_VecT_l(v, i) return newit(v, v.a, i) end
function Iter_op_Add(x, k) local v = x.v; if v ~= nil then return newit(v, v.a, x.i + k) end return newit(nil, x.a, x.i + k) end
local Iter_op_Add = Iter_op_Add
function Iter_op_Sub_IterT_l(x, k) return Iter_op_Add(x, -k) end
function Iter_op_Sub_IterT_IterT(x, y) return x.i - y.i end
function Iter_op_Increment(x) return Iter_op_Add(x, 1) end
function Iter_op_Decrement(x) return Iter_op_Add(x, -1) end
function Iter_op_Eq(x, y) return x.i == y.i end
function Iter_op_Ne(x, y) return x.i ~= y.i end
function Iter_op_Lt(x, y) return x.i < y.i end
function Iter_op_Gt(x, y) return x.i > y.i end
function Iter_op_Le(x, y) return x.i <= y.i end
function Iter_op_Ge(x, y) return x.i >= y.i end

local RevIter = lua_class("RevIter")
Cpp_RevIter = RevIter
local function newrit(v, i) return setmetatable({ v = v, i = i }, RevIter) end
_ENV.newrit = newrit
function RevIter.Clone(s) return s end
function RevIter.get_Deref(s) return s.v.a[s.i - 1] end
function RevIter.set_Deref(s, x) s.v.a[s.i - 1] = x end
function RevIter.ref_Deref(s) return s.v.a, s.i - 1 end
function RevIter.Equals(s, o) return isa_(o, RevIter) and o.i == s.i end
RevIter.Equals_o = RevIter.Equals
RevIter_ZERO = newrit(nil, 0)
function NewRevIter_VecT_l(v, i) return newrit(v, i) end
function RevIter_op_Increment(x) return newrit(x.v, x.i - 1) end
function RevIter_op_Eq(x, y) return x.i == y.i end
function RevIter_op_Ne(x, y) return x.i ~= y.i end

local CSpan = lua_class("CSpan")
Cpp_CSpan = CSpan
local function newspan(a, o, n) return setmetatable({ a = a, o = o, n = n }, CSpan) end
function CSpan.Clone(s) return s end
function CSpan.get_Item(s, i) return s.a[s.o + i] end
function CSpan.set_Item(s, i, v) s.a[s.o + i] = v end
function CSpan.ref_Item(s, i) return s.a, s.o + i end
CSpan.get_Item_l = CSpan.get_Item; CSpan.set_Item_l = CSpan.set_Item; CSpan.ref_Item_l = CSpan.ref_Item
function CSpan.size(s) return s.n end
function CSpan.empty(s) return s.n == 0 end
function CSpan.data(s) return newptr(s.a or { n = 0 }, s.o) end
function CSpan.front(s) return s.a[s.o] end
function CSpan.back(s) return s.a[s.o + s.n - 1] end
function CSpan.subspan(s, off, cnt)
  if cnt == nil or cnt == -1 then return newspan(s.a, s.o + off, s.n - off) end
  return newspan(s.a, s.o + off, cnt)
end
CSpan.subspan_ul_ul = CSpan.subspan
function CSpan.first(s, k) return newspan(s.a, s.o, k) end
function CSpan.last(s, k) return newspan(s.a, s.o + s.n - k, k) end
CSpan_ZERO = newspan(nil, 0, 0)
function NewCSpan_TA_l_l(a, o, n) return newspan(a, o, n) end

-- a Box: a reference kept as an object (an array element, or a RefGet function returning a table and key)
local Box = lua_class("Box")
Cpp_Box = Box
function Box.get_V(s) local g = s.g; if g ~= nil then local t, k = g(); return t[k] end return s.a[s.o] end
function Box.set_V(s, v) local g = s.g; if g ~= nil then local t, k = g(); t[k] = v else s.a[s.o] = v end end
function Box.ref_V(s) local g = s.g; if g ~= nil then return g() end return s.a, s.o end
function NewBox_TA_l(a, o) return setmetatable({ a = a, o = o }, Box) end
function NewBox_RefGetT(g) return setmetatable({ g = g, o = 0 }, Box) end
Box_Of = NewBox_RefGetT

for _, c in ipairs({ "D", "F", "I", "L", "B", "Z", "S", "C" }) do
  _ENV["Ptr" .. c .. "_ZERO"] = Ptr_ZERO; _ENV["Iter" .. c .. "_ZERO"] = Iter_ZERO; _ENV["RevIter" .. c .. "_ZERO"] = RevIter_ZERO
  _ENV["CSpan" .. c .. "_ZERO"] = CSpan_ZERO; _ENV["MK_Ptr" .. c] = MK_Ptr; _ENV["MK_Iter" .. c] = MK_Iter
  for _, n in ipairs({ "NewPtr@_TA_l", "NewPtr@_o_RefAtT", "Ptr@_op_Add_PtrT_l", "Ptr@_op_Add_PtrT_ul", "Ptr@_op_Sub_PtrT_l",
      "Ptr@_op_Sub_PtrT_PtrT", "Ptr@_op_Increment", "Ptr@_op_Decrement", "Ptr@_op_Eq", "Ptr@_op_Ne", "Ptr@_op_Lt", "Ptr@_op_Gt",
      "Ptr@_op_Le", "Ptr@_op_Ge", "Ptr@_from_IterT", "NewIter@_TA_l", "NewIter@_VecT_l", "Iter@_op_Add", "Iter@_op_Sub_IterT_l",
      "Iter@_op_Sub_IterT_IterT", "Iter@_op_Increment", "Iter@_op_Decrement", "Iter@_op_Eq", "Iter@_op_Ne", "Iter@_op_Lt",
      "Iter@_op_Gt", "Iter@_op_Le", "Iter@_op_Ge", "NewRevIter@_VecT_l", "RevIter@_op_Increment", "RevIter@_op_Eq",
      "RevIter@_op_Ne", "NewCSpan@_TA_l_l", "Box@_Of", "NewBox@_TA_l", "NewBox@_RefGetT" }) do
    _ENV[n:gsub("@", c)] = _ENV[n:gsub("@", "")]
  end
  _ENV["Box_Of__" .. c] = Box_Of
end

-- a function value for a method of a runtime object (the object bound)
function bind_method(o, name) return function(...) return o[name](o, ...) end end

-- foreach over a runtime collection: its elements as a Lua sequence 1 .. n and n
function elems(c) return c:elems() end
