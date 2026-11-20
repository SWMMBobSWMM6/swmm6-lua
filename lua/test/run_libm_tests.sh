#!/bin/bash
# run_libm_tests.sh [N] [N2] - check the Lua port's math bit for bit against the system libm (glibc 2.39, the library the
# C++ SWMM6 engine calls), by the method of tools/libm/test/run_tests.sh, with the vector generators the Perl and Ruby
# ports use (tools/libm/test/mkvectors.c, mkedge.c, mkvectors2.c, ruby/test/mkexact.c) and lua/test/mkextra.c (fmod,
# remainder, nextafter, pow(x, 2)), all built against the system libm: set 1 (exp, log, log10, pow, sin, cos, tan, asin,
# acos, atan, and the fma emulation), set 2 (cbrt, hypot, atan2, cosh, sinh, tanh, log2, expm1, log1p, frexp, ldexp), the
# exact operations (sqrt, floor, ceil, trunc, fabs, round, copysign) and the extras, each called as the generated engine
# calls it (libm_check.lua). Vectors go to W (default /dev/shm/lua6_libm_test), deleted at the end.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
N=${1:-1000000}; N2=${2:-1000000}; W=${W:-/dev/shm/lua6_libm_test}; rm -rf "$W"; mkdir -p "$W"
T=$ROOT/tools/libm/test
gcc -O2 -o "$W/mkvectors" "$T/mkvectors.c" -lm
gcc -O2 -o "$W/mkedge" "$T/mkedge.c" -lm
gcc -O2 -fno-builtin -o "$W/mkvectors2" "$T/mkvectors2.c" -lm
gcc -O2 -fno-builtin -o "$W/mkexact" "$ROOT/ruby/test/mkexact.c" -lm
gcc -O2 -fno-builtin -o "$W/mkextra" "$HERE/mkextra.c" -lm
"$W/mkvectors" "$N" "$W/vectors.bin" > /dev/null 2>&1
"$W/mkedge" 100000 "$W/edge.bin" > /dev/null 2>&1
"$W/mkvectors2" "$N2" "$W/vectors2.bin" > /dev/null 2>&1
"$W/mkexact" "$N" "$W/exact.bin" > /dev/null 2>&1
"$W/mkextra" "$N" "$W/extra.bin" > /dev/null 2>&1
python3 -c 'import lupa; from lupa import lua54; print("lupa", lupa.__version__ + ",", lua54.LuaRuntime().lua_implementation)'
set +e
python3 "$HERE/runlua.py" "$HERE/libm_check.lua" "$W/vectors.bin" "$W/edge.bin" "$W/vectors2.bin" "$W/exact.bin" "$W/extra.bin"
rc=$?
rm -rf "$W"
exit $rc
