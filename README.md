# swmm6-lua: the OpenSWMM 6 1D engine in Lua, byte for byte

A translation of the 1D engine of OpenSWMM 6 (HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6)
into Lua, held to the same output as the C++ engine: the same binary `.out` file and the same `.rpt`
report, apart from the three clock lines. It is not SWMM6 and not a HydroCouple or EPA release; it is a
translation checked against SWMM6.

## Result

**478 of 480 models byte-identical** (the other 2 did not finish within the time limit, `Hydrology/SCANLON.inp` after 1800 s, `EPA/72_H&H_Elements(2).inp` after 1800 s; untested, not failed) against the C++ reference engine built from the same commit and run on one thread
(`OMP_NUM_THREADS=1`), on the 480-model gate set (the one the SWMM5 ports were checked on), drawn from
[1729-SWMM5-Models-2030](https://github.com/SWMMBobSWMM6/1729-SWMM5-Models-2030). Gate runs
`lua6_c01`, `lua6_c02`, `lua6_c03`, `lua6_c04`, `lua6_c05`, `lua6_c05r`, `lua6_c06`, `lua6_c07`, `lua6_c08`; every result, with the SHA-256 of each `.out` and `.rpt`, is in `gate/evidence/`.

The same engine on the 452 extra decks: **450 of 452 extra decks byte-identical** (2 did not finish within the time limit: `legacy_small.inp`, `refactored_small.inp`; untested, not failed). These are SWMM6's own tests, which the corpus cannot be:
the input files in the upstream repository's `tests` folder at 88329d6, and the synthetic decks of
[swmm6-rust](https://github.com/SWMMBobSWMM6/swmm6-rust)'s gate, which probe the finite-volume solver, its
structure coupling, the newer hydrology and the input checks. Gate runs
`lua6_x01`, `lua6_x02`, `lua6_x03`, `lua6_x04`, in `gate/evidence/` with the same hashes.

Checked twice more. An independent rerun of a sample (the first gates took more than five hours of engine time, 6.78): 100 corpus models drawn at random (seed 20261110) from the 478 that passed, the three decks that SAVE and USE `cho.txt`, and 40 extra decks drawn the same way from the 450, from a clean copy of the repository (`git archive`), with
the translator rebuilt there, the engine (`lua/gen/engine.lua`, `literals.txt` and the translator's three reports), `lua/rt/primes.lua` and the translated math (`lua/rt/glibm.lua` and `glibm_rt.lua`, from glibc's source compiled to GIMPLE only) regenerated there, all byte-identical to the committed files (`lua/results/lua6_v_build.txt`); every status, exit code and `.out` and `.rpt` hash equal to the first runs' (`lua/results/lua6_v_compare.txt`): gate runs
`lua6_v_a`, `lua6_v_b`, `lua6_vx`, **142 of 142 byte-identical**. Then the main session's own check, from a
clean `git clone`: the translator rebuilt, and the engine, `primes.lua` and the translated math regenerated (identical again); and gate runs `lua6_main` on 45 corpus models drawn at random (seed 20261110) plus the three decks that
SAVE and USE `cho.txt` (**48 of 48 byte-identical**) and `lua6_main_x` on 12 extra decks drawn the same way
(**12 of 12 byte-identical**). The math's own tests are in `lua/results/libm_tests.txt`.

The gates ran a snapshot of commit eeeb633; the engine, runtime and launcher files published here are unchanged since. The four models that did not finish were stopped at the 1800 s limit set for this port. For each, the part of the `.out` written when it was stopped is the reference's, byte for byte (`lua/results/*_stopped.txt`): `Hydrology/SCANLON.inp` 71,299,346 of 78,975,850 bytes (90.3%), `EPA/72_H&H_Elements(2).inp` 2,351 of 440,275 (0.5%, the header), `legacy_small.inp` 27,760,953 of 155,158,965 (17.9%) and `refactored_small.inp` 28,596,369 of 155,158,965 (18.4%). They count as not run.

The corpus runs were interrupted three times, each recorded in the run's times file (`lua/gate/NAME_times.txt`): a container restart during `lua6_c04`, which was run again from the start; a stop by hand of `lua6_c05` 28 s in, to give it a full two-hour window; and the out-of-memory killer of the memory cgroup the agents share, which stopped `lua6_c05` after 119 models when another port's compiler filled it (`lessons/76`), after which it was resumed. The same kill stopped one model's engine, `OWA_EXTRAN/extran3_RTC_Rule.inp`, which was run again on its own as `lua6_c05r`: PASS, and it counts by that rerun.

**The checked run.** Lua has no unchecked mode to compare with. Every run, the gates and the rerun included, runs under a guard in `lua/runswmm6.lua` that raises an error on any read of an undeclared global and on any new global made after the engine has loaded, so a misspelt name cannot pass as `nil`. No run tripped it. `lua/test/strict_probe.sh` shows that the guard works (`lua/results/strict_probe.txt`).

A model passes when its `.out` is byte-identical to the reference's (when the reference writes one), its `.rpt` is
identical after removing the lines "Analysis begun", "Analysis ended" and "Total elapsed time", and its exit code is
the same (the command line exits nonzero when a model stops on an input error).

The translations, all from the same C# and gated the same way: swmm6-csharp, swmm6-go, swmm6-java, swmm6-typescript, swmm6-fortran, swmm6-python, swmm6-kotlin, swmm6-groovy, swmm6-javascript, swmm6-fsharp, swmm6-hy, swmm6-ruby, swmm6-php, swmm6-perl, swmm6-zig, swmm6-pascal, swmm6-mojo, swmm6-lua, under
[SWMMBobSWMM6](https://github.com/SWMMBobSWMM6).

## How it was made

The C++ engine was translated to C# first, and the C# gated to 480 of 480. The other languages are translated
from that C#, not from the C++. `tools/cs2x/Cs2Lua.cs` translates the verified C# engine (`cs/gen`) through Roslyn into one Lua 5.4 file (`lua/gen/engine.lua`; the mapping is in `tools/cs2x/LUA.md`). C# classes become tables with metatables, exceptions Lua `error` and `pcall`, and C#'s integers Lua 5.4's 64-bit integers, which wrap as C#'s unchecked arithmetic does. There is no stand-alone Lua interpreter on the machine it was made on: `lua/runswmm6.py` starts a Lua state in lupa and calls the engine. `lua/rt` is the runtime library, written in Lua for this port. Lua's `x ^ 2` is `x * x`, not `pow`, `math.atan(x)` is `atan2(x, 1)`, lupa's Lua binds glibc's oldest math symbols, and Lua has no sinh, cosh, tanh, expm1, log1p, cbrt or hypot, so those of glibc 2.39's routines are translated into Lua from the GIMPLE GCC makes of glibc's source (`tools/libm/gim2lua.py`, run by `lua/make_glibm.sh`; no binary built from glibc's source is run). Nothing in `lua/` loads anything from the other ports.

Nothing in the generated engine is edited by hand. Where the output depends on the C library (printf's rounding,
strtod, sscanf, the order of a hash table's nodes, introsort's swaps), the runtime reproduces glibc and libstdc++
exactly; the checks in `tests/` compare it with them case by case.

## Build and run

Needs Python 3 with lupa 2.8 (`pip install lupa==2.8`, which embeds Lua 5.4.8), on glibc x86-64; the .NET 8 SDK only to regenerate the engine, and gcc 13 with a glibc 2.39 source tree only to regenerate the translated math. No build step. Then run a model the way the C++ command line runs it:

    lua/runswmm6 model.inp model.rpt model.out

To regenerate the engine: tools/cs2x/build_lua.sh, then dotnet tools/cs2x/bin/cs2lua.dll cs lua/gen, then lua/make_primelist.sh, then lua/make_glibm.sh GLIBC_SRC (a glibc 2.39 checkout, compiled to GIMPLE only; nothing built from it is run). The C# engine it starts from is regenerated from the C++ source with
`tools/cpp2x` (see the header of `tools/cpp2x/emit_cs.py` and `cs/README.md`), which needs the OpenSWMM source at
commit 88329d6 and libclang.

## The gate

`gate/make_ref.sh` makes the reference outputs with the C++ engine (`ref/runswmm6`: build openswmm.engine at
88329d6 and run it single-threaded); `gate/gate.py NAME "lua/runswmm6" --resume` runs this engine on every model in
`gate/models_all.tsv` (paths relative to the corpus; set `SWMM_CORPUS`) and compares; `gate/cmp1.sh` checks one
model. The extra decks are listed in `gate/models_extra.tsv`, with paths relative to a folder that holds clones of
openswmm.engine (at 88329d6) and swmm6-rust: make their references with
`SWMM_CORPUS=FOLDER MODELS=gate/models_extra.tsv REF=$PWD/gate/ref_outputs_extra gate/make_ref.sh`, then run
`gate/gate.py NAME "lua/runswmm6" --models gate/models_extra.tsv --ref gate/ref_outputs_extra --root FOLDER --resume`.
The median time per model in the gate runs was 1.68 s (the C# engine's: 0.76 s, which includes .NET's start-up and JIT compilation). The times were measured on a shared two-core cloud machine while other runs were going, so they are a
rough guide, not a benchmark.

## What this does not show

- Agreement on models outside the 480 and the 452. The two sets are broad (EPA's examples, the OWA EXTRAN set,
  hydrology, hydraulics, water quality, LID, RDII, controls, hot start, input errors, the FV solver and SWMM6's own
  tests), but a feature no gate model or deck uses is untested.
- The reference's parallel runs. Every parallel loop runs on one thread, in order, which is what the C++ engine
  does when it is held to one thread; results with OpenMP threads can differ in the last bits.
- The 2D and other modules of OpenSWMM 6 beyond the 1D engine the command line runs.
- Every input to the math functions. Lua calls the C library for most of them, and the runtime gives the current glibc symbol versions' results where lupa's Lua binds older ones (`lessons/71`); atan, sinh, cosh, tanh, cbrt, expm1, log1p, hypot and pow with the exponent 2 (Lua computes `x ^ 2` as `x * x`) are glibc 2.39's own routines translated into Lua. The tests cover tens of millions of arguments (`lua/results/libm_tests.txt`), not all of them; that is a test, not a proof.

## License and attribution

This repository is a translation of the OpenSWMM 6 engine.

OpenSWMM Engine — Copyright 2026 HydroCouple Developers, licensed under the Apache License, Version 2.0. See
[LICENSE](LICENSE) and [NOTICE](NOTICE). Source: https://github.com/HydroCouple/openswmm.engine (branch
`swmm6_rel`, commit `88329d6`).

Every generated engine file here is a modified, mechanically translated form of the OpenSWMM sources: its header
names what it was generated from, and each C# file in `cs/gen` names the OpenSWMM source file it came from.

Portions derive from the USEPA Storm Water Management Model, which is in the public domain under 17 USC § 105. The
USEPA does not endorse this product, and neither does HydroCouple.

The translators, the runtime, the gate and the notes: Copyright 2026 Robert Dickinson, licensed under the Apache
License, Version 2.0.

The math routines `lua/rt/glibm.lua` and `lua/rt/glibm_rt.lua` (and their generator's sources in `tools/libm/`) are translations of glibc 2.39 code and remain under glibc's licence, the GNU Lesser General Public License 2.1 or later (`LICENSES/LGPL-2.1.txt`).

## AI use

Made with Claude (Anthropic): the translators, the runtime, the gate and the notes are Claude's work, directed by
Robert Dickinson; the engine itself is OpenSWMM's, translated mechanically. See [AI-USE.md](AI-USE.md).
