#!/bin/bash
# Write lua/rt/primes.lua, libstdc++'s __prime_list, from the C# runtime's cs/runtime/PrimeList.cs (which
# tests/stdcheck/primes.cpp extracted from the system libstdc++). A prime at or above 2^63 is written in hexadecimal,
# which Lua reads as the 64-bit integer with those bits (the unsigned value the hash tables compare with math.ult).
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and lua/README.md.
set -e
cd "$(dirname "$0")"
python3 - ../cs/runtime/PrimeList.cs > rt/primes.lua <<'PY'
import re, sys
nums = [int(x) for x in re.findall(r'(\d+)UL', open(sys.argv[1]).read())]
print("-- primes.lua - libstdc++'s std::__detail::__prime_list (C# Cpp.PrimeList.P, cs/runtime/PrimeList.cs, which")
print("-- tests/stdcheck/primes.cpp extracted from the system libstdc++): the bucket counts its hash tables take, ending")
print("-- with the largest 64-bit prime. Written by lua/make_primelist.sh from cs/runtime/PrimeList.cs; do not edit.")
print("-- Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.")
print("local _ENV = ...")
lits = [str(v) if v < 2**63 else '0x%016X' % v for v in nums]
print("PRIMES = { [0] = " + lits[0] + ",")
for i in range(1, len(lits), 8):
    print("  " + ", ".join(lits[i:i+8]) + ",")
print("  n = %d }" % len(lits))
PY
