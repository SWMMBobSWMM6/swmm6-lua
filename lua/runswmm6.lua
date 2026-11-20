-- runswmm6.lua - the OpenSWMM 6 command line (src/cli/main.cpp, by way of the C# port's Program.cs and the Perl
-- port's runswmm6.pl) over the Lua engine: lua/runswmm6 model.inp report.rpt [output.out]
-- Builds the environment every runtime file and the engine share (E), loads the runtime (rt/*.lua), glibc's translated
-- math (rt/glibm_rt.lua, rt/glibm.lua) and the generated engine (gen/engine.lua) into it, then makes the C API calls
-- main.cpp makes, in its order, with its messages and its exit code. An exception that escapes the engine ends the
-- process with status 134, as the C++ (SIGABRT) and .NET do.
-- The strict-globals guard: once the runtime is loaded, reading a global the runtime or the engine never defined (or
-- declared, for one that starts as nil) raises an error instead of giving nil, and after the engine is loaded so does
-- defining a new one. LUA6_STRICT=0 turns the guard off (it costs nothing on a name that exists).
-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and README.md.
return function(dir, cwd, ...)
  collectgarbage("generational")
  local argv = { ... }
  local E = {}
  E.CWD = cwd
  local function load_into(path, mode)
    local f = assert(loadfile(path, mode or "t"))
    f(E)
  end
  for _, n in ipairs({ "core", "strvec", "primes", "containers", "glibm_rt", "glibm", "crt", "io" }) do
    load_into(dir .. "/rt/" .. n .. ".lua")
  end
  local strict = os.getenv("LUA6_STRICT") ~= "0"
  local defining = true
  local DECLARED = E.DECLARED
  if strict then
    setmetatable(E, {
      __index = function(_, k)
        if DECLARED[k] then return nil end
        error("strict globals: read of undeclared global '" .. tostring(k) .. "'", 2)
      end,
      __newindex = function(t, k, v)
        if defining or DECLARED[k] then rawset(t, k, v); return end
        error("strict globals: assignment to undeclared global '" .. tostring(k) .. "'", 2)
      end })
  end
  local VERSION = "6.0.0-alpha.4"
  local stdout = E.R_stdout_
  local function out(s) stdout:write(s) end
  local function lit(s) return E.R_Lit(s) end
  local function run()
    if #argv < 1 then out("\nError: not enough arguments. Use --help for usage.\n\n"); return 1 end
    if argv[1] == "--version" or argv[1] == "-v" then out("openswmm.engine " .. VERSION .. "\n"); return 0 end
    if #argv < 2 then
      out("\nError: need at least input and report file paths.\n")
      out("Usage: openswmm <input.inp> <report.rpt> [output.out]\n\n")
      return 1
    end
    local inp, rpt = argv[1], argv[2]
    local outf = #argv > 2 and argv[3] or ""
    load_into(dir .. "/gen/engine.lua")
    defining = false
    local API = E
    local function err_msg(engine) return E.cbs(API.F__global_swmm_get_last_error_msg(engine)) end
    out("\n... OpenSWMM Engine " .. VERSION .. "\n... Input: " .. inp .. "\n... Report: " .. rpt .. "\n... Output: " .. outf .. "\n")
    E.R_fflush(stdout)
    local t0 = os.time()
    local engine = API.F__global_swmm_engine_create()
    if engine == nil then out("Error: failed to create engine instance.\n"); return 1 end
    local err = API.F__global_swmm_engine_open(engine, lit(inp), lit(rpt), lit(outf), E.CPtr_ZERO)
    if err ~= 0 then out("Error opening input file: " .. err_msg(engine) .. "\n"); API.F__global_swmm_engine_destroy(engine); return err end
    err = API.F__global_swmm_engine_initialize(engine)
    if err ~= 0 then
      out("Error initializing: " .. err_msg(engine) .. "\n")
      API.F__global_swmm_engine_close(engine); API.F__global_swmm_engine_destroy(engine)
      return err
    end
    err = API.F__global_swmm_engine_start(engine, outf == "" and 0 or 1)
    if err ~= 0 then
      out("Error starting simulation: " .. err_msg(engine) .. "\n")
      API.F__global_swmm_engine_close(engine); API.F__global_swmm_engine_destroy(engine)
      return err
    end
    local elapsed = { [0] = 0.0, n = 1 }
    local ptr = E.NewPtrD_TA_l(elapsed, 0)
    local steps = 0
    while true do
      err = API.F__global_swmm_engine_step(engine, ptr)
      if err ~= 0 then out("\nError at step " .. steps .. ": " .. err_msg(engine) .. "\n"); break end
      if elapsed[0] <= 0.0 then break end
      steps = steps + 1
    end
    out("\n... " .. steps .. " steps completed.\n")
    local result = err
    local function fin(status, phase)
      if status ~= 0 then
        out("Error " .. phase .. ": " .. err_msg(engine) .. "\n")
        if result == 0 then result = status end
      end
    end
    fin(API.F__global_swmm_engine_end(engine), "ending simulation")
    fin(API.F__global_swmm_engine_report(engine), "writing report")
    fin(API.F__global_swmm_engine_close(engine), "closing simulation")
    API.F__global_swmm_engine_destroy(engine)
    out(string.format("... OpenSWMM Engine %s in %.2f seconds.\n\n", result == 0 and "completed" or "failed", os.time() - t0 + 0.0))
    return result
  end
  local ok, rc = xpcall(run, function(e)
    if os.getenv("SWMM6_LUA_TRACE") then io.stderr:write(debug.traceback(tostring(type(e) == "table" and (e.ToString and e:ToString() or e.kind) or e), 2), "\n") end
    return e
  end)
  if not ok then
    local e = rc
    local m
    if type(e) == "table" and e.Message then m = (e.kind or (getmetatable(e) and getmetatable(e).__name) or "Exception") .. ": " .. tostring(e:Message())
    else m = tostring(e) end
    pcall(E.R_FlushAll)
    io.stdout:flush()
    io.stderr:write("Unhandled exception. " .. m .. "\n")
    return 134
  end
  E.R_FlushAll()
  io.stdout:flush()
  return rc
end
