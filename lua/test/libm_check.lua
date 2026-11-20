-- libm_check.lua VECTORS... - check the Lua port's math bit for bit against the system libm (glibc 2.39, the library the
-- C++ SWMM6 engine calls), each function called as the generated engine calls it: the runtime (lua/rt) is loaded into
-- an environment E as lua/runswmm6.lua loads it, and the engine's own names are called (L_exp is Lua's math.exp,
-- L_log Math_Log_d, L_pow Math_Pow_d, Math_Atan_d the translated atan, LibM_hypot the translated hypot, ...). The
-- translated routines are also checked directly where the runtime calls them only on some arguments (Glibm_pow,
-- which Math_Pow_d calls for the exponent 2, on every pow vector; Glibm_exp, which sinh and cosh call; and the fused
-- multiply-add emulation GlibmRT.fma on the fma vectors). Record format of tools/libm/test (name\0, n:u32, then n x
-- (args..., result) as raw doubles). A NaN must match in sign and payload.
-- Run: python3 lua/test/runlua.py lua/test/libm_check.lua VECTORS... (lua/test/run_libm_tests.sh makes the vectors)
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
return function(dir, ...)
  local paths = { ... }
  local E = { CWD = "/" }
  for _, n in ipairs({ "core", "strvec", "primes", "containers", "glibm_rt", "glibm", "crt", "io" }) do
    assert(loadfile(dir .. "/rt/" .. n .. ".lua", "t"))(E)
  end
  E.inherit_all()            -- as the end of gen/engine.lua does: copy inherited methods down the runtime's classes
  local RT = E.GlibmRT
  local F = {
    exp = { 1, { { "L_exp (math.exp)", E.L_math_exp }, { "Glibm_exp", E.Glibm_exp } } },
    log = { 1, { { "L_log (Math_Log_d)", E.Math_Log_d } } },
    log10 = { 1, { { "Math_Log10_d", E.Math_Log10_d } } },
    pow = { 2, { { "L_pow (Math_Pow_d)", E.Math_Pow_d }, { "Glibm_pow", E.Glibm_pow } } },
    sin = { 1, { { "L_sin (math.sin)", E.L_math_sin } } },
    cos = { 1, { { "L_cos (math.cos)", E.L_math_cos } } },
    tan = { 1, { { "Math_Tan_d", E.Math_Tan_d } } },
    asin = { 1, { { "Math_Asin_d", E.Math_Asin_d } } },
    acos = { 1, { { "Math_Acos_d", E.Math_Acos_d } } },
    atan = { 1, { { "Math_Atan_d", E.Math_Atan_d } } },
    fma = { 3, { { "GlibmRT.fma", RT.fma } } },
    cbrt = { 1, { { "Math_Cbrt_d", E.Math_Cbrt_d } } },
    hypot = { 2, { { "LibM_hypot", E.LibM_hypot } } },
    atan2 = { 2, { { "Math_Atan2_d", E.Math_Atan2_d } } },
    cosh = { 1, { { "Math_Cosh_d", E.Math_Cosh_d } } },
    sinh = { 1, { { "Math_Sinh_d", E.Math_Sinh_d } } },
    tanh = { 1, { { "Math_Tanh_d", E.Math_Tanh_d } } },
    log2 = { 1, { { "Math_Log2_d", E.Math_Log2_d } } },
    expm1 = { 1, { { "LibM_expm1", E.LibM_expm1 } } },
    log1p = { 1, { { "LibM_log1p", E.LibM_log1p } } },
    frexp = { 2, { { "GlibmRT.frexp", function(x) return RT.frexp(x) end },
      { "GlibmRT.frexpExp", function(x) return RT.frexpExp(x) + 0.0 end, 3 } }, 1 },
    ldexp = { 2, { { "GlibmRT.ldexp", function(x, e) return RT.ldexp(x, E.f2i32(e)) end } } },
    sqrt = { 1, { { "L_sqrt (math.sqrt)", E.L_math_sqrt }, { "Math_Sqrt_d", E.Math_Sqrt_d } } },
    floor = { 1, { { "L_floor (Math_Floor_d)", E.Math_Floor_d } } },
    ceil = { 1, { { "L_ceil (Math_Ceiling_d)", E.Math_Ceiling_d } } },
    trunc = { 1, { { "Math_Truncate_d", E.Math_Truncate_d } } },
    fabs = { 1, { { "L_abs (math.abs)", E.L_math_abs }, { "Math_Abs_d", E.Math_Abs_d } } },
    round = { 1, { { "LibM_round", E.LibM_round } } },
    copysign = { 2, { { "Math_CopySign_d", E.Math_CopySign_d } } },
    fmod = { 2, { { "LibM_fmod", E.LibM_fmod }, { "L_fmod (math.fmod)", E.L_math_fmod } } },
    remainder = { 2, { { "LibM_remainder", E.LibM_remainder } } },
    nextafter = { 2, { { "LibM_nextafter", E.LibM_nextafter } } },
    pow_y2 = { 2, { { "L_pow (Math_Pow_d)", E.Math_Pow_d } } },
  }
  local spack, sunpack = string.pack, string.unpack
  local function bits(x) return (sunpack("<i8", spack("<d", x))) end
  local clock = os.clock
  local total, bad_all = 0, 0
  for _, path in ipairs(paths) do
    print("== " .. path:gsub(".*/", ""))
    local f = assert(io.open(path, "rb"))
    while true do
      local name = {}
      while true do
        local c = f:read(1)
        if c == nil or c == "\0" then break end
        name[#name + 1] = c
      end
      if #name == 0 then break end
      name = table.concat(name)
      local n = sunpack("<I4", f:read(4))
      local spec = F[name]
      if not spec then error("unknown function " .. name) end
      local na, fns, nres = spec[1], spec[2], spec[3]
      -- frexp's records are (x, mantissa, exponent): one argument; the mantissa and the exponent checked separately
      local args = nres and 1 or na
      local rec = na + 1
      local CH = 65536
      local results = {}
      for k = 1, #fns do results[k] = { 0, 0, 0, 0, 0.0 } end
      local left = n
      while left > 0 do
        local m = left < CH and left or CH
        local buf = f:read(m * rec * 8)
        local vals = { sunpack("<" .. string.rep("d", m * rec), buf) }
        for k, fe in ipairs(fns) do
          local g, r = fe[2], results[k]
          local t0 = clock()
          for i = 0, m - 1 do
            local b = i * rec
            local want = vals[b + (fe[3] or args + 1)]
            local got
            if args == 1 then got = g(vals[b + 1])
            elseif args == 2 then got = g(vals[b + 1], vals[b + 2])
            else got = g(vals[b + 1], vals[b + 2], vals[b + 3]) end
            local gb, wb = bits(got), bits(want)
            if gb ~= wb then
              if got ~= got and want ~= want then
                if (gb < 0) ~= (wb < 0) then r[2] = r[2] + 1 else r[3] = r[3] + 1 end
              else
                r[1] = r[1] + 1
              end
              if r[4] < 4 then
                r[4] = r[4] + 1
                local a = {}
                for j = 1, args do a[j] = string.format("%016x", bits(vals[b + j])) end
                print(string.format("  %s(%s) = %016x, libm %016x", fe[1], table.concat(a, ", "), gb, wb))
              end
            end
          end
          r[5] = r[5] + (clock() - t0)
        end
        left = left - m
      end
      for k, fe in ipairs(fns) do
        local r = results[k]
        print(string.format("%-9s %-24s %d of %d differ, %d NaN sign, %d NaN payload   (%.3f us/call)",
          name, fe[1], r[1], n, r[2], r[3], r[5] * 1e6 / n))
        total = total + n
        bad_all = bad_all + r[1] + r[2] + r[3]
      end
    end
    f:close()
  end
  print("records checked: " .. total)
  print("total mismatches: " .. bad_all)
  return bad_all == 0 and 0 or 1
end
