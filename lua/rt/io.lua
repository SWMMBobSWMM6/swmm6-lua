-- io.lua - iostreams (ostream, ofstream, ostringstream, istream, ifstream, istringstream, getline), std::filesystem
-- (FsPath, Fs_*), and the rest of the C# runtime's miscellany: atomics, variant, tuple, time points, mutexes,
-- std::swap / get / from_chars, error codes, raw memory views (Mem_*, Bytes_View). From cs/runtime/Streams.cs, Fs.cs and
-- Misc.cs by way of perl/cpp/io.pl. Paths are byte strings handed to the system as they are; .NET's full-path rules
-- (relative to the working directory, which the launcher passes in as CWD, "." and ".." removed) are kept.
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and lua/README.md.
local setmetatable, getmetatable, rawequal, type, error, pairs, ipairs, tostring, tonumber, select, pcall =
  setmetatable, getmetatable, rawequal, type, error, pairs, ipairs, tostring, tonumber, select, pcall
local schar, sbyte, ssub, srep, sformat, sfind, smatch, sgsub, spack, sunpack =
  string.char, string.byte, string.sub, string.rep, string.format, string.find, string.match, string.gsub, string.pack, string.unpack
local mtype, ult, huge, mininteger, maxinteger = math.type, math.ult, math.huge, math.mininteger, math.maxinteger
local tconcat, tmove, tunpack = table.concat, table.move, table.unpack
local io, os, math = io, os, math
local _ENV = ...
local newcp, newptr, cbs, bytes_str, str_bytes, signbit, i32, f32, isa_, str_of, str_text, newpair, format_c, scan_double, is_dir, float_bytes, lit_bytes =
  newcp, newptr, cbs, bytes_str, str_bytes, signbit, i32, f32, isa_, str_of, str_text, newpair, format_c, scan_double, is_dir, float_bytes, lit_bytes
local CPtr_ZERO, Ptr_ZERO = CPtr_ZERO, Ptr_ZERO

-- ------------------------------------------------------------------------------------------------ files as .NET opens them
function full_path(path)
  if path == "" then error(NewSysException("ArgumentException", "The value cannot be an empty string. (Parameter 'path')"), 0) end
  if sfind(path, "\0", 1, true) then error(NewSysException("ArgumentException", "Null character in path. (Parameter 'path')"), 0) end
  if ssub(path, 1, 1) ~= "/" then
    local c = CWD
    if ssub(c, -1) == "/" then path = c .. path else path = c .. "/" .. path end
  end
  if not (sfind(path, "//", 1, true) or sfind(path, "/.", 1, true)) then return path end
  local parts = {}
  for x in path:gmatch("[^/]+") do
    if x == "." then
    elseif x == ".." then parts[#parts] = nil
    else parts[#parts + 1] = x end
  end
  local r = "/" .. tconcat(parts, "/")
  if ssub(path, -1) == "/" and #parts > 0 then r = r .. "/" end
  return r
end
local full_path = full_path
local function try_full(p) local ok, f = pcall(full_path, p); if ok then return f end return nil end
function file_exists(p)
  if p == nil or p == "" then return false end
  local f = try_full(p)
  if f == nil then return false end
  if #f > 1 and ssub(f, -1) == "/" then return false end
  local h = io.open(f, "rb")
  if not h then return false end
  h:close()
  return not is_dir(f)
end
local file_exists = file_exists
function dir_exists(p)
  if p == nil or p == "" then return false end
  local f = try_full(p)
  if f == nil then return false end
  return is_dir(f)
end
local dir_exists = dir_exists
function File_Exists(s) if type(s) == "table" then s = s:ToString() end return file_exists(s) end

local FileOut = lua_class("FileOut")    -- a FileStream for writing (buffered), at the position .NET keeps
local function fileout(fh, append)
  local s = setmetatable({ fh = fh, fpos = 0, astart = -1 }, FileOut)
  if append then s.fpos = fh:seek("end"); s.astart = s.fpos end
  fh:seek("set", s.fpos)
  return s
end
function FileOut.write(s, d)
  if d == "" then return end
  local fh = s.fh
  if fh:seek("cur") ~= s.fpos then fh:seek("set", s.fpos) end
  fh:write(d)
  s.fpos = s.fpos + #d
end
function FileOut.position(s) return s.fpos end
function FileOut.length(s) local cur = s.fh:seek("cur"); local ln = s.fh:seek("end"); s.fh:seek("set", cur); if s.fpos > ln then return s.fpos end return ln end
function FileOut.seek(s, off, d)
  local np = d == 0 and off or (d == 2 and s:length() + off or s.fpos + off)
  if np < 0 then error(NewSysException("IO.IOException", "An attempt was made to move the position before the beginning of the stream."), 0) end
  if s.astart ~= -1 and np < s.astart then error(NewSysException("IO.IOException", "Unable seek backward to overwrite data that previously existed in a file opened in Append mode."), 0) end
  s.fpos = np
end
function FileOut.flush(s) if s.fh ~= nil then s.fh:flush() end end
function FileOut.close(s) if s.fh ~= nil then s.fh:close(); s.fh = nil end end
local FileIn = lua_class("FileIn")
local function filein(fh) return setmetatable({ fh = fh, pos = 0 }, FileIn) end
function FileIn.read(s, n) s.fh:seek("set", s.pos); local b = s.fh:read(n) or ""; s.pos = s.pos + #b; return b end
function FileIn.length(s) local ln = s.fh:seek("end"); return ln end
function FileIn.seek(s, p) s.pos = p end
function FileIn.position(s) return s.pos end
function FileIn.close(s) if s.fh ~= nil then s.fh:close(); s.fh = nil end end
local MemStream = lua_class("MemStream")
local function memstream() return setmetatable({ parts = {}, b = "", pos = 0, dirty = false }, MemStream) end
local function mem_text(s) if s.dirty then s.b = s.b .. tconcat(s.parts); s.parts = {}; s.dirty = false end return s.b end
_ENV.mem_text = mem_text
function MemStream.write(s, d)
  local n = #d
  if n <= 0 then return end
  local ln = #s.b
  if s.dirty then for _, p in ipairs(s.parts) do ln = ln + #p end end
  if s.pos == ln then s.parts[#s.parts + 1] = d; s.dirty = true
  else
    local b = mem_text(s)
    if s.pos > #b then b = b .. srep("\0", s.pos - #b) end
    s.b = ssub(b, 1, s.pos) .. d .. ssub(b, s.pos + n + 1)
  end
  s.pos = s.pos + n
end
function MemStream.seek(s, off, d)
  local np = d == 0 and off or (d == 1 and s.pos + off or #mem_text(s) + off)
  if np < 0 then error(NewSysException("IO.IOException", "An attempt was made to move the position before the beginning of the stream."), 0) end
  s.pos = np
end
function MemStream.flush(s) end
local function open_fd(path, mode)
  local full = full_path(path)
  if (#full > 1 and ssub(full, -1) == "/") or is_dir(full) then error("is a directory") end
  local fh
  if mode == "r" then fh = io.open(full, "rb")
  elseif mode == "w" then fh = io.open(full, "wb")
  elseif mode == "a" then fh = io.open(full, "ab")
  else fh = io.open(full, "r+b") or io.open(full, "w+b") end
  if not fh then error("cannot open " .. full) end
  return fh
end

-- ------------------------------------------------------------------------------------------------ ostreams
local IosBase = lua_class("IosBase")
local function ios_init(s) s.failbit = false; s.eofbit = false; s.badbit = false; s.prec = 6; s.flagsv = 0; s.widthv = 0; s.fillc = 32; return s end
function IosBase.good(s) return not (s.failbit or s.eofbit or s.badbit) end
function IosBase.fail_(s) return s.failbit or s.badbit end
function IosBase.bad(s) return s.badbit end
function IosBase.eof(s) return s.eofbit end
function IosBase.ok(s) return not (s.failbit or s.badbit) end
function IosBase.notok(s) return s.failbit or s.badbit end
function IosBase.Bool(s) return s:ok() end
function IosBase.clear(s) s.failbit = false; s.eofbit = false; s.badbit = false end
function IosBase.precision_(s) return s.prec end
function IosBase.precision_l(s, p) local o = s.prec; s.prec = p; return o end
function IosBase.width_(s) return s.widthv end
function IosBase.width_l(s, w) local o = s.widthv; s.widthv = w; return o end
function IosBase.setf_i(s, f) local o = s.flagsv; s.flagsv = i32(o | f); return o end
function IosBase.setf_i_i(s, f, m) local o = s.flagsv; s.flagsv = i32((o & ~m) | (f & m)); return o end
function IosBase.unsetf(s, f) s.flagsv = i32(s.flagsv & ~f) end
function IosBase.imbue() return nil end
function IosBase.exceptions() return nil end
function IosBase.rdbuf() return nil end

local OStream = lua_class("OStream", IosBase)
Cpp_OStream = OStream
local SFMTS = { [false] = { "%.*g", "%.*f", "%.*e", "%a" }, [true] = { "%#.*g", "%#.*f", "%#.*e", "%#a" } }
local function ostream_new(c) return ios_init(setmetatable({ s = nil, mem = nil, std = 0 }, c)) end
function OStream._alloc(c) return ostream_new(c) end
function OStream.Raw(s, d)
  if s.s ~= nil then s.s:write(d)
  elseif s.std ~= 0 then
    if d == "" then return end
    local f = s.std == 1 and R_stdout_ or R_stderr_
    R_fflush(f)
    f:write(d)
  elseif s.mem ~= nil then s.mem:write(d) end
end
function OStream.Pad(s, body)
  local w = s.widthv
  s.widthv = 0
  local n = #body
  if n >= w then s:Raw(body); return end
  local p = srep(schar(s.fillc & 255), w - n)
  if s.flagsv & 32 ~= 0 then s:Raw(body); s:Raw(p) else s:Raw(p); s:Raw(body) end
end
function OStream.Put_Str(s, x) s:Pad(str_text(x)); return s end
function OStream.Put_CPtr(s, p) s:Pad(cbs(p)); return s end
function OStream.Put_c(s, c) s:Pad(schar(c & 255)); return s end
OStream.Put_uc = OStream.Put_c
function OStream.Put_i(s, v) s:Pad(sformat("%d", v)); return s end
OStream.Put_l = OStream.Put_i; OStream.Put_u = OStream.Put_i; OStream.Put_s = OStream.Put_i
function OStream.Put_ul(s, v) s:Pad(sformat("%u", v)); return s end
function OStream.Put_b(s, v)
  if s.flagsv & 1 ~= 0 then s:Pad(v and "true" or "false") else s:Pad(v and "1" or "0") end
  return s
end
function OStream.Put_d(s, v)
  local fm = SFMTS[s.flagsv & 1024 ~= 0]
  local fx = s.flagsv & 4 ~= 0
  local sci = s.flagsv & 256 ~= 0
  local body
  if fx and sci then body = format_c(fm[4], { v }, 1)
  else body = format_c(fx and fm[2] or (sci and fm[3] or fm[1]), { i32(s.prec), v }, 2) end
  s:Pad(body)
  return s
end
OStream.Put_f = OStream.Put_d
function OStream.Put_OStream(s) return s end
function OStream.Manip_endl(s) s:Raw("\n"); s:flush(); return s end
function OStream.Manip_flush(s) s:flush(); return s end
function OStream.Manip_setprecision(s, p) s.prec = p; return s end
function OStream.Manip_setw(s, w) s.widthv = w; return s end
function OStream.Manip_setfill(s, c) s.fillc = c; return s end
local function quote(b) return '"' .. sgsub(b, '(["\\])', "\\%1") .. '"' end
function OStream.Manip_quoted_Str(s, x) s:Pad(quote(str_text(x))); return s end
function OStream.Manip_quoted_CPtr(s, p) s:Pad(quote(cbs(p))); return s end
function OStream.Manip_fixed(s) s.flagsv = (s.flagsv & ~(4 | 256)) | 4; return s end
function OStream.Manip_scientific(s) s.flagsv = (s.flagsv & ~(4 | 256)) | 256; return s end
function OStream.Manip_defaultfloat(s) s.flagsv = s.flagsv & ~(4 | 256); return s end
function OStream.Manip_left(s) s.flagsv = (s.flagsv & ~(32 | 128)) | 32; return s end
function OStream.Manip_right(s) s.flagsv = (s.flagsv & ~(32 | 128)) | 128; return s end
function OStream.Manip_boolalpha(s) s.flagsv = s.flagsv | 1; return s end
function OStream.Manip_noboolalpha(s) s.flagsv = s.flagsv & ~1; return s end
function OStream.Manip_showpoint(s) s.flagsv = s.flagsv | 1024; return s end
function OStream.Manip_noshowpoint(s) s.flagsv = s.flagsv & ~1024; return s end
function OStream.write_CPtr_l(s, p, n)
  if n == 0 then return s end
  local k = i32(n)
  if p.O + k > p.B.n or k < 0 then
    error(NewSysException("ArgumentException", "Offset and length were out of bounds for the array or count is greater than the number of elements from index to the end of the source collection."), 0)
  end
  s:Raw(bytes_str(p.B, p.O, k))
  return s
end
for _, c in ipairs({ "B", "Z", "S", "I", "L", "F", "D" }) do
  OStream["write_PtrT_l__" .. c] = function(s, p, n) s:Raw(pod_of(c, p, i32(n))); return s end
end
function OStream.flush(s) if s.s ~= nil then s.s:flush() end return s end
function OStream.tellp(s)
  if s.s ~= nil then return s.s:position() end
  if s.std ~= 0 then error(NewSysException("NotSupportedException", "Stream does not support seeking."), 0) end
  if s.mem ~= nil then return s.mem.pos end
  return 0
end
function OStream.seekp(s, pos, d)
  d = d or 0
  if s.s ~= nil then s.s:seek(pos, d) elseif s.mem ~= nil then s.mem:seek(pos, d) end
  return s
end
local OStringStream = lua_class("OStringStream", OStream)
local function oss_new() local s = ostream_new(OStringStream); s.mem = memstream(); return s end
function OStringStream.str_(s) return str_of(mem_text(s.mem)) end
function OStringStream.str_Str(s, x) local m = memstream(); m:write(str_text(x)); s.mem = m end
function OStringStream.MoveFrom(s, o) s.mem = o.mem; s.prec = o.prec; s.flagsv = o.flagsv; o.mem = memstream() end
function NewOStringStream() return oss_new() end
NewOStringStream_i = NewOStringStream
function NewOStringStream_Str(x) local o = oss_new(); o.mem:write(str_text(x)); o.mem:seek(0, 0); return o end
local OFStream = lua_class("OFStream", OStream, { Cpp_IDisposable })
function OFStream.open_bytes(s, path, mode)
  if s.s ~= nil then local old = s.s; s.s = nil; old:close() end
  local app = (mode & 1) ~= 0
  local ok, fh = pcall(open_fd, path, app and "a" or "w")
  if not ok then s.s = nil; s.failbit = true; return end
  s.s = fileout(fh, app)
  s.failbit = false
end
function OFStream.open_Str_i(s, p, m) s:open_bytes(str_text(p), m or 16) end
function OFStream.open_FsPath_i(s, p, m) s:open_bytes(str_text(p.p), m or 16) end
function OFStream.open_CPtr_i(s, p, m) s:open_bytes(cbs(p), m or 16) end
function OFStream.is_open(s) return s.s ~= nil end
function OFStream.close(s) local x = s.s; if x == nil then return end s.s = nil; x:close() end
function OFStream.Dispose(s) s:close() end
function OFStream.MoveFrom(s, o) s.s = o.s; o.s = nil end
function NewOFStream() return ostream_new(OFStream) end
function NewOFStream_Str_i(p, m) local o = ostream_new(OFStream); o:open_Str_i(p, m); return o end
function NewOFStream_CPtr_i(p, m) local o = ostream_new(OFStream); o:open_CPtr_i(p, m); return o end
function NewOFStream_FsPath_i(p, m) local o = ostream_new(OFStream); o:open_FsPath_i(p, m); return o end
local FStream = lua_class("FStream", OStream, { Cpp_IDisposable })
function FStream.is_open(s) return s.s ~= nil end
function FStream.close(s) local x = s.s; s.s = nil; if x ~= nil then x:close() end end
function FStream.Dispose(s) s:close() end
function NewFStream(path, mode)
  local o = ostream_new(FStream)
  local ok, fh = pcall(open_fd, str_text(path), "rw")
  if ok then o.s = fileout(fh, false) else o.failbit = true end
  return o
end
Streams_cout = ostream_new(OStream); Streams_cout.std = 1
Streams_cerr = ostream_new(OStream); Streams_cerr.std = 2
Streams_clog = Streams_cerr

-- ------------------------------------------------------------------------------------------------ istreams
local IStream = lua_class("IStream", IosBase)
Cpp_IStream = IStream
local function istream_new(c) return ios_init(setmetatable({ buf = "", pos = 0, len = 0, src = nil, gcountv = 0, dir = false }, c)) end
-- buf holds the bytes read ahead; pos and len are 0-based offsets into it
local function fill(s)
  if s.pos < s.len then return true end
  if s.dir then s.badbit = true; s.failbit = true; return false end
  if s.src == nil then return false end
  s.buf = s.src:read(1 << 16)
  s.len = #s.buf
  s.pos = 0
  return s.len > 0
end
IStream.Fill = fill
local function at_end(s) if not s.dir then s.eofbit = true end end
function IStream.peek(s) if not fill(s) then at_end(s); return -1 end return sbyte(s.buf, s.pos + 1) end
function IStream.get_(s)
  if not fill(s) then at_end(s); s.failbit = true; return -1 end
  s.gcountv = 1
  s.pos = s.pos + 1
  return sbyte(s.buf, s.pos)
end
function IStream.get_cr(s, t, k) local x = s:get_(); if x >= 0 then if x > 127 then x = x - 256 end t[k] = x end return s end
function IStream.ignore(s, n, delim)
  n = n or 1; delim = delim or -1
  local i = 0
  while i < n do
    local c = s:get_()
    if c < 0 or c == delim then break end
    i = i + 1
  end
  s.failbit = s.failbit and not s.eofbit
  return s
end
function IStream.gcount(s) return s.gcountv end
function IStream.read_CPtr_l(s, p, n)
  local got = 0
  local b, o = p.B, p.O
  while got < n do
    if not fill(s) then break end
    local k = n - got
    if s.len - s.pos < k then k = s.len - s.pos end
    if o + got + k > b.n then
      error(NewSysException("ArgumentException", "Destination array was not long enough. Check the destination index, length, and the array's lower bounds. (Parameter 'destinationArray')"), 0)
    end
    for j = 1, k do b[o + got + j - 1] = sbyte(s.buf, s.pos + j) end
    s.pos = s.pos + k; got = got + k
  end
  s.gcountv = got
  if got < n then at_end(s); s.failbit = true end
  return s
end
for _, c in ipairs({ "B", "Z", "S", "I", "L", "F", "D" }) do
  IStream["read_PtrT_l__" .. c] = function(s, p, n)
    local m = i32(n)
    local tb = { n = m }
    for i = 0, m - 1 do tb[i] = 0 end
    local tmp = newcp(tb, 0)
    s:read_CPtr_l(tmp, n)
    pod_into(c, p, bytes_str(tb, 0, m), s.gcountv)
    return s
  end
end
function IStream.ReadLine(s, str, delim)
  str:clear()
  local any = false
  local d = (delim >= 0 and delim <= 255) and schar(delim) or nil
  while true do
    if not fill(s) then at_end(s); if not any then s.failbit = true end return any end
    any = true
    local k = d and sfind(s.buf, d, s.pos + 1, true) or nil
    local e = k and (k - 1) or s.len
    if e > s.len then e = s.len end
    if e > s.pos then str:append_bytes(ssub(s.buf, s.pos + 1, e)) end
    if k ~= nil and k - 1 < s.len then s.pos = k; return true end
    s.pos = s.len
  end
end
local function skip_ws(s)
  while fill(s) do
    local a, b = sfind(s.buf, "^[ \t\n\r\v\f]*", s.pos + 1)
    if b < s.len then s.pos = b; return end
    s.pos = s.len
  end
end
IStream.SkipWs = skip_ws
local function token(s)
  skip_ws(s)
  local parts = {}
  while fill(s) do
    local a, b = sfind(s.buf, "^[^ \t\n\r\v\f]*", s.pos + 1)
    local e = b
    if e > s.len then e = s.len end
    parts[#parts + 1] = ssub(s.buf, s.pos + 1, e)
    s.pos = e
    if e < s.len then break end
  end
  local tok = tconcat(parts)
  if tok == "" then s.failbit = true; if not fill(s) then at_end(s) end
  elseif not fill(s) then at_end(s) end
  return tok
end
IStream.token = token
function IStream.Get_Str(s, str) local t = token(s); if t ~= "" then str:Assign_Str(str_of(t)) end return s end
function IStream.Manip_ws(s)
  while true do
    if not fill(s) then at_end(s); break end
    local a, b = sfind(s.buf, "^[ \t\n\r\v\f]*", s.pos + 1)
    if b >= s.len then s.pos = s.len
    else s.pos = b; break end
  end
  return s
end
local function next_c(s) s.pos = s.pos + 1; if fill(s) then return sbyte(s.buf, s.pos + 1) end return -1 end
function IStream.Get_dr(s, t, k)
  if s.failbit or s.eofbit or s.badbit then s.failbit = true; return s end
  skip_ws(s)
  if not fill(s) then at_end(s); s.failbit = true; return s end
  local acc = {}
  local c = sbyte(s.buf, s.pos + 1)
  if c == 43 or c == 45 then acc[#acc + 1] = schar(c); c = next_c(s) end
  local mant, dec, sci = false, false, false
  while c == 48 do if not mant then acc[#acc + 1] = "0"; mant = true end c = next_c(s) end
  while c >= 0 do
    if c >= 48 and c <= 57 then acc[#acc + 1] = schar(c); mant = true
    elseif c == 46 and not dec and not sci then acc[#acc + 1] = "."; dec = true
    elseif (c == 101 or c == 69) and not sci and mant then
      acc[#acc + 1] = "e"; sci = true
      c = next_c(s)
      if c < 0 then break end
      if c == 43 or c == 45 then acc[#acc + 1] = schar(c) else goto again end
    else break end
    c = next_c(s)
    ::again::
  end
  if c < 0 then at_end(s) end
  local a = tconcat(acc)
  local r, n = scan_double(a, 0, false)
  if n <= 0 or n ~= #a then t[k] = 0.0; s.failbit = true
  elseif r == huge then t[k] = 1.7976931348623157e308; s.failbit = true
  elseif r == -huge then t[k] = -1.7976931348623157e308; s.failbit = true
  else t[k] = r end
  return s
end
function IStream.Get_fr(s, t, k) local d = { 0.0 }; s:Get_dr(d, 1); t[k] = f32(d[1]); return s end
local function strtol_bytes(t)
  local a, b, sg, d = sfind(t, "^[ \t\n\r\v\f]*([+-]?)(%d+)")
  if a == nil then return 0, 0 end
  return clamp_long(d, sg == "-"), b
end
function IStream.Get_ir(s, t, k)
  local tok = token(s)
  if tok == "" then t[k] = 0; return s end
  local r, e = strtol_bytes(tok)
  if e ~= #tok or r < -2147483648 or r > 2147483647 then
    s.failbit = true
    t[k] = r < -2147483648 and -2147483648 or (r > 2147483647 and 2147483647 or 0)
    return s
  end
  t[k] = r
  return s
end
function IStream.Get_lr(s, t, k)
  local tok = token(s)
  if tok == "" then t[k] = 0; return s end
  local r, e = strtol_bytes(tok)
  if e ~= #tok then s.failbit = true; t[k] = 0; return s end
  t[k] = r
  return s
end
function IStream.Get_ulr(s, t, k) local x = { 0 }; s:Get_lr(x, 1); t[k] = x[1]; return s end
function IStream.Get_ur(s, t, k) local x = { 0 }; s:Get_lr(x, 1); t[k] = x[1] & 0xFFFFFFFF; return s end
function IStream.Get_cr(s, t, k) skip_ws(s); local x = s:get_(); if x >= 0 then if x > 127 then x = x - 256 end t[k] = x end return s end
function IStream.tellg(s) if s.src ~= nil then return s.src:position() - (s.len - s.pos) end return s.pos end
function IStream.seekg(s, off, d)
  d = d or 0
  s.eofbit = false
  if s.src ~= nil then
    local np = d == 0 and off or (d == 1 and s:tellg() + off or s.src:length() + off)
    if np < 0 then s.failbit = true; return s end
    s.src:seek(np); s.pos = 0; s.len = 0
  else
    s.pos = i32(d == 0 and off or (d == 1 and s.pos + off or s.len + off))
  end
  return s
end
local IStringStream = lua_class("IStringStream", IStream)
function IStringStream.str_Str(s, x) s.buf = str_text(x); s.pos = 0; s.len = #s.buf; s.failbit = false; s.eofbit = false end
function IStringStream.str_(s) return str_of(ssub(s.buf, 1, s.len)) end
function IStringStream.MoveFrom(s, o) s.buf = o.buf; s.pos = o.pos; s.len = o.len end
function NewIStringStream() return istream_new(IStringStream) end
function NewIStringStream_Str(x) local i = istream_new(IStringStream); i:str_Str(x); return i end
NewIStringStream_Str_i = NewIStringStream_Str
local IFStream = lua_class("IFStream", IStream, { Cpp_IDisposable })
function IFStream.open_bytes(s, path)
  if s.src ~= nil then s.src:close(); s.src = nil end
  s.dir = false
  if dir_exists(path) then s.dir = true; s.failbit = false; s.pos = 0; s.len = 0; return end
  local ok, fh = pcall(open_fd, path, "r")
  if not ok then s.src = nil; s.failbit = true; return end
  s.src = filein(fh)
  s.failbit = false; s.pos = 0; s.len = 0
end
function IFStream.open_Str_i(s, p) s:open_bytes(str_text(p)) end
function IFStream.open_FsPath_i(s, p) s:open_bytes(str_text(p.p)) end
function IFStream.open_CPtr_i(s, p) s:open_bytes(cbs(p)) end
function IFStream.is_open(s) return s.src ~= nil or s.dir end
function IFStream.close(s) if s.src ~= nil then local x = s.src; s.src = nil; x:close() end s.dir = false end
function IFStream.Dispose(s) s:close() end
function IFStream.MoveFrom(s, o) s.src = o.src; s.buf = o.buf; s.pos = o.pos; s.len = o.len; s.dir = o.dir; o.src = nil; o.dir = false end
function NewIFStream() return istream_new(IFStream) end
function NewIFStream_Str_i(p) local f = istream_new(IFStream); f:open_Str_i(p); return f end
function NewIFStream_CPtr_i(p) local f = istream_new(IFStream); f:open_CPtr_i(p); return f end
function NewIFStream_FsPath_i(p) local f = istream_new(IFStream); f:open_FsPath_i(p); return f end
function Streams_getline_IStream_Str(i, s) i:ReadLine(s, 10); return i end
function Streams_getline_IStream_Str_c(i, s, c) i:ReadLine(s, c & 255); return i end
Streams_getline_IStream_Str_i = Streams_getline_IStream_Str_c

-- ------------------------------------------------------------------------------------------------ raw memory
-- element codes: size, the string.pack format to read, to write, and the mask of the bits written
local EL = { D = { 8, "<d", "<d" }, F = { 4, "<f", "<f" }, I = { 4, "<i4", "<I4", 0xFFFFFFFF }, U = { 4, "<I4", "<I4", 0xFFFFFFFF },
  L = { 8, "<i8", "<i8" }, UL = { 8, "<i8", "<i8" }, S = { 2, "<i2", "<I2", 0xFFFF }, C = { 2, "<I2", "<I2", 0xFFFF },
  B = { 1, "B", "B", 0xFF }, Z = { 1, "B", "B" } }
local function elem_bytes(code, a, o, n)
  if n == 0 then return "" end
  local e = EL[code]
  local size, wc, mask = e[1], e[3], e[4]
  local k = (n + size - 1) // size
  if o + k > a.n then error(NewSysException("IndexOutOfRangeException", "memory read past the array"), 0) end
  local parts = {}
  for i = 0, k - 1 do
    local x = a[o + i]
    if code == "Z" then parts[#parts + 1] = schar(x and 1 or 0)
    elseif code == "F" then parts[#parts + 1] = float_bytes(x)
    elseif code == "D" or code == "L" or code == "UL" then parts[#parts + 1] = spack(wc, x)
    else parts[#parts + 1] = spack(wc, x & mask) end
  end
  local b = tconcat(parts)
  if #b == n then return b end
  return ssub(b, 1, n)
end
_ENV.elem_bytes = elem_bytes
local function elem_write(code, a, o, data)
  local n = #data
  if n == 0 then return end
  local e = EL[code]
  local size, rc = e[1], e[2]
  local k = (n + size - 1) // size
  if o + k > a.n then error(NewSysException("IndexOutOfRangeException", "memory write past the array"), 0) end
  if n ~= k * size then data = data .. ssub(elem_bytes(code, a, o + k - 1, size), n - (k - 1) * size + 1, size) end
  for i = 0, k - 1 do
    local v = sunpack(rc, data, i * size + 1)
    if code == "Z" then v = v ~= 0 end
    a[o + i] = v
  end
end
local function all_bytes(code, a, o) return elem_bytes(code, a, o, (a.n - o) * EL[code][1]) end
local function cp_bytes(p, n)
  if n == 0 then return "" end
  if p.O + n > p.B.n then error(NewSysException("IndexOutOfRangeException", "memory read past the buffer"), 0) end
  return bytes_str(p.B, p.O, n)
end
local function cp_write(p, d)
  local n = #d
  if n == 0 then return end
  if p.O + n > p.B.n then error(NewSysException("IndexOutOfRangeException", "memory write past the buffer"), 0) end
  local b, o = p.B, p.O
  for i = 1, n do b[o + i - 1] = sbyte(d, i) end
end
local POD_SIZE = { B = 1, Z = 1, S = 2, I = 4, L = 8, F = 4, D = 8 }
local function pod_check(p, size, n)
  local a = p.a
  if a == nil then error(NewSysException("NullReferenceException", "Object reference not set to an instance of an object."), 0) end
  local o = p.o
  if o < 0 or o > a.n or n < 0 or n > (a.n - o) * size then error(NewSysException("ArgumentOutOfRangeException", "Specified argument was out of the range of valid values."), 0) end
end
function pod_of(code, p, n)
  if n == 0 and p.a == nil then return "" end
  pod_check(p, POD_SIZE[code], n)
  return elem_bytes(code, p.a, p.o, n)
end
function pod_into(code, p, src, n)
  if n <= 0 then if n == 0 and p.a == nil then return end pod_check(p, POD_SIZE[code], 0); return end
  pod_check(p, POD_SIZE[code], n)
  if code == "B" then for i = 1, n do p.a[p.o + i - 1] = sbyte(src, i) end
  else elem_write(code, p.a, p.o, ssub(src, 1, n)) end
end
for _, c in ipairs({ "D", "F", "I", "L", "B" }) do
  local z = (c == "D" or c == "F") and 0.0 or 0
  local size = EL[c][1]
  _ENV["Mem_Calloc__" .. c] = function(n, m) return newptr(newA((n * m) // size, z), 0) end
end
function Mem_Free() end
local function index_of(a, obj)
  for i = 0, a.n - 1 do if rawequal(a[i], obj) then return i end end
  for i = 0, a.n - 1 do if elem_eq(a[i], obj) then return i end end
  return -1
end
function Mem_Diff_T_PtrT(o, p) return index_of(p.a, o) - p.o end
function Mem_Diff_PtrT_T(p, o) return p.o - index_of(p.a, o) end
for _, c in ipairs({ "B", "D", "F", "I", "L", "S", "Z", "C" }) do
  _ENV["Mem_memcpy_PtrT_CPtr_ul__" .. c] = function(d, s, n) elem_write(c, d.a, d.o, cp_bytes(s, n)); return d end
  _ENV["Mem_memcpy_CPtr_PtrU_ul__" .. c] = function(d, s, n) cp_write(d, elem_bytes(c, s.a, s.o, n)); return d end
  _ENV["Mem_memset_PtrT_i_ul__" .. c] = function(d, v, n) elem_write(c, d.a, d.o, srep(schar(v & 255), n)); return d end
  _ENV["Bytes_View_PtrT__" .. c] = function(p)
    if p.a == nil and p.at == nil then return CPtr_ZERO end
    return newcp(str_bytes(all_bytes(c, p.a, p.o), false), 0)
  end
end
for _, q in ipairs({ { "IB", "U", "B" }, { "LD", "UL", "D" }, { "DL", "D", "L" }, { "BI", "B", "I" }, { "IF", "I", "F" }, { "FI", "F", "I" } }) do
  local sfx, dc, sc = q[1], q[2], q[3]
  _ENV["Mem_memcpy_PtrT_PtrU_ul__" .. sfx] = function(d, s, n) if n ~= 0 then elem_write(dc, d.a, d.o, elem_bytes(sc, s.a, s.o, n)) end return d end
end
function Mem_memcpy_CPtr_CPtr_ul(d, s, n) if n ~= 0 then cp_write(d, cp_bytes(s, n)) end return d end
function Mem_memset_CPtr_i_ul(d, c, n) cp_write(d, srep(schar(c & 255), n)); return d end
function Mem_fwrite_CPtr_ul_ul_CFile(p, size, count, f) if size * count ~= 0 then f:write(cp_bytes(p, size * count)) end return count end
function Mem_fread_CPtr_ul_ul_CFile(p, size, count, f)
  local want = size * count
  local b = want ~= 0 and (f:read(want) or "") or ""
  if #b < want then f:ReadFailed() end
  cp_write(p, b)
  if size ~= 0 then return #b // size end
  return 0
end
for _, c in ipairs({ "D", "F", "I", "L", "B" }) do
  _ENV["Mem_fwrite_PtrT_ul_ul_CFile__" .. c] = function(p, size, count, f) f:write(elem_bytes(c, p.a, p.o, size * count)); return count end
  _ENV["Mem_fread_PtrT_ul_ul_CFile__" .. c] = function(p, size, count, f)
    local want = size * count
    local b = want ~= 0 and (f:read(want) or "") or ""
    if #b < want then f:ReadFailed() end
    elem_write(c, p.a, p.o, b)
    if size ~= 0 then return #b // size end
    return 0
  end
end
function Bytes_View_CPtr(p) return p end

-- ------------------------------------------------------------------------------------------------ std::filesystem
local FsPath = lua_class("FsPath", nil, { Cpp_ICopy })
Cpp_FsPath = FsPath
local function mk(s) return setmetatable({ p = str_of(s) }, FsPath) end
local function pb(x) return str_text(x.p) end
function FsPath.Clone(s) return setmetatable({ p = s.p:Clone() }, FsPath) end
function FsPath.clear(s) s.p = str_of("") end
function FsPath.Assign_FsPath(s, o) s.p = o.p:Clone() end
FsPath.Assign = FsPath.Assign_FsPath
function FsPath.Assign_Str(s, x) s.p = x:Clone() end
function FsPath.MoveFrom(s, o) s.p = o.p; o.p = str_of("") end
function FsPath.CompareTo(s, o) return cmp_(pb(s), pb(o)) end
function FsPath.compare(s, o) return s:CompareTo(o) end
function FsPath.ToString(s) return pb(s) end
function FsPath.string(s) return s.p:Clone() end
FsPath.generic_string = FsPath.string; FsPath.native = FsPath.string; FsPath.u8string = FsPath.string
function FsPath.c_str(s) return s.p:c_str() end
function FsPath.empty(s) return s.p.n == 0 end
function FsPath.is_absolute(s) return s.p.n > 0 and s.p.b[0] == 47 end
function FsPath.is_relative(s) return not s:is_absolute() end
local function rindex(s, ch) local r = nil; local i = 0; while true do local k = sfind(s, ch, i + 1, true); if not k then break end r = k; i = k end return r end
function FsPath.filename(s) local t = pb(s); local i = rindex(t, "/"); if i == nil then return mk(t) end return mk(ssub(t, i + 1)) end
function FsPath.has_filename(s) return s:filename().p.n > 0 end
function FsPath.has_parent_path(s) return s:parent_path().p.n > 0 end
function FsPath.has_extension(s) return s:extension().p.n > 0 end
function FsPath.parent_path(s)
  local t = pb(s)
  local i = rindex(t, "/")
  if i == nil then return mk("") end
  if i == 1 then return mk("/") end
  local j = i - 1
  while j > 0 and ssub(t, j, j) == "/" do j = j - 1 end
  return mk(ssub(t, 1, j == 0 and 1 or j))
end
function FsPath.stem(s)
  local f = pb(s:filename())
  if f == "." or f == ".." then return mk(f) end
  local i = rindex(f, ".")
  if i == nil or i == 1 then return mk(f) end
  return mk(ssub(f, 1, i - 1))
end
function FsPath.extension(s)
  local f = pb(s:filename())
  if f == "." or f == ".." then return mk("") end
  local i = rindex(f, ".")
  if i == nil or i == 1 then return mk("") end
  return mk(ssub(f, i))
end
function FsPath.replace_extension_FsPath(s, ext)
  local e = pb(s:extension())
  local a = pb(s)
  local r = ssub(a, 1, #a - #e)
  if ext ~= nil and ext.p.n > 0 then r = r .. (ext.p.b[0] == 46 and "" or ".") .. pb(ext) end
  s.p = str_of(r)
  return s
end
FsPath.replace_extension = FsPath.replace_extension_FsPath
function FsPath.replace_extension_Str(s, x) return s:replace_extension_FsPath(NewFsPath_Str(x)) end
function FsPath.replace_filename(s, f) s.p = s:parent_path():Join_FsPath(f).p; return s end
function FsPath.remove_filename(s) local t = pb(s); local i = rindex(t, "/"); s.p = str_of(i == nil and "" or ssub(t, 1, i)); return s end
function FsPath.Join_FsPath(s, o)
  if o:is_absolute() then return o:Clone() end
  local a = pb(s)
  if a == "" then return o:Clone() end
  if ssub(a, -1) ~= "/" and o.p.n > 0 then a = a .. "/" end
  return mk(a .. pb(o))
end
function FsPath.Join_Str(s, x) return s:Join_FsPath(NewFsPath_Str(x)) end
function FsPath.Join_CPtr(s, p) return s:Join_FsPath(NewFsPath_CPtr(p)) end
function FsPath.lexically_normal(s)
  local t = pb(s)
  if t == "" then return mk("") end
  local ab = ssub(t, 1, 1) == "/"
  local parts = {}
  for x in t:gmatch("[^/]+") do
    if x == "." then
    elseif x == ".." and #parts > 0 and parts[#parts] ~= ".." then parts[#parts] = nil
    elseif x == ".." and ab then
    else parts[#parts + 1] = x end
  end
  local r = (ab and "/" or "") .. tconcat(parts, "/")
  if ssub(t, -1) == "/" and #parts > 0 then r = r .. "/" end
  if r == "" then r = "." end
  return mk(r)
end
function NewFsPath() return mk("") end
function NewFsPath_Str(x) return setmetatable({ p = x:Clone() }, FsPath) end
function NewFsPath_CPtr(p) return mk(cbs(p)) end
function NewFsPath_str(s) return mk(s) end
local FileStatus = lua_class("FileStatus")
function FileStatus.type(s) return s.kind end
function FileStatus.Clone(s) return setmetatable({ kind = s.kind }, FileStatus) end
local ErrorCode = lua_class("ErrorCode")
local ETEXT = { [0] = "Success", [2] = "No such file or directory", [13] = "Permission denied", [17] = "File exists", [20] = "Not a directory", [21] = "Is a directory", [95] = "Operation not supported" }
function ErrorCode.Bool(s) return s.v ~= 0 end
function ErrorCode.value(s) return s.v end
function ErrorCode.clear(s) s.v = 0 end
function ErrorCode.message(s) return str_of(ETEXT[s.v] or ("Unknown error " .. s.v)) end
function NewErrorCode() return setmetatable({ v = 0 }, ErrorCode) end
function NewFileStatus() return setmetatable({ kind = 0 }, FileStatus) end
local function ps(x) return pb(x) end
function FileStatus_Of(s) return setmetatable({ kind = file_exists(s) and 1 or (dir_exists(s) and 2 or -1) }, FileStatus) end
function Fs_exists_FsPath(x) local s = ps(x); return file_exists(s) or dir_exists(s) end
function Fs_exists_FsPath_ErrorCode(x) return Fs_exists_FsPath(x) end
function Fs_is_regular_file_FsPath(x) return file_exists(ps(x)) end
function Fs_is_directory_FsPath(x) return dir_exists(ps(x)) end
local function file_length(p)
  local f = full_path(p)
  if not file_exists(p) then error(NewSysException("IO.FileNotFoundException", "Could not find file '" .. f .. "'."), 0) end
  local h = io.open(f, "rb")
  local ln = h:seek("end")
  h:close()
  return ln
end
function Fs_file_size_FsPath(x) return file_length(ps(x)) end
function Fs_file_size_FsPath_ErrorCode(x, ec)
  local s = ps(x)
  if file_exists(s) then ec.v = 0; return file_length(s) end
  ec.v = dir_exists(s) and 21 or 2
  return -1
end
function Fs_remove_FsPath(x) local s = ps(x); if file_exists(s) then os.remove(full_path(s)); return true end return false end
function Fs_remove_FsPath_ErrorCode(x, ec)
  ec.v = 0
  local s = ps(x)
  if file_exists(s) then if os.remove(full_path(s)) or not file_exists(s) then return true end ec.v = 13; return false end
  if dir_exists(s) then if os.remove(full_path(s)) then return true end ec.v = 13; return false end
  return false
end
function Fs_rename_FsPath_FsPath_ErrorCode(a, b, ec)
  local ok, fa, fb = pcall(function() return full_path(ps(a)), full_path(ps(b)) end)
  if not ok then ec.v = 13; return end
  if not file_exists(fa) then ec.v = 2; return end
  if is_dir(fb) then ec.v = 13; return end
  if os.rename(fa, fb) then ec.v = 0; return end
  local par = smatch(fb, "^(.*)/[^/]*$")
  if par == nil or par == "" then par = "/" end
  ec.v = is_dir(par) and 2 or 13
end
function Fs_rename_FsPath_FsPath(a, b)
  local ec = NewErrorCode()
  Fs_rename_FsPath_FsPath_ErrorCode(a, b, ec)
  if ec.v ~= 0 then error(NewSysException("IO.IOException", "rename failed"), 0) end
end
function Fs_current_path() return NewFsPath_str(CWD) end
function Fs_absolute(x) if x:is_absolute() then return x:Clone() end return Fs_current_path():Join_FsPath(x) end
function Fs_canonical_FsPath(x) return NewFsPath_str(full_path(ps(x))) end
function Fs_weakly_canonical_FsPath(x) return NewFsPath_str(full_path(ps(x))) end
function Fs_weakly_canonical_FsPath_ErrorCode(x, ec) ec.v = 0; return Fs_weakly_canonical_FsPath(x) end
function Fs_temp_directory_path() return NewFsPath_str(os.getenv("TMPDIR") or "/tmp") end
function Fs_equivalent_FsPath_FsPath(a, b) return full_path(ps(a)) == full_path(ps(b)) end
function Fs_equivalent_FsPath_FsPath_ErrorCode(a, b, ec)
  if not (Fs_exists_FsPath(a) and Fs_exists_FsPath(b)) then ec.v = 2; return false end
  ec.v = 0
  return Fs_equivalent_FsPath_FsPath(a, b)
end
function Fs_status_FsPath(x) return FileStatus_Of(ps(x)) end
function Fs_status_FsPath_ErrorCode(x, ec) ec.v = 0; return FileStatus_Of(ps(x)) end
function Fs_symlink_status_FsPath(x) return FileStatus_Of(ps(x)) end
function Fs_symlink_status_FsPath_ErrorCode(x, ec) ec.v = 0; return FileStatus_Of(ps(x)) end
function Fs_exists_FileStatus(s) return s.kind ~= -1 end
function Fs_is_regular_file_FileStatus(s) return s.kind == 1 end
function Fs_is_directory_FileStatus(s) return s.kind == 2 end
function Fs_is_symlink() return false end
function Fs_create_hard_link(target, link, ec)
  if file_exists(ps(link)) then ec.v = 17; return end
  local ok = pcall(function()
    local fa, fb = full_path(ps(target)), full_path(ps(link))
    local i = assert(io.open(fa, "rb"))
    local d = i:read("a")
    i:close()
    local o = assert(io.open(fb, "wb"))
    o:write(d or "")
    o:close()
  end)
  ec.v = ok and 0 or 2
end

-- ------------------------------------------------------------------------------------------------ miscellany
local Atomic = lua_class("Atomic", nil, { Cpp_ICopy })
function Atomic.exchange(s, v) local o = s.v; s.v = v; return o end
function Atomic.load(s) return s.v end
function Atomic.store(s, v) s.v = v end
function Atomic.compare_exchange(s, t, k, des)
  local v, e = s.v, t[k]
  if v == e or (v ~= v and e ~= e) then s.v = des; return true end
  t[k] = v
  return false
end
Atomic.compare_exchange_weak = Atomic.compare_exchange; Atomic.compare_exchange_strong = Atomic.compare_exchange
function Atomic.Clone(s) return setmetatable({ v = s.v }, getmetatable(s)) end
function Atomic.Assign(s, o) s.v = o.v end
function Atomic.ToString(s) return cs_tostring(s.v) end
function Atomic.fetch_add(s, d) local o = s.v; s.v = s:_add(o, d); return o end
function Atomic.fetch_sub(s, d) local o = s.v; s.v = s:_add(o, -d); return o end
local AtomicD = lua_class("AtomicD", Atomic); function AtomicD._add(s, a, b) return a + b end
local AtomicF = lua_class("AtomicF", Atomic); function AtomicF._add(s, a, b) return f32(a + b) end
local AtomicI = lua_class("AtomicI", Atomic); function AtomicI._add(s, a, b) return i32(a + b) end
local AtomicL = lua_class("AtomicL", Atomic); function AtomicL._add(s, a, b) return a + b end
local AtomicZ = lua_class("AtomicZ", Atomic)
function NewAtomicD() return setmetatable({ v = 0.0 }, AtomicD) end
function NewAtomicD_T(v) return setmetatable({ v = v }, AtomicD) end
function NewAtomicF() return setmetatable({ v = 0.0 }, AtomicF) end
function NewAtomicF_T(v) return setmetatable({ v = v }, AtomicF) end
function NewAtomicI() return setmetatable({ v = 0 }, AtomicI) end
function NewAtomicI_T(v) return setmetatable({ v = v }, AtomicI) end
function NewAtomicL() return setmetatable({ v = 0 }, AtomicL) end
function NewAtomicL_T(v) return setmetatable({ v = v }, AtomicL) end
function NewAtomicZ() return setmetatable({ v = false }, AtomicZ) end
function NewAtomicZ_T(v) return setmetatable({ v = v }, AtomicZ) end
local Variant = lua_class("Variant", nil, { Cpp_ICopy })
function Variant.Set_b(s, v) s.v = v; s.idx = 0 end
function Variant.Set_i(s, v) s.v = v; s.idx = 1 end
function Variant.Set_d(s, v) s.v = v; s.idx = 2 end
function Variant.Set_Str(s, v) s.v = v:Clone(); s.idx = 3 end
function Variant.index(s) return s.idx end
function Variant.Holds(s, i) return s.idx == i end
function Variant.Get(s, i) if s.idx ~= i then error(NewBadVariantAccess(), 0) end return s.v end
function Variant.Clone(s) local c = NewVariant(); c:Assign(s); return c end
function Variant.Assign(s, o) s.idx = o.idx; if o.idx == 3 then s.v = o.v:Clone() else s.v = o.v end end
function Variant.MoveFrom(s, o) s.idx = o.idx; s.v = o.v end
function NewVariant() return setmetatable({ v = false, idx = 0 }, Variant) end
local function ident_of(o) if o == nil then return 0 end return addr_of(o) end
local function tcmp(a, b)
  if a == nil then return b ~= nil and -1 or 0 end
  if type(a) ~= "table" then
    if type(a) == "boolean" then a = a and 1 or 0; b = b and 1 or 0 end
    if a < b then return -1 end
    if b < a then return 1 end
    return 0
  end
  if isa_(a, Cpp_TBox) then local x, y = a.v, b.v; if x < y then return -1 end if y < x then return 1 end return 0 end
  if isa_(a, Cpp_Ptr) then
    local x, y = ident_of(a.a), ident_of(b.a)
    if x ~= y then return x < y and -1 or 1 end
    if a.o < b.o then return -1 end
    if b.o < a.o then return 1 end
    return 0
  end
  if a.CompareTo then return a:CompareTo(b) end
  error(NewSysException("NotSupportedException", "tuple element"), 0)
end
local TupN = lua_class("TupN", nil, { Cpp_ICopy })
function TupN.Clone(s) local v = { n = s.v.n }; for i = 0, v.n - 1 do v[i] = s.v[i] end return setmetatable({ v = v }, TupN) end
function TupN.Assign(s, o) local v = { n = o.v.n }; for i = 0, v.n - 1 do v[i] = o.v[i] end s.v = v end
function TupN.MoveFrom(s, o) s.v = o.v end
function TupN.CompareTo(s, o) for i = 0, s.v.n - 1 do local c = tcmp(s.v[i], o.v[i]); if c ~= 0 then return c end end return 0 end
function TupN.Equals(s, o) return o ~= nil and s:CompareTo(o) == 0 end
function TupN.GetHashCode(s) return s.v.n end
function NewTupN() return setmetatable({ v = { n = 0 } }, TupN) end
function NewTupN_oA(...)
  local n = select("#", ...)
  local v = { n = n }
  for i = 1, n do v[i - 1] = (select(i, ...)) end
  return setmetatable({ v = v }, TupN)
end
local TimePoint = lua_class("TimePoint")
local Duration = lua_class("Duration")
function TimePoint.Clone(s) return s end
function TimePoint.time_since_epoch(s) return setmetatable({ ns = s.ns }, Duration) end
function Duration.Clone(s) return s end
function Duration.count(s) return s.ns * 1e-9 end
TimePoint_ZERO = setmetatable({ ns = 0 }, TimePoint)
MK_TimePoint = function() return TimePoint_ZERO end
IMMUT[MK_TimePoint] = true
function TimePoint_now() return setmetatable({ ns = math.floor(os.clock() * 1e9) }, TimePoint) end
function TimePoint_op_Sub(a, b) return setmetatable({ ns = a.ns - b.ns }, Duration) end
function NewDuration_l(n) return setmetatable({ ns = n }, Duration) end
function NewDuration_Duration(d) return setmetatable({ ns = d.ns }, Duration) end
function Duration_op_Add(a, b) return setmetatable({ ns = a.ns + b.ns }, Duration) end
function Duration_op_Sub(a, b) return setmetatable({ ns = a.ns - b.ns }, Duration) end
local Mutex = lua_class("Mutex"); function Mutex.lock() end function Mutex.unlock() end function Mutex.try_lock() return true end
local CondVar = lua_class("CondVar"); function CondVar.notify_one() end function CondVar.notify_all() end
local Thread = lua_class("Thread"); function Thread.joinable() return false end function Thread.join() end
local Lock = lua_class("Lock"); local OnceFlag = lua_class("OnceFlag")
function NewMutex() return setmetatable({}, Mutex) end
function NewCondVar() return setmetatable({}, CondVar) end
function NewThread() return setmetatable({}, Thread) end
function NewLock() return setmetatable({}, Lock) end
function NewOnceFlag() return setmetatable({ done = false }, OnceFlag) end
function Std_Rethrow(e) error(e, 0) end
function Std_call_once(flag, f) if flag.done then return end f(); flag.done = true end
function Std_Nop() return 0 end
function Std_iabs_i(x) if x < 0 then return -x end return x end
Std_iabs_l = Std_iabs_i
function Std_get0_PairAB(p) return p.first end
function Std_get1_PairAB(p) return p.second end
for _, s in ipairs({ "ID", "II", "IO", "LO", "OD", "OI", "OL", "OS", "OZ", "DD", "DI", "LL", "LD", "IL", "OO", "ZO", "BO", "OB", "IZ", "IB", "LI", "DO", "IF", "OF" }) do
  _ENV["Std_get0_PairAB__" .. s] = Std_get0_PairAB; _ENV["Std_get1_PairAB__" .. s] = Std_get1_PairAB
end
function Std_swap(ta, ka, tb, kb) local t = ta[ka]; ta[ka] = tb[kb]; tb[kb] = t end
for _, c in ipairs({ "D", "F", "I", "L", "B", "S", "C", "Z" }) do _ENV["Std_swap__" .. c] = Std_swap end
function Std_exchange(t, k, v) local o = t[k]; t[k] = v; return o end
function Std_release(t, k) local r = t[k]; t[k] = nil; return r end
local FromCharsResult = lua_class("FromCharsResult")
function FromCharsResult.Clone(s) return s end
local function fcr(ptr, ec) return setmetatable({ ptr = ptr, ec = ec }, FromCharsResult) end
local function range_bytes(f, l) return bytes_str(f.B, f.O, l.O - f.O) end
function Std_from_chars_CPtr_CPtr_dr(first, last, t, k)
  local s = range_bytes(first, last)
  local kk = ssub(s, 1, 1) == "-" and 1 or 0
  local c = #s > kk and sbyte(s, kk + 1) or 0
  local lc = (c >= 65 and c <= 90) and (c | 0x20) or c
  if not ((c >= 48 and c <= 57) or c == 46 or lc == 105 or lc == 110) then return fcr(first, 22) end
  if c == 48 and kk + 1 < #s and (sbyte(s, kk + 2) | 0x20) == 120 then s = ssub(s, 1, kk + 1) end
  local r, e = scan_double(s, 0, false)
  if e <= 0 then return fcr(first, 22) end
  local ptr = newcp(first.B, first.O + e)
  if (r == huge or r == -huge) and lc ~= 105 then return fcr(ptr, 34) end
  if r == 0 then
    for j = kk + 1, e do
      local d = sbyte(s, j)
      if d == 101 or d == 69 then break end
      if d >= 49 and d <= 57 then return fcr(ptr, 34) end
    end
  end
  t[k] = r
  return fcr(ptr, 0)
end
local function int_chars(first, last, signed, lo, hi, t, k)
  local s = range_bytes(first, last)
  local i, neg = 1, false
  if signed and ssub(s, 1, 1) == "-" then neg = true; i = 2 end
  local j = i
  while j <= #s and sbyte(s, j) >= 48 and sbyte(s, j) <= 57 do j = j + 1 end
  if j == i then return fcr(first, 22) end
  local d = ssub(s, i, j - 1):gsub("^0+(%d)", "%1")
  local ptr = newcp(first.B, first.O + j - 1)
  local lim = neg and (lo == 0 and "0" or (lo == -2147483648 and "2147483648" or "9223372036854775808")) or hi
  if #d > #lim or (#d == #lim and d > lim) then return fcr(ptr, 34) end
  local v = 0
  for q = 1, #d do v = v * 10 + (sbyte(d, q) - 48) end
  t[k] = neg and -v or v
  return fcr(ptr, 0)
end
function Std_from_chars_CPtr_CPtr_ir(f, l, t, k) return int_chars(f, l, true, -2147483648, "2147483647", t, k) end
function Std_from_chars_CPtr_CPtr_lr(f, l, t, k) return int_chars(f, l, true, mininteger, "9223372036854775807", t, k) end
function Std_from_chars_CPtr_CPtr_ur(f, l, t, k) return int_chars(f, l, false, 0, "4294967295", t, k) end
function Std_from_chars_CPtr_CPtr_ulr(f, l, t, k) return int_chars(f, l, false, 0, "18446744073709551615", t, k) end
-- std::thread::hardware_concurrency is glibc's get_nprocs: the ranges in /sys/devices/system/cpu/online, else the cpuN
-- lines of /proc/stat, else 2 (glibc's last resort)
function Sys_hardware_concurrency()
  local f = io.open("/sys/devices/system/cpu/online", "r")
  if f then
    local l = f:read("l")
    f:close()
    if l then
      local n = 0
      for r in l:gmatch("[^,]+") do
        local a, b = smatch(r, "^%s*(%d+)%-(%d+)")
        if a then n = n + tonumber(b) - tonumber(a) + 1 elseif smatch(r, "%d") then n = n + 1 end
      end
      if n > 0 then return n end
    end
  end
  f = io.open("/proc/stat", "r")
  if f then
    local n = 0
    for l in f:lines() do if smatch(l, "^cpu%d") then n = n + 1 end end
    f:close()
    if n > 0 then return n end
  end
  return 2
end
