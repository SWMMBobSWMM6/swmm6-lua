#!/bin/bash
# rerun_build.sh [COMMIT] [DIR] [GLIBC_SRC] - the first half of the independent rerun: a clean copy of COMMIT (default
# HEAD) of this repository (git archive) in DIR (default /dev/shm/lua6_v), where the translator is rebuilt, the engine is
# regenerated from cs/gen and compared byte for byte with the committed lua/gen/engine.lua (and literals.txt and the
# translator's three reports with the committed lua/cs2lua_*.txt), the generated runtime files are written again and
# compared (lua/rt/primes.lua by lua/make_primelist.sh; lua/rt/glibm.lua and lua/rt/glibm_rt.lua by lua/make_glibm.sh
# from GLIBC_SRC, default /home/claude/ext/glibc, glibc 2.39), and the engine is loaded over the runtime. Lua needs no
# build step: the gate then runs that copy as it is:
#   lua/gate/run_chunk.sh lua6_v corpus lua/gate/ids_v.txt DIR/lua/runswmm6_saves.sh   (and lua6_vx, extra)
# After perl/gate/rerun_build.sh. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
K=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$K/.." && pwd)
C=${1:-HEAD}; R=${2:-/dev/shm/lua6_v}; GL=${3:-/home/claude/ext/glibc}
rm -rf "$R"; mkdir -p "$R"
git -C "$ROOT" archive "$C" | tar -x -C "$R"
echo "== clean copy of $(git -C "$ROOT" rev-parse --short "$C") in $R"
cd "$R"
echo "== the translator: tools/cs2x/build_lua.sh"
nice -n 10 tools/cs2x/build_lua.sh 2>&1 | grep -v 'warning CS' || true
echo "== the engine, regenerated from cs/gen into $R/regen and compared with lua/gen/engine.lua and lua/cs2lua_*.txt"
mkdir -p "$R/regen/gen"
nice -n 10 dotnet tools/cs2x/bin/cs2lua.dll cs "$R/regen/gen"
for f in gen/engine.lua gen/literals.txt cs2lua_runtime.txt cs2lua_todo.txt cs2lua_stats.txt; do
	if cmp -s "$R/regen/$f" "lua/$f"; then echo "lua/$f: $(wc -l < "lua/$f") lines, byte-identical to the commit"; else echo "lua/$f: DIFFERENT"; exit 1; fi
done
echo "== the generated runtime files, written again by lua/make_primelist.sh and lua/make_glibm.sh"
mkdir -p "$R/committed"
cp lua/rt/primes.lua lua/rt/glibm.lua lua/rt/glibm_rt.lua "$R/committed/"
lua/make_primelist.sh
nice -n 10 lua/make_glibm.sh "$GL" "$R/glibm_work" > "$R/glibm_build.txt" 2>&1 || { tail -5 "$R/glibm_build.txt"; exit 1; }
for f in primes.lua glibm.lua glibm_rt.lua; do
	if cmp -s "$R/committed/$f" "lua/rt/$f"; then echo "lua/rt/$f: $(wc -l < "lua/rt/$f") lines, byte-identical to the commit"; else echo "lua/rt/$f: DIFFERENT"; exit 1; fi
done
rm -rf "$R/regen" "$R/committed" "$R/glibm_work" "$R/glibm_build.txt"
echo "== the engine loads over the runtime (a missing input file: the engine is loaded, then the open fails)"
(cd "$R" && lua/runswmm6 "$R/no-such-model.inp" "$R/no-such.rpt" | grep -m1 'Error opening input file' && rm -f "$R/no-such.rpt")
python3 -c 'import lupa; from lupa import lua54; print("lupa", lupa.__version__ + ",", lua54.LuaRuntime().lua_implementation)'
