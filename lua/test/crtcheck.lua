-- crtcheck.lua - the Lua side of tests/crtcheck (as perl/test/crtcheck.pl is the Perl side):
--   python3 lua/test/runlua.py lua/test/crtcheck.lua libm N | printf | scanf | misc | units
-- reads what the C program of the same name (tests/crtcheck: libm.c, printf.c, scanf.c, misc.cpp, and
-- tests/crtcheck/pycheck/specs.c for every printf conversion the engine's format strings use) wrote on stdin and
-- reports where the Lua runtime (lua/rt) differs from glibc. The case lines and their checks are crtcheck.pl's, one for
-- one; units are its unit checks in the Lua runtime's terms (a reference is a table and a key), for the runtime
-- functions the engine uses (crtcheck.pl's check of Perl scalar references as sscanf targets has no Lua counterpart:
-- the generated engine passes R_RefI/R_RefL/R_RefD/R_RefF setters, slots and buffers, all checked here).
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
return function(dir, mode, narg)
  local E = { CWD = os.getenv("PWD") or "/" }
  for _, n in ipairs({ "core", "strvec", "primes", "containers", "glibm_rt", "glibm", "crt", "io" }) do
    assert(loadfile(dir .. "/rt/" .. n .. ".lua", "t"))(E)
  end
  E.inherit_all()            -- as the end of gen/engine.lua does: copy inherited methods down the runtime's classes
  local spack, sunpack, sfmt, schar, sbyte = string.pack, string.unpack, string.format, string.char, string.byte
  local function dbits(x) return (sunpack("<i8", spack("<d", x))) end
  local function frombits(u) return (sunpack("<d", spack("<i8", u))) end
  local function unhex(h)
    if h == "-" then return "" end
    return (h:gsub("..", function(c) return schar(tonumber(c, 16)) end))
  end
  local function hexs(s) return (s:gsub(".", function(c) return sfmt("%02x", sbyte(c)) end)) end
  local function lit(s) return E.R_Lit(s) end
  local function bytes_of(p, n)
    local t = {}
    for i = 0, n - 1 do t[#t + 1] = schar(p.B[p.O + i] & 255) end
    return table.concat(t)
  end
  local function isnan(x) return x ~= x end
  local function split(s, sep)
    local t, i = {}, 1
    while true do
      local j = s:find(sep, i, true)
      if j == nil then t[#t + 1] = s:sub(i); return t end
      t[#t + 1] = s:sub(i, j - 1)
      i = j + 1
    end
  end
  local function hex64(v) return sfmt("%016x", v) end
  local function tostr(v)
    if math.type(v) == "float" and v == math.floor(v) and v > -1e15 and v < 1e15 then return sfmt("%d", math.floor(v)) end
    return tostring(v)
  end

  local function lines(what, fn)
    local n, bad = 0, 0
    for raw in io.stdin:lines() do
      local f = split(raw, "\t")
      n = n + 1
      local want, got = fn(f)
      if want ~= got then
        bad = bad + 1
        if bad <= 15 then io.write("MISMATCH ", unhex(f[1]), "\n  glibc:  ", want, "\n  Lua:    ", got, "\n") end
      end
    end
    io.write(what, " cases: ", n, ", mismatches: ", bad, "\n")
  end

  -- ---------------------------------------------------------------------------------------------- printf
  -- hex(format) types args size ret hex(output)
  local function printf_case(f)
    local fmt = lit(unhex(f[1]))
    local vals = split(f[3], ",")
    local args = {}
    local t = f[2]
    for i = 1, #t do
      local c, v = t:sub(i, i), vals[i]
      if c == "d" then args[i] = frombits(tonumber(v, 16))
      elseif c == "i" then local x = tonumber(v, 16); args[i] = x >= 2 ^ 31 and x - (1 << 32) or x
      elseif c == "l" then args[i] = E.I64(tonumber(v, 16))
      elseif c == "s" then args[i] = lit(unhex(v))
      elseif c == "S" then args[i] = E.CPtr_ZERO end
    end
    local size = tonumber(f[4])
    local buf = E.R_Buf_i(1024)
    for i = 0, 1023 do buf.B[i] = 0x55 end
    buf.B[0] = 0
    local r = E.R_snprintf_CPtr_ul_CPtr_oA(buf, size, fmt, table.unpack(args, 1, #t))
    local out = "-"
    if size > 0 then
      local k = 0
      while buf.B[k] ~= 0 do k = k + 1 end
      if k > 0 then out = hexs(bytes_of(buf, k)) end
    end
    return f[5] .. "\t" .. f[6], tostring(r) .. "\t" .. out
  end

  -- ---------------------------------------------------------------------------------------------- scanf
  -- hex(format) hex(input) types ret values; the targets are the kinds the engine passes
  local function scanf_case(f)
    local fmt = lit(unhex(f[1]))
    local inp = lit(unhex(f[2]))
    local types = f[3]
    local m = #types
    local ints, longs, floats, doubles, bufs, args = {}, {}, {}, {}, {}, {}
    local f55 = (sunpack("<f", "\x55\x55\x55\x55"))
    for k = 1, m do ints[k] = 0x55555555; longs[k] = 0x5555555555555555; floats[k] = f55; doubles[k] = frombits(0x5555555555555555) end
    for k = 1, m do
      local c = types:sub(k, k)
      if c == "i" or c == "n" then args[k] = E.R_RefI(function(v) ints[k] = v end)
      elseif c == "u" then args[k] = E.R_RefL(function(v) ints[k] = E.i32(v) end)
      elseif c == "l" then args[k] = E.R_RefL(function(v) longs[k] = v end)
      elseif c == "f" then args[k] = E.R_RefF(function(v) floats[k] = v end)
      elseif c == "d" then args[k] = E.R_RefD(function(v) doubles[k] = v end)
      elseif c == "k" then ints[k] = 0x55; args[k] = E.R_RefI(function(v) ints[k] = ((v + 0x80) & 0xFF) - 0x80 end)
      elseif c == "s" or c == "c" then
        bufs[k] = E.R_Buf_i(64)
        for i = 0, 63 do bufs[k].B[i] = 0x55 end
        args[k] = bufs[k]
      end
    end
    local r = E.R_sscanf(inp, fmt, table.unpack(args, 1, m))
    local parts = {}
    for k = 1, m do
      local c = types:sub(k, k)
      if c:find("[inuk]") then parts[#parts + 1] = tostring(ints[k])
      elseif c == "l" then parts[#parts + 1] = tostring(longs[k])
      elseif c == "f" then parts[#parts + 1] = sfmt("%08x", (sunpack("<I4", E.float_bytes(floats[k]))))
      elseif c == "d" then parts[#parts + 1] = hex64(dbits(doubles[k]))
      else parts[#parts + 1] = hexs(bytes_of(bufs[k], 12)) end
      parts[#parts + 1] = " "
    end
    return f[4] .. "\t" .. (f[5] or ""), tostring(r) .. "\t" .. table.concat(parts)
  end

  -- ---------------------------------------------------------------------------------------------- misc
  -- kind hex(input) result
  local function misc_case(f)
    local raw = unhex(f[2])
    local s = lit(raw)
    local e = E.CPtr_op_Add_CPtr_i(s, #raw)
    local k = f[1]
    local got
    local cell = { 0 }
    if k == "fci" or k == "fcu" or k == "fcl" then
      cell[1] = k == "fcl" and 0x5555555555555555 or 0x55555555
      local r
      if k == "fci" then r = E.Std_from_chars_CPtr_CPtr_ir(s, e, cell, 1)
      elseif k == "fcu" then r = E.Std_from_chars_CPtr_CPtr_ur(s, e, cell, 1)
      else r = E.Std_from_chars_CPtr_CPtr_lr(s, e, cell, 1) end
      got = r.ec .. " " .. E.CPtr_Diff(r.ptr, s) .. " " .. tostring(cell[1])
    elseif k == "fcd" then
      cell[1] = 0.25
      local r = E.Std_from_chars_CPtr_CPtr_dr(s, e, cell, 1)
      got = sfmt("%d %d %016x", r.ec, E.CPtr_Diff(r.ptr, s), dbits(cell[1]))
    elseif k == "strtol" then
      cell[1] = s
      local v = E.R_strtol(s, cell, 1)
      got = tostring(v) .. " " .. E.CPtr_Diff(cell[1], s)
    elseif k == "atoi" then got = tostring(E.R_atoi(s))
    elseif k == "atol" then got = tostring(E.R_atol(s))
    elseif k == "strtod" then
      cell[1] = s
      local v = E.R_strtod_CPtr_CPtrr(s, cell, 1)
      got = sfmt("%016x %d", dbits(v), E.CPtr_Diff(cell[1], s))
    elseif k == "ctime" then
      local p = E.R_ctime_Ptrl(E.NewPtrL_TA_l({ [0] = math.tointeger(tonumber(raw)), n = 1 }, 0))
      got = hexs(bytes_of(p, E.R_strlen(p)))
    elseif k == "nprocs" then got = tostring(E.Sys_hardware_concurrency())
    elseif k == "ctype" then
      local c = math.tointeger(tonumber(raw))
      got = sfmt("%d%d%d%d%d%d%d%d%d %d %d", E.R_isdigit(c), E.R_isalpha(c), E.R_isalnum(c), E.R_isspace(c), E.R_isupper(c),
        E.R_islower(c), E.R_ispunct(c), E.R_isprint(c), E.R_isxdigit(c), E.R_toupper(c), E.R_tolower(c))
    else error("misc kind " .. k) end
    if got ~= f[3] then got = got .. "  (" .. k .. " " .. hexs(raw) .. ")" end
    return f[3], got
  end

  -- ---------------------------------------------------------------------------------------------- libm
  -- each function as the engine calls it (the engine's local aliases L_exp, L_log, ... are these runtime globals)
  local FN = { "atan2", "cbrt", "cosh", "sinh", "tanh", "log2", "expm1", "log1p", "hypot", "fmod", "remainder", "round",
    "nextafter", "exp", "log", "pow", "sin", "cos", "tan", "asin", "acos", "atan", "log10", "floor", "ceil", "trunc", "sqrt" }
  local F = { E.Math_Atan2_d, E.Math_Cbrt_d, E.Math_Cosh_d, E.Math_Sinh_d, E.Math_Tanh_d, E.Math_Log2_d, E.LibM_expm1,
    E.LibM_log1p, E.LibM_hypot, E.LibM_fmod, E.LibM_remainder, E.LibM_round, E.LibM_nextafter, E.L_math_exp, E.Math_Log_d,
    E.Math_Pow_d, E.L_math_sin, E.L_math_cos, E.Math_Tan_d, E.Math_Asin_d, E.Math_Acos_d, E.Math_Atan_d, E.Math_Log10_d,
    E.Math_Floor_d, E.Math_Ceiling_d, E.Math_Truncate_d, E.L_math_sqrt }
  local NSPEC = 24
  local function show(x)
    local b = dbits(x)
    if isnan(x) then
      return (b < 0 and "-nan" or "nan") .. ((b & 0x7FFFFFFFFFFFFFFF) == 0x7FF8000000000000 and "" or sfmt("(0x%x)", b & 0xFFFFFFFFFFFFF))
    end
    if x == 0 then return b < 0 and "-0" or "0" end
    return sfmt("%.17g", x)
  end
  local function ulps(a, b)
    local ia, ib = dbits(a), dbits(b)
    if ia < 0 then ia = math.mininteger - ia end
    if ib < 0 then ib = math.mininteger - ib end
    local d = ia - ib
    return d < 0 and -d or d
  end
  local function libm(n)
    local per = n + NSPEC * NSPEC
    io.write(sfmt("%-10s %8s %10s %9s %8s %10s  %s\n", "function", "cases", "mismatch", "NaN-sign", "max ulp", "special",
      "first mismatch (x, y: glibc vs Lua)"))
    local total = 0
    for fi = 1, #FN do
      local fn = F[fi]
      local bad, nan_sign, maxu, sbad, nan_num, first = 0, 0, 0, 0, false, ""
      local k = 0
      while k < per do
        local m = per - k < 20000 and per - k or 20000
        local data = io.stdin:read(m * 24)
        if data == nil or #data < m * 24 then error("short input") end
        for j = 0, m - 1 do
          local x, y, want = sunpack("<d<d<i8", data, j * 24 + 1)
          local g = fn(x, y)
          local got = dbits(g)
          if got ~= want then
            bad = bad + 1
            if k + j >= n then sbad = sbad + 1 end
            local w = frombits(want)
            if isnan(w) and isnan(g) then nan_sign = nan_sign + 1
            elseif not isnan(w) and not isnan(g) then local u = ulps(w, g); if u > maxu then maxu = u end
            else nan_num = true end
            if first == "" then first = show(x) .. ", " .. show(y) .. ": " .. show(w) .. " vs " .. show(g) end
          end
        end
        k = k + m
      end
      total = total + bad
      io.write(sfmt("%-10s %8d %10d %9d %8s %10d  %s\n", FN[fi], per, bad, nan_sign, nan_num and "NaN/num" or tostring(maxu), sbad, first))
    end
    io.write("total mismatches: ", total, "\n")
  end

  -- ---------------------------------------------------------------------------------------------- units
  local un, ubad = 0, 0
  local function check(name, ok, ...)
    un = un + 1
    if ok then return end
    ubad = ubad + 1
    local d = {}
    for i = 1, select("#", ...) do d[#d + 1] = tostring((select(i, ...))) end
    io.write("FAIL ", name, " (", table.concat(d, " "), ")\n")
  end
  local function slurp(p) local h = io.open(p, "rb"); if not h then return nil end local t = h:read("a"); h:close(); return t end
  local function arr(...) local t = { ... }; local a = { n = #t }; for i = 1, #t do a[i - 1] = t[i] end return a end
  local function cptr(...) return E.newcp and E.newcp(arr(...), 0) or E.CPtr_new(arr(...), 0) end
  local function Bvals(p) local t = {}; for i = 0, p.B.n - 1 do t[#t + 1] = tostring(p.B[i]) end return table.concat(t, " ") end
  local INF = 1.0 / 0.0

  local function units()
    -- sscanf into pointer parameters: the stash and R_Back, as the engine's parsers use them
    local c = { -9, sbyte("q") }
    local r = E.R_Back_i_T1r_T2r__LB(E.R_sscanf(E.R_Lit("123 Y"), E.R_Lit("%ld %c"), E.R_Slot, E.R_Slot), c, 1, c, 2)
    check("slot %ld %c", r == 2 and c[1] == 123 and c[2] == sbyte("Y"), r, c[1], c[2])
    c = { -9, sbyte("q") }
    r = E.R_Back_i_T1r_T2r__LB(E.R_sscanf(E.R_Lit("77"), E.R_Lit("%ld %c"), E.R_Slot, E.R_Slot), c, 1, c, 2)
    check("slot partial", r == 1 and c[1] == 77 and c[2] == sbyte("q"), r, c[1], c[2])
    local x = 99.99
    c = { sbyte("q") }
    r = E.R_Back_i_T1r__B(E.R_sscanf(E.R_Lit("1.5 X"), E.R_Lit("%f %c"), E.R_RefF(function(v) x = v end), E.R_Slot), c, 1)
    check("RefF + slot", r == 2 and x == 1.5 and c[1] == sbyte("X"), r, x, c[1])
    local s1 = E.R_Buf_i(80)
    r = E.R_sscanf(E.R_Lit("  SWMM5 x"), E.R_Lit("%s"), s1)
    check("%s CPtr", r == 1 and E.R_strcmp(s1, E.R_Lit("SWMM5")) == 0, r)
    local lb = E.newcp(arr(0, 0, 0, 0, 0, 0, 0, 0), 0)
    r = E.R_sscanf(E.R_Lit("xy\xE9"), E.R_Lit("%s"), lb)
    check("%s into a byte buffer", r == 1 and lb.B[0] == 120 and lb.B[1] == 121 and (lb.B[2] & 255) == 233 and lb.B[3] == 0, Bvals(lb))

    -- strtod details: hex floats, NaN payloads, the end pointer, ERANGE
    local en = { E.CPtr_ZERO }
    local s = E.R_Lit("  0x1.8p1rest")
    check("strtod hex", E.R_strtod_CPtr_CPtrr(s, en, 1) == 3.0 and E.CPtr_Diff(en[1], s) == 9)
    check("strtod nan payload", dbits(E.R_strtod_CPtr(E.R_Lit("nan(0x5)"))) == 0x7ff8000000000005)
    check("strtod -nan", dbits(E.R_strtod_CPtr(E.R_Lit("-nan"))) == dbits(frombits(0xfff8000000000000)))
    s = E.R_Lit("abc")
    check("strtod no number", E.R_strtod_CPtr_CPtrr(s, en, 1) == 0.0 and E.CPtr_op_Eq(en[1], s))
    check("strtod huge exponent", E.R_strtod_CPtr(E.R_Lit("1e99999999999")) == INF and E.R_strtod_CPtr(E.R_Lit("1e-99999999999")) == 0.0)
    local er = {}
    for _, t in ipairs({ { "1e999", 1 }, { "-1e999", 1 }, { "1e-400", 1 }, { "2.2250738585072011e-308", 1 }, { "2.22507385850720138e-308", 0 },
      { "2.2250738585072014e-308", 0 }, { "4.9e-324", 1 }, { "1.5", 0 }, { "0", 0 }, { "0e-999", 0 }, { "0x1p-1080", 1 },
      { "0x1p99999", 1 }, { "inf", 0 }, { "abc", 0 }, { "4.940656458412465441765687928682213723651e-324", 1 },
      { "4.940656458412465441248710587739e-324", 1 }, { "0x3p-1074", 0 } }) do
      E.R_strtod_CPtr(E.R_Lit(t[1]))
      if (E.R_get_ERange() and 1 or 0) ~= t[2] then er[#er + 1] = t[1] end
    end
    check("strtod ERANGE", #er == 0, table.concat(er, " "))
    check("atof", E.R_atof(E.R_Lit(" -2.5e1x")) == -25.0)

    -- raw memory
    local b = arr(0)
    E.Mem_memcpy_PtrT_PtrU_ul__LD(E.NewPtrL_TA_l(b, 0), E.NewPtrD_TA_l(arr(-2.75), 0), 8)
    check("memcpy double->u64 (unsigned)", b[0] == dbits(-2.75), b[0])
    local view = E.Bytes_View_PtrT__L(E.NewPtrL_TA_l(arr(0x0102030405060708), 0))
    check("bytes view", view.B.n - view.O == 8 and view.B[view.O] == 8 and view.B[view.O + 7] == 1)
    local fa = arr(0.0)
    E.Mem_memcpy_PtrT_CPtr_ul__D(E.NewPtrD_TA_l(fa, 0), view, 8)
    check("memcpy CPtr->double", dbits(fa[0]) == 0x0102030405060708)
    local cl = E.Mem_Calloc__D(5, 8)
    check("calloc", cl.a.n == 5 and cl.o == 0 and cl.a[4] == 0.0 and math.type(cl.a[4]) == "float")
    local u = arr(0, 0)
    E.Mem_memcpy_PtrT_PtrU_ul__IB(E.NewPtrI_TA_l(u, 1), E.NewPtrB_TA_l(arr(1, 2, 3, 4, 5), 1), 4)
    check("memcpy bytes->u32 offset", u[0] == 0 and u[1] == 0x05040302, u[0], u[1])
    local w = arr(0x11111111, 0x22222222)
    E.Mem_memcpy_PtrT_CPtr_ul__I(E.NewPtrI_TA_l(w, 0), E.newcp(arr(1, 2, 3, 4, 5, 6), 0), 6)
    check("memcpy partial element", w[0] == 0x04030201 and w[1] == 0x22220605, w[0], w[1])
    local neg = arr(0)
    E.Mem_memcpy_PtrT_CPtr_ul__I(E.NewPtrI_TA_l(neg, 0), E.newcp(arr(255, 255, 255, 255), 0), 4)
    check("memcpy int (signed)", neg[0] == -1, neg[0])
    local zv = E.Bytes_View_PtrT__Z(E.NewPtrZ_TA_l(arr(true, false, true), 1))
    check("bool view", zv.B.n - zv.O == 2 and zv.B[zv.O] == 0 and zv.B[zv.O + 1] == 1)
    local dv = E.Bytes_View_PtrT__D(E.NewPtrD_TA_l(arr(1.0, 2.0), 1))
    check("double view offset", dv.B.n - dv.O == 8 and dv.B[dv.O + 7] == 0x40 and dv.B[dv.O + 6] == 0)
    local sh = arr(0, 0)
    E.Mem_memcpy_PtrT_CPtr_ul__S(E.NewPtrS_TA_l(sh, 0), E.newcp(arr(0xff, 0x7f, 0x01, 0x80), 0), 4)
    check("memcpy shorts", sh[0] == 0x7FFF and sh[1] == -0x7FFF, sh[0], sh[1])
    local fl = arr(0.0)
    E.Mem_memcpy_PtrT_CPtr_ul__F(E.NewPtrF_TA_l(fl, 0), E.Bytes_View_PtrT__F(E.NewPtrF_TA_l(arr(E.f32(0.1)), 0)), 4)
    check("memcpy float", fl[0] == E.f32(0.1), fl[0])
    local nv = E.Bytes_View_PtrT__F(E.NewPtrF_TA_l(arr(frombits(0xFFF8000000000123)), 0))
    check("float NaN bytes", nv.B[nv.O] == 0 and nv.B[nv.O + 1] == 0 and nv.B[nv.O + 2] == 192 and nv.B[nv.O + 3] == 255,
      nv.B[nv.O], nv.B[nv.O + 1], nv.B[nv.O + 2], nv.B[nv.O + 3])

    -- binary and text files
    local dr = (os.getenv("TMPDIR") or "/tmp") .. "/lua6_crtcheck_" .. tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9))
    assert(os.execute("mkdir -p '" .. dr .. "'"))
    local name = E.R_Lit(dr .. "/t.bin")
    local fp = E.R_fopen(name, E.R_Lit("w+b"))
    E.Mem_fwrite_CPtr_ul_ul_CFile(E.R_Lit("STAMP"), 1, 5, fp)
    E.R_fwriteI1(42, fp)
    local pos = E.R_ftell(fp)
    E.R_fwriteD1(3.5, fp)
    E.R_fwriteF1(0.25, fp)
    E.Mem_fwrite_PtrT_ul_ul_CFile__I(E.NewPtrI_TA_l(arr(7, -8, 9), 0), 4, 3, fp)
    E.R_fseek_CFile_l_i(fp, pos, 0)
    E.R_fwriteD1(4.5, fp)
    E.R_rewind(fp)
    local stamp = E.R_BufOf(16, arr())
    local got = E.Mem_fread_CPtr_ul_ul_CFile(stamp, 1, 5, fp)
    local v = { 0, 0.0, 0.0 }
    local ok = got == 5 and E.R_strncmp(stamp, E.R_Lit("STAMP"), 5) == 0 and E.R_freadI1(v, 1, fp) == 1 and v[1] == 42 and
      E.R_freadD1(v, 2, fp) == 1 and v[2] == 4.5 and E.R_freadF1(v, 3, fp) == 1 and v[3] == 0.25
    check("binary round trip", ok, got, v[1], v[2], v[3])
    local ints = arr(0, 0, 0, 0)
    local k = E.Mem_fread_PtrT_ul_ul_CFile__I(E.NewPtrI_TA_l(ints, 0), 4, 4, fp)
    check("short fread", k == 3 and ints[0] == 7 and ints[1] == -8 and ints[2] == 9 and E.R_feof(fp) == 1, k, ints[0], ints[1], ints[2])
    check("fgetc at end", E.R_fgetc(fp) == -1)
    check("ftell at end", E.R_ftell(fp) == 5 + 4 + 8 + 4 + 12)
    check("fseek negative", E.R_fseek_CFile_l_i(fp, -1, 0) == -1)
    check("fseek end", E.R_fseek_CFile_l_i(fp, -4, 2) == 0 and E.R_ftell(fp) == 29 and E.R_feof(fp) == 0)
    local last = { 0 }
    check("fread after seek", E.R_freadI1(last, 1, fp) == 1 and last[1] == 9)
    check("fclose", E.R_fclose(fp) == 0)
    fp = E.R_fopen(name, E.R_Lit("r"))
    local line = E.R_Buf_i(8)
    check("fgets", not E.R_fgets(line, 4, fp):get_IsNull() and E.R_strcmp(line, E.R_Lit("STA")) == 0)
    local part = arr(0x11111111, 0x22222222)
    E.R_fseek_CFile_l_i(fp, -6, 2)
    local pk = E.Mem_fread_PtrT_ul_ul_CFile__I(E.NewPtrI_TA_l(part, 0), 4, 2, fp)
    check("fread partial element", pk == 1 and part[0] == 0x0009FFFF and part[1] == 0x22220000 and E.R_feof(fp) == 1, pk, part[0], part[1])
    E.R_fclose(fp)
    check("fopen missing", E.R_fopen(E.R_Lit(dr .. "/none"), E.R_Lit("r")) == nil)
    local dfp = E.R_fopen(E.R_Lit(dr), E.R_Lit("r"))
    local dline = E.R_Buf_i(8)
    check("fopen directory", dfp ~= nil and E.R_fgets(dline, 8, dfp):get_IsNull() and E.R_feof(dfp) == 0 and E.R_ferror(dfp) == 1 and
      E.R_fgetc(dfp) == -1 and E.R_feof(dfp) == 0 and E.R_fclose(dfp) == 0 and E.R_fopen(E.R_Lit(dr), E.R_Lit("r+")) == nil and
      E.R_fopen(E.R_Lit(dr), E.R_Lit("w")) == nil)
    local efp = E.R_fopen(name, E.R_Lit("r"))
    check("ferror of a file", E.R_ferror(efp) == 0)
    E.R_fclose(efp)
    check("fopen bad mode", E.R_fopen(name, E.R_Lit("x")) == nil)
    local an = E.R_Lit(dr .. "/a.txt")
    fp = E.R_fopen(an, E.R_Lit("w")); E.R_fprintf(fp, E.R_Lit("one\n")); E.R_fclose(fp)
    fp = E.R_fopen(an, E.R_Lit("a"))
    check("append position", E.R_ftell(fp) == 4)
    check("append no seek back", E.R_fseek_CFile_l_i(fp, 0, 0) == -1)
    E.R_fprintf(fp, E.R_Lit("two\n")); E.R_fclose(fp)
    check("append content", slurp(dr .. "/a.txt") == "one\ntwo\n")
    local h = assert(io.open(dr .. "/l.txt", "wb")); h:write("ab\ncdef\ng"); h:close()
    fp = E.R_fopen(E.R_Lit(dr .. "/l.txt"), E.R_Lit("r"))
    local lbuf = E.R_Buf_i(16)
    local gl = {}
    while not E.R_fgets(lbuf, 4, fp):get_IsNull() do gl[#gl + 1] = E.R_Str(lbuf) .. "|" .. E.R_feof(fp) end
    check("fgets lines", table.concat(gl, " ") == "ab\n|0 cde|0 f\n|0 g|1" and E.R_feof(fp) == 1, table.concat(gl, " "))
    E.R_fclose(fp)
    fp = E.R_fopen(E.R_Lit(dr .. "/t.txt"), E.R_Lit("w"))
    E.R_fprintf(fp, E.R_Lit("%-6s|%3d|%5.2f|%c|%zu|%s|%d|%ld|%lld|%.3f|%lu\n"), E.R_Lit("ab"), -5, 1.25, sbyte("Z"), E.U64(-1),
      E.NewStr_CPtr(E.R_Lit("str")), 7, E.I64(math.mininteger), E.U64(math.mininteger), 2, E.U64(-1))
    E.R_FlushAll(); E.R_fclose(fp)
    local txt = slurp(dr .. "/t.txt")
    check("fprintf argument kinds", txt == "ab    | -5| 1.25|Z|18446744073709551615|str|7|-9223372036854775808|-9223372036854775808|2.000|18446744073709551615\n", txt)
    check("fprintf null file", E.R_fprintf(nil, E.R_Lit("x")) == -1)
    local sb = E.R_Buf_i(8)
    check("snprintf truncation", E.R_snprintf_CPtr_ul_CPtr_oA(sb, 4, E.R_Lit("%d"), 123456) == 6 and E.R_strcmp(sb, E.R_Lit("123")) == 0)
    check("snprintf size 0", E.R_snprintf_CPtr_ul_CPtr_oA(sb, 0, E.R_Lit("%s"), E.R_Lit("abc")) == 3 and E.R_strcmp(sb, E.R_Lit("123")) == 0)
    check("remove", E.R_remove(an) == 0 and E.R_remove(an) == -1)
    check("File.Exists", E.File_Exists(E.NewStr_CPtr(E.R_Lit(dr .. "/t.txt"))) and not E.File_Exists(E.NewStr_CPtr(E.R_Lit(dr))) and
      not E.File_Exists(E.NewStr_CPtr(E.R_Lit(""))))
    local nb = E.R_Buf_i(64)
    E.R_snprintf_CPtr_ul_CPtr_oA(nb, 64, E.R_Lit("%f %+.2e %5.1f %G %a"), E.K_DNAN, INF, -INF, E.K_QNAN, -0.0)
    check("printf nan/inf", E.R_Str(nb) == "-nan +inf  -inf NAN -0x0p+0", E.R_Str(nb))
    for _, fnm in ipairs({ "t.bin", "a.txt", "l.txt", "t.txt" }) do os.remove(dr .. "/" .. fnm) end
    os.remove(dr)

    -- tuples, atomics, variants, once
    local t1, t2 = arr(1.0, 2.0), arr(1.0, 2.0)
    local ta = E.NewTupN_oA(1, 2.5, E.NewPtrD_TA_l(t1, 0), 1, 3)
    local tb = E.NewTupN_oA(1, 2.5, E.NewPtrD_TA_l(t1, 0), 1, 3)
    local tc = E.NewTupN_oA(1, 2.5, E.NewPtrD_TA_l(t2, 0), 1, 3)
    local td = E.NewTupN_oA(1, 2.5, E.NewPtrD_TA_l(t1, 0), 1, 4)
    check("tuple equal", ta:CompareTo(tb) == 0 and ta:Equals(tb))
    check("tuple identity", ta:CompareTo(tc) ~= 0 and ta:CompareTo(tc) == -tc:CompareTo(ta))
    check("tuple order", ta:CompareTo(td) < 0 and td:CompareTo(ta) > 0)
    local m = E.NewAtomicL()
    check("fetch_add", m:fetch_add(5, 0) == 0 and m:fetch_add(2, 0) == 5 and m.v == 7)
    local fat = E.NewAtomicD(); fat.v = 1.5
    local old = { 1.0 }
    local ok1 = fat:compare_exchange(old, 1, 3.0)
    local ok2 = fat:compare_exchange(old, 1, 3.0)
    check("compare_exchange", not ok1 and old[1] == 1.5 and ok2 and fat.v == 3.0)
    local ul = E.NewAtomicL_T(-1); ul:fetch_add(1, 0)
    check("atomic ulong wraps", ul.v == 0, ul.v)
    local vr = E.NewVariant()
    local vs = E.NewStr_CPtr(E.R_Lit("abc"))
    vr:Set_Str(vs)
    vs:append_i(sbyte("d"))
    local vw = vr:Clone()
    check("variant string", vr:index() == 3 and vr.v:ToString() == "abc" and vw.v ~= vr.v and vw.v:ToString() == "abc")
    vr:Set_d(2.5)
    check("variant double", vr:index() == 2 and vr.v == 2.5)
    local once = E.NewOnceFlag()
    local calls = 0
    E.Std_call_once(once, function() calls = calls + 1 end); E.Std_call_once(once, function() calls = calls + 1 end)
    check("call_once", calls == 1)
    local sw = { 1, 2 }
    E.Std_swap__I(sw, 1, sw, 2)
    check("swap", sw[1] == 2 and sw[2] == 1)
    local t0 = E.TimePoint_now()
    check("duration", E.TimePoint_op_Sub(E.TimePoint_now(), t0):count() >= 0)
    check("qnan", dbits(E.Std_QNaN) == 0x7FF8000000000000)   -- a constant in the Lua runtime
    check("nop", E.Std_Nop(3) == 0)
    local pr = E.NewPair_A_B(4, 0.5)
    check("get0/get1", E.Std_get0_PairAB__ID(pr) == 4 and E.Std_get1_PairAB__ID(pr) == 0.5)
    local thrown = not pcall(E.Std_Rethrow, E.NewSysException("IOException", "x"))
    check("Rethrow", thrown)
    local ec = E.NewErrorCode(); ec.v = 2
    check("error_code", ec:Bool())
    local nprocs = tonumber(os.getenv("NPROC") or "")          -- run_crtcheck.sh passes nproc's answer (lupa's Lua has no popen)
    check("hardware_concurrency", E.Sys_hardware_concurrency() == nprocs, E.Sys_hardware_concurrency(), nprocs)

    -- math corners
    check("CopySign NaN sign", E.Math_CopySign_d(1.0, E.K_DNAN) == -1.0)
    check("Truncate", E.Math_Truncate_d(-2.7) == -2.0 and dbits(E.Math_Truncate_d(-0.5)) == math.mininteger)
    check("Ceiling -0", dbits(E.Math_Ceiling_d(-0.5)) == math.mininteger and E.Math_Ceiling_d(0.2) == 1.0)
    check("Floor", dbits(E.Math_Floor_d(-0.0)) == math.mininteger and E.Math_Floor_d(-0.5) == -1.0 and E.Math_Floor_d(INF) == INF and
      E.Math_Floor_d(1e300) == 1e300)
    check("round", E.LibM_round(2.5) == 3.0 and E.LibM_round(-2.5) == -3.0 and E.LibM_round(0.49999999999999994) == 0.0 and
      dbits(E.LibM_round(-0.4)) == math.mininteger)
    check("pow errors", E.Math_Pow_d(0.0, -1.0) == INF and E.Math_Pow_d(-0.0, -3.0) == -INF and
      dbits(E.Math_Pow_d(-8.0, 1.0 / 3)) == dbits(frombits(0xFFF8000000000000)) and E.Math_Pow_d(10.0, 400.0) == INF and
      E.Math_Pow_d(-10.0, 401.0) == -INF)
    check("log errors", E.Math_Log_d(0.0) == -INF and isnan(E.Math_Log_d(-1.0)) and E.Math_Log10_d(-0.0) == -INF)
    check("exp overflow", E.L_math_exp(1000.0) == INF and E.Math_Cosh_d(1000.0) == INF and E.Math_Sinh_d(-1000.0) == -INF)
    check("sqrt", dbits(E.Math_Sqrt_d(-1.0)) == dbits(frombits(0xFFF8000000000000)) and E.Math_Sqrt_d(4.0) == 2.0 and
      dbits(E.Math_Sqrt_d(E.K_QNAN)) == 0x7FF8000000000000 and dbits(E.Math_Sqrt_d(-0.0)) == math.mininteger)
    check("Abs", dbits(E.Math_Abs_d(-0.0)) == 0 and dbits(E.Math_Abs_d(frombits(0xFFF8000000000001))) == 0x7FF8000000000001 and
      E.Math_Abs_d(-2.5) == 2.5)

    -- char arrays and strings
    local p = E.R_LitN("OPENSWMM_HS_V1", 16)
    check("LitN", p.B.n == 16 and p.B[14] == 0 and p.B[15] == 0)
    local q = E.R_CopyBuf(p); q.B[0] = sbyte("X")
    check("CopyBuf", p.B[0] == sbyte("O") and q.O == p.O)
    local dst = E.R_BufOf(6, arr(sbyte("a"), sbyte("b")))
    check("BufOf", Bvals(dst) == "97 98 0 0 0 0", Bvals(dst))
    check("bufs", E.R_Bufs(5, 24).n == 5 and E.R_Bufs(5, 24)[4].B.n == 24)
    local tp = E.NewPtrL_TA_l(arr(0), 0)
    local tt = E.R_time_Ptrl(tp)
    check("time", tt > 1700000000 and tp.a[0] == tt and E.R_difftime(tt + 3, tt) == 3.0)
    check("strcmp unsigned", E.R_strcmp(E.newcp(arr(0xE9, 0), 0), E.R_Lit("e")) > 0 and E.R_strcmp(E.R_Lit("ab"), E.R_Lit("abc")) == -sbyte("c") and
      E.R_strcmp(E.newcp(arr(97, 0), 0), E.R_Lit("a")) == 0)
    local hay = E.R_Lit("a,b,,c")
    check("strchr", E.CPtr_Diff(E.R_strchr(hay, sbyte(",")), hay) == 1 and E.CPtr_Diff(E.R_strchr(hay, 0), hay) == 6 and
      E.R_strchr(hay, sbyte("z")):get_IsNull())
    check("strrchr", E.CPtr_Diff(E.R_strrchr(hay, sbyte(",")), hay) == 4 and E.R_strrchr(hay, sbyte("z")):get_IsNull())
    check("strstr", E.CPtr_Diff(E.R_strstr(hay, E.R_Lit(",,")), hay) == 3 and E.R_strstr(hay, E.R_Lit("x")):get_IsNull() and
      E.CPtr_op_Eq(E.R_strstr(hay, E.R_Lit("")), hay))
    local toks = {}
    local tk = E.R_strtok(hay, E.R_Lit(","))
    while not tk:get_IsNull() do toks[#toks + 1] = E.R_Str(tk); tk = E.R_strtok(E.CPtr_ZERO, E.R_Lit(",")) end
    check("strtok", table.concat(toks, " ") == "a b c", table.concat(toks, " "))
    local nb2 = E.R_BufOf(6, arr(0x55, 0x55, 0x55, 0x55, 0x55, 0x55)); E.R_strncpy(nb2, E.R_Lit("ab"), 4)
    check("strncpy", Bvals(nb2) == "97 98 0 0 85 85", Bvals(nb2))
    check("toupper", E.R_toupper(sbyte("a")) == sbyte("A") and E.R_toupper(sbyte("{")) == sbyte("{"))
    check("atoi wrap", E.R_atoi(E.R_Lit("4294967297")) == 1 and E.R_atoi(E.R_Lit("99999999999999999999")) == -1)
    check("to_string(double)", E.Str_to_string_d(1.0 / 3):ToString() == "0.333333" and E.Str_to_string_d(-2.5e-7):ToString() == "-0.000000")
    io.write("units cases: ", un, ", failures: ", ubad, "\n")
  end

  if mode == "libm" then libm(math.tointeger(tonumber(narg)))
  elseif mode == "printf" then lines("printf", printf_case)
  elseif mode == "scanf" then lines("scanf", scanf_case)
  elseif mode == "misc" then lines("misc", misc_case)
  elseif mode == "units" then units()
  else error("crtcheck.lua: libm N | printf | scanf | misc | units") end
  E.R_FlushAll()
  return 0
end
