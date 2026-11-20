# The OpenSWMM 6 1D engine in Lua, byte for byte

A translation of the 1D engine of OpenSWMM 6 (HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6) into
Lua 5.4, held to the same output as the C++ engine: the same binary `.out` file and the same `.rpt` report, apart from
the three clock lines. It is not SWMM6 and not a HydroCouple or EPA release; it is a translation checked against
SWMM6.

## Result

**478 of 480 models byte-identical** against the C++ reference engine built from the same commit and run on one
thread, on the 480-model gate set the SWMM5 ports were checked on, drawn from 1729-SWMM5-Models-2030. **Two models were
not run: they timed out after 1800 s**, the time limit set for this port. They are not passes. For each, the part of the
`.out` written when it was stopped is the reference's, byte for byte (`results/NAME_stopped.txt`):

| model | run | `.out` written when stopped | Python port |
|---|---|---|---|
| `Hydrology/SCANLON.inp` | `lua6_c07` | 71,299,346 of 78,975,850 bytes (90.3%) | 4,056 s |
| `EPA/72_H&H_Elements(2).inp` | `lua6_c08` | 2,351 of 440,275 (0.5%; the header) | stopped at 7,000 s |

The Python port's times (`gate/evidence/py2.json`) show these are the corpus's two slowest models. Gate runs `lua6_c01`
to `lua6_c06` (478 of 478) and the single-model runs `lua6_c07` and `lua6_c08`; 4.86 hours of engine time in all, a
median of 1.7 s per model that passed, the slowest model that passed `Hydrology/17_Sub_90_Link_USA_Units.inp` (753 s).
Three things happened on the way, all recorded in the runs' times files (`gate/NAME_times.txt`): the container restarted
during `lua6_c04`, which was then run again from the start (21 of 21; the 11 results of the stopped run, all passes, are
kept in `gate/lua6_c04_partial_before_restart.jsonl`); `lua6_c05` was stopped by hand 28 s in, to give it a full
two-hour window, and later killed after 119 models by the out-of-memory killer of the memory cgroup all agents on the
machine share, when another port's compiler filled it (lesson 76), then resumed (`gate.py --resume`); and the same
killer took the engine of one model of that run, `OWA_EXTRAN/extran3_RTC_Rule.inp` (CRASH, rc 137, after 0.85 s), which
was run again on its own as `lua6_c05r`: PASS. The model counts by that rerun. After all the runs `Hydrology/cho.txt`,
which `save_rtk_long.inp` SAVEs and two other decks USE, is 1,114,474 bytes, md5 5b0ca1fe78588202fa779dbfa417b089.

**450 of 452 extra decks byte-identical**: SWMM6's own tests (the input files in the upstream repository's `tests`
folder at 88329d6) and the synthetic decks of swmm6-rust's gate. **Two decks were not run: they timed out after
1800 s**, `legacy_small.inp` (run `lua6_x03`) and `refactored_small.inp` (`lua6_x04`); they had written 27,760,953 and
28,596,369 of their 155,158,965-byte `.out` files (17.9% and 18.4%), every byte the reference's. The Python port was
stopped on both at 7,000 s. Gate runs `lua6_x01` (6 of 6) and `lua6_x02` (444 of 444) and the single-deck runs
`lua6_x03` and `lua6_x04`; 1.92 hours of engine time in all, a median of 0.43 s per deck that passed, the slowest deck
that passed `sdm_fv_o2_superbee.inp` (552 s). `lua6_x03` was first queued behind another port's gate and its command
stopped seconds after it had been given the lock, with its deck a few seconds in (no result was recorded); it was
queued again and run from the start (`gate/lua6_x03_times.txt`).

In all, 6.78 hours of engine time for the 932 models and decks (4.86 and 1.92), and 7.39 hours inside the shared lock
(5.46 and 1.93, the runs stopped and run again or resumed included; `gate/summarize.py`).

**The independent rerun: 142 of 142.** A clean copy of commit 3b8e3ea (`git archive`) in memory, where the translator
was rebuilt, the engine regenerated from `cs/gen` (`engine.lua`, `literals.txt` and the translator's three reports
byte-identical to the committed ones) and the generated runtime files written again (`rt/primes.lua` by
`make_primelist.sh`, and `rt/glibm.lua` and `rt/glibm_rt.lua` by `make_glibm.sh` from glibc's source: all
byte-identical; `results/lua6_v_build.txt`); its runtime, engine and launchers are byte-identical to the snapshot of
eeeb633 that the gate ran. That copy was gated as it was, on a sample, because the first gates took more than five
hours of engine time (6.78): 100 corpus models drawn from the 478 that passed with
`random.Random(20261110).sample(sorted(passed), 100)` plus the three decks that SAVE and USE `Hydrology/cho.txt`
(`save_rtk_long.inp` was drawn; `one_sub_one_rdii_node.inp` and `Use_SeasonalRDIIn.inp` were added), 102 models in runs
`lua6_v_a` (50 of 50) and `lua6_v_b` (52 of 52); and 40 extra decks drawn the same way from the 450, run `lua6_vx`
(40 of 40); 1.04 hours in all (`gate/sample_rerun.py`, `gate/ids_v_*.txt`, `gate/ids_vx.txt`). Every status, exit
code, `.rpt` hash and `.out` hash equals the first run's (`gate/compare_rerun.py`, `results/lua6_v_compare.txt`).

**The main session's check: 48 of 48 and 12 of 12.** A clean `git clone` of commit e6119c5 (in memory), where the
translator was rebuilt and the engine, `rt/primes.lua` and the translated math (`rt/glibm.lua`, `rt/glibm_rt.lua`, by
`make_glibm.sh` from glibc 2.39's source compiled to GIMPLE only) regenerated (no file changed: `git status` empty),
then gated with that clone's engine: run `lua6_main` on 45 corpus models drawn at random (`random.Random(20261110)`)
plus `Hydrology/save_rtk_long.inp`, `one_sub_one_rdii_node.inp` and `Use_SeasonalRDIIn.inp`, the decks that SAVE and
USE `cho.txt` (48 of 48; 1,391 s), and run `lua6_main_x` on 12 extra decks drawn the same way (12 of 12; 10 s); the
same samples as the other ports' checks. Ids in `gate/ids_main_check.txt` and `gate/ids_main_check_extra.txt`.
After all the runs `Hydrology/cho.txt` is 1,114,474 bytes, md5 5b0ca1fe78588202fa779dbfa417b089.

## How it was made

The C++ engine was translated to C# first (`cs/gen`, 480 of 480), and this engine is translated from that C#, not
from the C++, by a translator written for it: `tools/cs2x/Cs2Lua.cs`, `LuaTypes.cs` and `LuaFn.cs` (4,226 lines),
which read the C# (`cs/gen`, and the engine's hand-written partial classes `cs/runtime/Hand_*.cs`) through Roslyn's
semantic model and print one Lua file, `gen/engine.lua` (168,101 lines). The translator began as a copy of the Perl
back end (`Cs2Pl.cs`, itself begun from the Ruby and Python ones), so the analysis and the runtime names are those
ports'. Lua keeps integers and doubles as two subtypes of one number type and does not mix them up, but it has no
32-bit integer, no unsigned integer and no `ref`: C# `int` arithmetic is wrapped to 32 bits where it is stored, a
`ulong` is the same 64 bits compared with `math.ult`, an integer converted to double is made a float wherever it goes,
and a reference is a table and a key passed as two values. Lua also limits a function to 200 locals and forbids a
`goto` into the scope of a local (lesson 73), which the translator works around. The mapping is in
`tools/cs2x/LUA.md`; how often each translation choice was made is in `cs2lua_stats.txt`, every runtime name the engine
uses in `cs2lua_runtime.txt` (608), and the constructs left untranslated in `cs2lua_todo.txt` (none).

The runtime (`rt/`, 4,516 lines in `core.lua`, `strvec.lua`, `containers.lua`, `crt.lua` and `io.lua`) is the part of
the C++ standard library and of the C library that the engine calls: vectors, maps and sets with libstdc++'s hash-table
node order, bucket counts and growth (the bucket counts, `rt/primes.lua`, written by `make_primelist.sh`), strings,
iterators, pointers, introsort and merge sort step for step, glibc's printf (each conversion through Lua's
`string.format`, which calls the C library's, with the widths and precisions it refuses and glibc's quirks written
out), strtod (Lua's `tonumber`, which is the C library's, with the end of the number, ERANGE and the exact underflow
test written out), glibc's sscanf, stdio files, iostreams and the file system as the C# port has them. It is written
in Lua for this port. `runswmm6.lua` is the command line (`src/cli/main.cpp`, by way of the C# port's `Program.cs` and
the Perl port's `runswmm6.pl`); `runswmm6.py` (19 lines) only starts a Lua state in lupa and calls it, and `runswmm6`
is the shell wrapper. Nothing calls another port's engine, runtime or math.

The math is glibc's. Lua's `math.exp`, `sin`, `cos`, `tan`, `asin`, `acos`, `sqrt`, `log`, `fmod`, two-argument
`atan` and `^` call the C library, but lupa's Lua refers to them without symbol versions and so gets glibc's oldest
ones, the SVID wrappers, for log, log2 and fmod (lesson 71); the runtime gives the current versions' results where
the wrappers differ. Lua's `x ^ 2` is `x * x`, not `pow`, and `math.atan(x)` is `atan2(x, 1)` (SWMM5 lesson 40), and
Lua has no `sinh`, `cosh`, `tanh`, `expm1`, `log1p`, `cbrt` or `hypot`: these are glibc 2.39's own routines
translated into Lua (`rt/glibm.lua`, 2,029 lines, with its runtime `rt/glibm_rt.lua`, 298 lines: bit casts, x86's
conversions and an exact fused multiply-add). They are translated from the GIMPLE GCC makes of glibc's source compiled
as glibc compiles the variants it runs on an x86-64 processor with FMA and AVX2, by `tools/libm/gim2lua.py` (the SWMM5
Lua port's back end, extended for the routines the SWMM6 ports added), run by `make_glibm.sh`; no binary built from
glibc's source is run. `floor`, `ceil`, `trunc`, `round`, `fabs`, `copysign`, `remainder` and `nextafter`, whose
results IEEE fixes, are computed by the runtime.

Nothing in the generated engine is edited by hand: every fix went into the translator or the runtime.

## How it was checked

- **The math**: `test/run_libm_tests.sh` compares the functions as the engine calls them with the system's glibc 2.39,
  bit for bit, by the method of `tools/libm/test`: a million arguments per function over the ranges SWMM uses with
  special values, and 200,000 to 700,000 edge cases each, for exp, log, log10, pow, sin, cos, tan, asin, acos and atan
  (and the translated exp and pow on every exp and pow vector, and the fused multiply-add on a million cases); a million
  per function over wide ranges and every branch threshold, with signed zeros, infinities, subnormals and NaNs of both
  signs with several payloads, for cbrt, hypot, atan2, cosh, sinh, tanh, log2, expm1, log1p, frexp and ldexp; a million
  each for sqrt, floor, ceil, trunc, fabs, round and copysign; and a million plus every pair of 34 special values for
  fmod, remainder and nextafter, and a million for pow(x, 2) (`test/mkextra.c`). 43,370,324 results, **0 differences**,
  NaN signs and payloads included (`results/libm_tests.txt`).
- **The C library**: `test/run_crtcheck.sh` runs the cases of `tests/crtcheck` (C programs using the system's own glibc)
  through the runtime (`test/crtcheck.lua`, after `perl/test/crtcheck.pl`): libm through the runtime, 0 differences in
  300,576 cases for each of 27 functions; printf, 0 differences in 179,756 cases and in 101,800 more covering every
  conversion the engine's format strings use; sscanf, 0 in 1,728; from_chars, strtol, strtod, atoi, ctime, ctype and
  get_nprocs, 0 in 752; and 90 unit checks of the rest (files, raw memory, atomics, variants, strings), 0 failures
  (`results/crtcheck.txt`).
- **libstdc++**: `test/run_std_checks.sh` runs the cases of `tests/stdcheck`: the permutations std::sort,
  std::stable_sort and std::partial_sort leave on keys with many ties (6,447 cases, through the generic sort and the
  double, int and long specialisations) and the hash tables' iteration order, bucket counts and std::hash (167 lines),
  identical to libstdc++; the streams (2,963 lines of formatting, extraction and files, and 1 of seeking), identical to
  libstdc++ (`results/std_checks.txt`).
- **The literals**: every double literal of the engine (2,002) read back by Lua's parser has the C# double's bits and is
  a float (`test/literals_check.lua`, in `results/std_checks.txt`).
- **The strict-globals run**: every run of this engine, the gate runs and the independent rerun included, is made under
  a strict-globals guard (`runswmm6.lua`): once the runtime is loaded, the shared environment's metatable raises an
  error on any read of a global that the runtime or the engine never defined (or declared, for the static fields that
  start as nil), and once the engine is loaded, on any assignment to a new global; `LUA6_STRICT=0` turns it off. So the
  gate results above are the checked build's results: no run read an undefined global (a read would have stopped it with
  status 134 and the guard's message, which no run gave). `test/strict_probe.sh` shows the guard working in the snapshot
  the gate ran: a line appended to a copy of the engine that reads an undeclared global stops the run with status 134
  and "read of undeclared global"; with the guard off the same copy runs the deck to the reference's `.out`; and an
  engine function that assigns a new global after loading stops it with "assignment to undeclared global"
  (`results/strict_probe.txt`). During development the guard found two runtime bugs, assignments that went to a local of
  the same name instead of the global (`ult`, and the `math` library used after `_ENV` was replaced).
- **The engine**: the gate (above), run on the corpus and on the extra decks, and the independent rerun.

## Build and run

Needs Python 3 (3.13.18 was used) with lupa 2.8 (`pip install lupa`), whose `lupa.lua54` module embeds Lua 5.4.8, and
glibc on x86-64. There is no build step. Run a model the way the C++ command line runs it:

    lua/runswmm6 model.inp model.rpt model.out

Memory: the engine runs in one Lua state with Lua's generational garbage collector
(`collectgarbage("generational")`, set by `runswmm6.lua`); arrays are Lua tables (16 bytes an element), strings and byte
buffers Lua strings and tables, and the `.out` and `.rpt` files are written through the C library's buffered streams as
the engine goes, never held in memory. Sampled every 5 s during the gate runs from `lua6_c02` on (and by hand during
`lua6_c01`), the engine process's resident memory stayed under 500 MB: at most 482 MB, on the `Hydrology/rtk_long*.inp`
decks (a long rainfall record), 169 MB on `221_H&H_SI_Units_Elements.inp`, and a median of 42 MB over the 277 decks that
ran long enough to be sampled; well inside the 2 GB a run was allowed.

The translator needs the .NET 8 SDK (8.0.132 was used). To regenerate the engine from `cs/gen`:
`tools/cs2x/build_lua.sh && dotnet tools/cs2x/bin/cs2lua.dll cs lua/gen` (about 30 seconds); `lua/make_primelist.sh`
writes `rt/primes.lua` again, and `lua/make_glibm.sh GLIBC_SRC` writes `rt/glibm.lua` and copies `rt/glibm_rt.lua`
(needs gcc and a glibc 2.39 source tree; the one used was `release/2.39/master` at ce65d944e38a). The checks:
`lua/test/run_libm_tests.sh`, `run_crtcheck.sh` and `run_std_checks.sh` (gcc and g++).

The gate: `lua/gate/run_chunk.sh NAME corpus|extra [IDS_FILE] [ENGINE]` runs `gate/gate.py` on this port with the
SAVE-file wrapper (`runswmm6_saves.sh`), inside the shared lock (`WAIT` seconds at most); `gate/snapshot.sh [COMMIT]`
makes the fixed copy a chunk runs; `gate/plan_chunks.py` cut the runs; `gate/rerun_build.sh` makes the clean copy of a
commit that the independent rerun gates, `gate/sample_rerun.py` draws its sample and `gate/compare_rerun.py` compares
its results with the first run's; `gate/summarize.py` lists the runs; `gate/stopped.py` records how far a model stopped
at the time limit had got.

## What this does not show

- Four results, two corpus models and two extra decks: they were stopped at the 1800 s limit and are not results; the
  bytes they had written are evidence of how far they got, not a result.
- Agreement on models outside the 480 and the 452. A feature no gate model or deck uses is untested.
- The reference's parallel runs: every parallel loop runs on one thread, in order, as the C++ engine does when it
  is held to one thread.
- The 2D and other modules of OpenSWMM 6 beyond the 1D engine the command line runs.
- Every input to the math functions: the tests check the calls into the C library and the translated routines on tens
  of millions of arguments, not all of them; another glibc would give that glibc's results for the functions called
  in the C library, while the translated ones stay glibc 2.39's FMA variants on any machine.
- Section b of the stream checks (the C# port's own stream and file-system behaviour) and the core-helper checks of
  `tests/pycheck`: they were not ported to Lua; that part of the runtime is exercised only through the engine.
- Speed. Lua runs this engine at about 0.8 times the Python port's time, half the Ruby port's and twice the C# port's
  on 40 short decks (`results/lua_vs_py.txt`); the times above were measured on a shared two-core machine.

## License and attribution

The engine is a translation of the OpenSWMM Engine, Copyright 2026 HydroCouple Developers, licensed under the
Apache License, Version 2.0 (https://github.com/HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6).
Portions derive from the USEPA Storm Water Management Model, which is in the public domain; the USEPA does not
endorse this translation, and neither does HydroCouple. `rt/glibm.lua`, `rt/glibm_rt.lua` and `tools/libm/gim2lua.py`'s
output are derived from the GNU C Library (glibc) 2.39 and are, like glibc's libm, under the GNU Lesser General Public
License 2.1 or later; the rest of the math is the system's glibc, called at run time and not copied.

## AI use

The translator (`tools/cs2x/Cs2Lua.cs`, `LuaTypes.cs`, `LuaFn.cs`), the runtime (`lua/rt`), the math translator
(`tools/libm/gim2lua.py`), the port's scripts and checks and these notes were written by Claude, Anthropic's AI model,
for Robert Dickinson, who directed the work. The engine is a mechanical translation of OpenSWMM 6 (Apache-2.0,
HydroCouple Developers), itself derived in part from the public-domain EPA SWMM; it was checked by running it against
the C++ engine, not by reading it. glibc-derived math is LGPL-2.1-or-later. This is a translation checked against
SWMM6, not SWMM6, and not a HydroCouple or EPA release. See `../AI-USE.md`.
