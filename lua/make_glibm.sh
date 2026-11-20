#!/bin/bash
# make_glibm.sh GLIBC_SRC [WORKDIR] - regenerate the Lua port's translation of glibc 2.39's math (lua/rt/glibm.lua) and
# copy its runtime (tools/libm/glibm_rt.lua -> lua/rt/glibm_rt.lua):
#   1. tools/libm/build_glibm.sh   compile glibc's sysdeps/ieee754/dbl-64 routines as glibc's x86-64 build compiles the
#                                  variants it selects on a processor with FMA and AVX2, and dump GCC's optimized
#                                  GIMPLE (the objects are only compiled, never run)
#   2. tools/libm/extract_tables.py copy the constant tables out of the object files (objdump/objcopy)
#   3. tools/libm/gim2lua.py       translate the GIMPLE of exp, pow, atan (set 1) and expm1, sinh, cosh, tanh, log1p,
#                                  cbrt, hypot (set 2) into Lua
# GLIBC_SRC is a checkout of glibc 2.39 (the one used: release/2.39/master at ce65d944e38a); WORKDIR (default
# /dev/shm/lua6_glibm, about 0.7 MB) holds the objects and dumps and is deleted at the end unless given.
# Then run lua/test/run_libm_tests.sh. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see README.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
GL=$(readlink -f "$1"); W=${2:-/dev/shm/lua6_glibm}; KEEP=${2:+1}
mkdir -p "$W"
"$ROOT/tools/libm/build_glibm.sh" "$GL" "$W"
python3 "$ROOT/tools/libm/extract_tables.py" "$W" "$W/tables.json"
G=$W/gimple
python3 "$ROOT/tools/libm/gim2lua.py" "$HERE/rt/glibm.lua" \
    $G/e_exp.c.254t.optimized $G/e_pow.c.254t.optimized $G/s_atan.c.254t.optimized $G/s_expm1.c.254t.optimized \
    $G/e_sinh.c.254t.optimized $G/e_cosh.c.254t.optimized $G/s_tanh.c.254t.optimized $G/s_log1p.c.254t.optimized \
    $G/s_cbrt.c.254t.optimized $G/e_hypot.c.254t.optimized --tables "$W/tables.json" \
    --name my_exp_fma=exp --name my_pow=pow --name my_atan=atan --name my_expm1=expm1_t --name my_sinh=sinh_t \
    --name my_cosh=cosh_t --name my_tanh=tanh_t --name my_log1p=log1p_t --name my_cbrt=cbrt_t --name my_hypot=hypot_t \
    --header "exp, pow and atan from glibc's FMA variants (e_exp.c, e_pow.c, s_atan.c with -mfma -mavx2); expm1, sinh, tanh" \
    --header "and log1p from the FMA variants of set 2; cosh, cbrt and hypot generic (tools/libm/README.md). The engine calls" \
    --header "the public Glibm_* functions at the end through lua/rt/crt.lua (Math_Pow_d for the exponent 2, Math_Atan_d, ...)." \
    --header "Derived from the GNU C Library (glibc) 2.39 and so, like glibc's libm, licensed under the GNU Lesser General" \
    --header "Public License, version 2.1 or later (LGPL-2.1-or-later)." \
    --header "Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md."
cp "$ROOT/tools/libm/glibm_rt.lua" "$HERE/rt/glibm_rt.lua"
[ -n "$KEEP" ] || rm -rf "$W"
echo "wrote lua/rt/glibm.lua and lua/rt/glibm_rt.lua"
