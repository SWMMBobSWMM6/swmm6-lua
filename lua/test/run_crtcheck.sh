#!/bin/bash
# run_crtcheck.sh [N] - compare the Lua runtime's C library (lua/rt: crt.lua, io.lua, core.lua) with the system's glibc,
# as perl/test/run_crtcheck.sh does for the Perl runtime: libm results bit for bit (N cases per function plus a grid of
# special values; tests/crtcheck/libm.c), printf output (printf.c, and pycheck/specs.c for every conversion spec the
# engine's format strings use), sscanf results (scanf.c), from_chars / strtol / strtod / atoi / ctime / ctype /
# get_nprocs (misc.cpp), and unit checks of the rest (crtcheck.lua units). The C and C++ programs use only the
# system's own libc, libm and libstdc++; they are built in W (default /dev/shm/lua6_crtcheck), deleted at the end.
# Set TZ to test ctime in another time zone.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); C=$ROOT/tests/crtcheck
W=${W:-/dev/shm/lua6_crtcheck}; rm -rf "$W"; mkdir -p "$W"
for p in libm printf scanf; do gcc -O2 -ffp-contract=off -fno-builtin -o "$W/$p" "$C/$p.c" -lm; done
gcc -O2 -o "$W/specs" "$C/pycheck/specs.c"
g++ -O2 -std=c++20 -o "$W/misc" "$C/misc.cpp"
R="python3 $HERE/runlua.py $HERE/crtcheck.lua"
N=${1:-300000}
"$W/libm" "$N" | $R libm "$N"
"$W/printf" | $R printf
"$W/specs" | $R printf
"$W/scanf" | $R scanf
"$W/misc" | $R misc
NPROC=$(nproc) TMPDIR="$W" $R units
rm -rf "$W"
