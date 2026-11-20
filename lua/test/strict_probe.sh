#!/bin/bash
# strict_probe.sh [LUADIR] - show that the strict-globals guard of lua/runswmm6.lua is on in an ordinary run (as in every
# gate run): a copy of LUADIR (default this lua/ folder: rt, gen, the launchers) in W (default /dev/shm/lua6_strict) gets one
# line appended to its gen/engine.lua that reads a global nobody defined, and runs a small corpus deck. With the guard
# (the default) the run must stop with the guard's message and status 134; with LUA6_STRICT=0 the read gives nil and the
# run must finish as the reference does. Then a line that defines a new global from inside an engine function after
# the engine is loaded (the guard's other half) must stop the run too. W is deleted at the end.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); L=${1:-$(cd "$HERE/.." && pwd)}; ROOT=$(cd "$HERE/../.." && pwd)
W=${W:-/dev/shm/lua6_strict}; rm -rf "$W"; mkdir -p "$W/lua/gen" "$W/run"
cp -r "$L/rt" "$W/lua/"; cp "$L/runswmm6" "$L/runswmm6.lua" "$L/runswmm6.py" "$W/lua/"
DECK=$ROOT/../swmmbobswmm6/1729-swmm5-models-2030/OWA_EXTRAN/very_simple_cfs_flow_import_ICM_SWMM.inp
cp "$DECK" "$W/run/m.inp"
fail=0
run() { (cd "$W/run" && rm -f r.rpt r.out && env "$@" "$W/lua/runswmm6" m.inp r.rpt r.out > out.txt 2> err.txt; echo $? > rc.txt); }
# 1: a read of an undeclared global while the engine loads
cp "$L/gen/engine.lua" "$W/lua/gen/engine.lua"
printf '\nlocal strict_probe = THIS_GLOBAL_IS_NOT_DECLARED\n' >> "$W/lua/gen/engine.lua"
run LUA6_STRICT=1
echo "read, guard on:  status $(cat "$W/run/rc.txt"), $(grep -o "strict globals: [^']*'[A-Z_]*'" "$W/run/err.txt" | head -1)"
[ "$(cat "$W/run/rc.txt")" = 134 ] && grep -q "read of undeclared global 'THIS_GLOBAL_IS_NOT_DECLARED'" "$W/run/err.txt" || fail=1
run LUA6_STRICT=0
REF=$ROOT/gate/ref_outputs/3340b657fffa
echo "read, guard off: status $(cat "$W/run/rc.txt") (reference $(cat "$REF/rc")), report $(wc -c < "$W/run/r.rpt") bytes, .out $(cmp -s "$W/run/r.out" "$REF/r.out" && echo identical || echo DIFFERENT) to the reference's"
[ "$(cat "$W/run/rc.txt")" = "$(cat "$REF/rc")" ] && cmp -s "$W/run/r.out" "$REF/r.out" || fail=1
# 2: an assignment to a new global after the engine is loaded (from the report writer's first call of an engine function)
cp "$L/gen/engine.lua" "$W/lua/gen/engine.lua"
printf '\nlocal strict_probe_f = F__global_swmm_engine_create\nfunction F__global_swmm_engine_create(...) NEW_GLOBAL_AFTER_LOAD = 1; return strict_probe_f(...) end\n' >> "$W/lua/gen/engine.lua"
run LUA6_STRICT=1
echo "write, guard on: status $(cat "$W/run/rc.txt"), $(grep -o "strict globals: [^']*'[A-Z_]*'" "$W/run/err.txt" | head -1)"
[ "$(cat "$W/run/rc.txt")" = 134 ] && grep -q "assignment to undeclared global 'NEW_GLOBAL_AFTER_LOAD'" "$W/run/err.txt" || fail=1
rm -rf "$W"
echo "exit $fail"
exit $fail
