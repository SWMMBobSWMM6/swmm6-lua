-- streamcheck.lua a|c - sections a and c of tests/stdcheck/streamcheck.cpp / streamcheck.cs through the Lua runtime's
-- streams (lua/rt/io.lua), statement for statement as perl/test/streamcheck.pl: section a (formatting, extraction,
-- files) must equal the C++ output or the C# output (they differ on one glibc %#g line), section c both. Section b
-- (the C# port's own stream and file-system behaviour, much of it calls the engine never makes) is not ported.
-- Run from a folder that has a build/ subfolder (paths are relative to it):
--   python3 lua/test/runlua.py lua/test/streamcheck.lua a|c
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
return function(dir, section)
  local E = { CWD = os.getenv("PWD") or "/" }
  for _, n in ipairs({ "core", "strvec", "primes", "containers", "glibm_rt", "glibm", "crt", "io" }) do
    assert(loadfile(dir .. "/rt/" .. n .. ".lua", "t"))(E)
  end
  E.inherit_all()
  local Ios_app, Ios_binary, Ios_in, Ios_out, Ios_trunc, Ios_beg, Ios_cur, Ios_end = 1, 4, 8, 16, 32, 0, 1, 2
  local Ios_fixed, Ios_scientific, Ios_floatfield = 4, 256, 260
  local sb = {}
  local function fb(u) return (string.unpack("<d", string.pack("<i8", u))) end
  local function st(s) return (s:good() and "g" or "-") .. (s:eof() and "e" or "-") .. (s:fail_() and "f" or "-") .. (s:bad() and "b" or "-") end
  local function g(v) local o = E.NewOStringStream(); o:Put_d(v); return E.str_text(o:str_()) end
  local function S(x) return E.str_of(x) end
  local function b(x) return x and "1" or "0" end
  local function w(x) sb[#sb + 1] = x end
  local function t(x) return E.str_text(x) end
  local function c(x) return string.byte(x) end
  local function arr(n, v) local a = { n = n }; for i = 0, n - 1 do a[i] = v end return a end
  local function upto0(a, n) local k = 0; local r = {}; while k < n and a[k] ~= 0 do r[#r + 1] = string.char(a[k] & 255); k = k + 1 end return table.concat(r) end
  local function ts(v) return E.cs_tostring(v) end

  local function sec_c()
    local f = E.NewIFStream_Str_i(S("build/streamcheck.bin"), Ios_in | Ios_binary)
    local bb = arr(1, 0)
    f:read_PtrT_l__I(E.NewPtrI_TA_l(bb, 0), 4)
    f:seekg(4, Ios_cur)
    f:read_PtrT_l__I(E.NewPtrI_TA_l(bb, 0), 4)
    w("cur at8 " .. bb[0] .. " tellg " .. f:tellg() .. " " .. st(f) .. "\n")
  end

  local function sec_a()
    local vals = { 0.0, fb(math.mininteger), 1.0, -1.0, 0.1, 0.5, 1.5, 2.5, 123.456, 1e-5, 1.23456789e-7, 1e21,
      1.7976931348623157e308, fb(1), 2.2250738585072014e-308, 1.0 / 3.0, 2.0 / 3.0, 100.0, 1e15,
      123456789012345678.0, 0.000123456, 9.999999, 99.995, 0.125, fb(0x7ff8000000000000),
      fb(0x7ff0000000000000), fb(-4503599627370496), 1e100, 5e-310, 3.14159265358979, -0.0004567, 1234567.0,
      0.95, 0.05, 1e-300, 6.02214076e23 }
    local precs = { 0, 1, 2, 3, 4, 6, 8, 10, 15, 16, 17, 20, -1 }
    for _, v in ipairs(vals) do
      for mode = 0, 3 do
        for sp = 0, 1 do
          for _, p in ipairs(precs) do
            if not (mode == 3 and p ~= 6) then
              local o = E.NewOStringStream()
              if mode == 1 then o:Manip_fixed() end
              if mode == 2 then o:Manip_scientific() end
              if mode == 3 then o:setf_i_i(Ios_fixed | Ios_scientific, Ios_floatfield) end
              if sp == 1 then o:Manip_showpoint() end
              o:precision_l(p)
              o:Put_d(v)
              w("d " .. mode .. sp .. " " .. p .. " [" .. t(o:str_()) .. "]\n")
            end
          end
        end
      end
      local f = E.NewOStringStream()
      f:Put_f(E.f32(v))
      w("f [" .. t(f:str_()) .. "]\n")
    end
    local o = E.NewOStringStream()
    o:Put_c(c("[")):Manip_setw(10):Put_d(3.5):Put_CPtr(E.R_Lit("][")):Manip_left():Manip_setw(8):Manip_setfill(c("*")):Put_i(-42):Put_c(c("]"))
    o:Put_c(c("[")):Manip_right():Manip_setw(6):Put_CPtr(E.R_Lit("ab")):Put_CPtr(E.R_Lit("][")):Manip_setw(2):Put_CPtr(E.R_Lit("abcdef")):Put_c(c("]"))
    o:Put_c(c("[")):Manip_setw(5):Manip_setfill(c("0")):Put_u(7):Put_CPtr(E.R_Lit("][")):Put_i(123):Put_c(c("]"))
    o:Manip_boolalpha():Put_c(c("[")):Put_b(true):Put_c(c(" ")):Put_b(false):Put_c(c("]")):Manip_noboolalpha():Put_c(c("[")):Put_b(true):Put_b(false):Put_c(c("]"))
    o:Put_c(c("[")):Manip_setw(12):Manip_setfill(c(" ")):Manip_quoted_Str(S('a"b\\c')):Put_c(c("]"))
    o:Put_c(c("[")):Manip_quoted_CPtr(E.R_Lit("plain")):Put_c(c("]"))
    o:Put_c(c("[")):Manip_fixed():Manip_setprecision(3):Manip_setw(9):Put_d(2.0 / 3.0):Put_c(c("]"))
    o:Put_c(c("[")):Manip_defaultfloat():Manip_setprecision(4):Put_d(2.0 / 3.0):Put_c(c("]"))
    o:Put_c(c("[")):Put_l(math.mininteger):Put_c(c(" ")):Put_ul(-1):Put_c(c(" ")):Put_s(-5):Put_c(c("]"))
    o:Put_c(c("[")):Put_c(c("x")):Put_c(65):Put_c(c("]"))
    w("w " .. t(o:str_()) .. "\n")

    o = E.NewOStringStream_Str(S("abcdef"))
    o:Put_CPtr(E.R_Lit("XY"))
    w("init [" .. t(o:str_()) .. "] tellp " .. o:tellp() .. "\n")
    local q = E.NewOStringStream()
    q:Put_CPtr(E.R_Lit("hello world"))
    q:seekp(6)
    q:Put_CPtr(E.R_Lit("W"))
    q:seekp(-1, Ios_end)
    q:Put_CPtr(E.R_Lit("D"))
    q:seekp(2, Ios_beg)
    q:seekp(1, Ios_cur)
    q:Put_CPtr(E.R_Lit("L"))
    w("seekp [" .. t(q:str_()) .. "] tellp " .. q:tellp() .. "\n")

    local is = E.NewIStringStream_Str(S("  3.25 -7 abc\nline two\n\nlast"))
    local r = { -1.0, -1, -1, -1, -1, -1 }
    local sv = E.NewStr()
    is:Get_dr(r, 1)
    w("x d " .. g(r[1]) .. " " .. st(is) .. "\n")
    is:Get_ir(r, 2)
    w("x i " .. ts(r[2]) .. " " .. st(is) .. "\n")
    is:Get_Str(sv)
    w("x s " .. t(sv) .. " " .. st(is) .. "\n")
    local line = E.NewStr()
    for _ = 1, 4 do E.Streams_getline_IStream_Str(is, line); w("x line [" .. t(line) .. "] " .. st(is) .. "\n") end

    is = E.NewIStringStream_Str(S("12 4294967296 -2147483648 2147483648 -9223372036854775808 9000000000000000000 4294967295 7"))
    r = { -1, -1, -1, -1 }
    is:Get_ir(r, 1):Get_ir(r, 2)
    w("x ints " .. ts(r[1]) .. " " .. ts(r[2]) .. " " .. st(is) .. "\n")
    is:clear()
    is:Get_ir(r, 3):Get_ir(r, 4)
    w("x ints " .. ts(r[3]) .. " " .. ts(r[4]) .. " " .. st(is) .. "\n")
    is:clear()
    local l = { -1 }
    is:Get_lr(l, 1)
    w("x long " .. ts(l[1]) .. " " .. st(is) .. "\n")
    is:clear()
    local u = { 0, 0 }
    is:Get_ulr(u, 1)
    w("x ulong " .. E.cs_tostring_u64(u[1]) .. " " .. st(is) .. "\n")
    is:clear()
    is:Get_ur(u, 2)
    w("x uint " .. ts(u[2]) .. " " .. st(is) .. "\n")

    is = E.NewIStringStream_Str(S("a,b,,c"))
    local fl = E.NewStr()
    while E.Streams_getline_IStream_Str_c(is, fl, c(",")):ok() do w("x field [" .. t(fl) .. "] " .. st(is) .. "\n") end
    w("x field end " .. st(is) .. "\n")

    is = E.NewIStringStream_Str(S("   \t\n  tail"))
    is:Manip_ws()
    local rest = E.NewStr()
    E.Streams_getline_IStream_Str(is, rest)
    w("x ws [" .. t(rest) .. "] " .. st(is) .. "\n")
    local e2 = E.NewIStringStream_Str(S("   "))
    e2:Manip_ws()
    w("x ws-end " .. st(e2) .. "\n")

    is = E.NewIStringStream_Str(S("0123456789"))
    local buf = arr(16, 0)
    is:read_CPtr_l(E.newcp(buf, 0), 4)
    w("r [" .. upto0(buf, 4) .. "] gc " .. is:gcount() .. " " .. st(is) .. " tellg " .. is:tellg() .. "\n")
    w("r peek " .. is:peek())
    w(" get " .. is:get_())
    w(" get " .. is:get_() .. " " .. st(is) .. "\n")
    is:ignore(3, c("8"))
    w("r ignore tellg " .. is:tellg() .. " " .. st(is) .. "\n")
    is:seekg(-2, Ios_cur)
    w("r seekg cur tellg " .. is:tellg() .. " get " .. is:get_() .. "\n")
    is:seekg(-3, Ios_end)
    w("r seekg end tellg " .. is:tellg() .. " get " .. is:get_() .. "\n")
    is:read_CPtr_l(E.newcp(buf, 0), 10)
    w("r short gc " .. is:gcount() .. " " .. st(is) .. "\n")
    is:clear()
    is:seekg(0, Ios_beg)
    w("r rewind tellg " .. is:tellg() .. " get " .. is:get_() .. " " .. st(is) .. "\n")
    is:ignore(100, -1)
    w("r ignore-all " .. st(is) .. "\n")
    w("r get-end " .. is:get_())
    w(" " .. st(is) .. "\n")
    w("r str [" .. t(is:str_()) .. "]\n")

    local f = E.NewOFStream_Str_i(S("build/streamcheck.bin"), Ios_trunc | Ios_binary)
    w("f open " .. b(f:is_open()) .. " " .. st(f) .. "\n")
    local ai = { [0] = 1, -2, 300000, n = 3 }
    local ad = { [0] = 1.5, -0.25, n = 2 }
    f:write_PtrT_l__I(E.NewPtrI_TA_l(ai, 0), 12)
    f:write_PtrT_l__D(E.NewPtrD_TA_l(ad, 0), 16)
    f:write_CPtr_l(E.R_Lit("MAGIC"), 5)
    w("f tellp " .. f:tellp() .. "\n")
    f:Put_d(3.25):Put_c(c(" ")):Put_i(42):Put_c(c("\n"))
    w("f tellp " .. f:tellp() .. "\n")
    f:close()
    w("f closed " .. b(f:is_open()) .. "\n")

    f = E.NewOFStream_Str_i(S("build/streamcheck.bin"), Ios_app)
    f:Put_CPtr(E.R_Lit("tail\n"))
    f:Dispose()

    f = E.NewIFStream_Str_i(S("build/streamcheck.bin"), Ios_in | Ios_binary)
    w("f in open " .. b(f:is_open()) .. " " .. st(f) .. "\n")
    ai = arr(3, 0)
    f:read_PtrT_l__I(E.NewPtrI_TA_l(ai, 0), 12)
    w("f ints " .. ai[0] .. " " .. ai[1] .. " " .. ai[2] .. " gc " .. f:gcount() .. " tellg " .. f:tellg() .. "\n")
    ad = arr(2, 0.0)
    f:read_PtrT_l__D(E.NewPtrD_TA_l(ad, 0), 16)
    w("f dbl " .. g(ad[0]) .. " " .. g(ad[1]) .. " tellg " .. f:tellg() .. "\n")
    local m = arr(6, 0)
    f:read_CPtr_l(E.newcp(m, 0), 5)
    w("f magic " .. upto0(m, 6) .. "\n")
    local xn = { 0.0, 0 }
    local tt = E.NewStr()
    f:Get_dr(xn, 1):Get_ir(xn, 2):Get_Str(tt)
    w("f text " .. g(xn[1]) .. " " .. ts(xn[2]) .. " " .. t(tt) .. " " .. st(f) .. "\n")
    f:seekg(-5, Ios_end)
    E.Streams_getline_IStream_Str(f, tt)
    w("f end-5 [" .. t(tt) .. "] " .. st(f) .. "\n")
    E.Streams_getline_IStream_Str(f, tt)
    w("f after " .. st(f) .. "\n")
    f:clear()
    f:seekg(0, Ios_end)
    w("f size " .. f:tellg() .. "\n")
    f:seekg(4, Ios_beg)
    local b1 = arr(1, 0)
    f:read_PtrT_l__I(E.NewPtrI_TA_l(b1, 0), 4)
    w("f at4 " .. b1[0] .. " tellg " .. f:tellg() .. "\n")
    f:seekg(1000, Ios_beg)
    f:read_PtrT_l__I(E.NewPtrI_TA_l(b1, 0), 4)
    w("f past-end gc " .. f:gcount() .. " " .. st(f) .. "\n")
    f:close()

    f = E.NewIFStream_Str_i(S("build/no-such-file.bin"), Ios_in)
    w("f missing open " .. b(f:is_open()) .. " " .. st(f) .. "\n")
  end

  if (section or "a") == "a" then sec_a() else sec_c() end
  local s = table.concat(sb)
  E.Streams_cout:write_CPtr_l(E.R_Lit(s), #s)
  E.R_FlushAll()
  return 0
end
