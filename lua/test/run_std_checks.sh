#!/bin/bash
# run_std_checks.sh - the Lua runtime's libstdc++ behaviour against libstdc++ itself and the C# runtime, on the cases of
# tests/stdcheck (as perl/test/run_std_checks.sh does for the Perl runtime):
#   sort    sortcheck.lua (modes O, D, I, L) against sortcheck.cpp: the permutations std::sort, std::stable_sort and
#           std::partial_sort leave on keys with many ties
#   hash    hashcheck.lua against hashcheck.cpp: unordered_map / unordered_set bucket counts and iteration order after
#           inserts, operator[], erases, reserve and copies, and std::hash of strings
#   streams streamcheck.lua against the outputs tests/stdcheck/run_stream.sh left in tests/stdcheck/build (C++ and C#):
#           section a (formatting, extraction, files) must equal C++ or C# (they differ on one glibc %#g line),
#           section c C++ and C#; section b (the C# port's own stream and file-system behaviour) is not ported.
# The C++ programs use only the system's libstdc++. Everything is built in W (default /dev/shm/lua6_stdcheck) and
# deleted at the end; tests/ is only read. And literals_check.lua: every double literal of the generated engine read
# back by Lua's parser.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); S=$ROOT/tests/stdcheck
W=${W:-/dev/shm/lua6_stdcheck}; rm -rf "$W"; mkdir -p "$W/stdcheck/build"
R="python3 $HERE/runlua.py"
fail=0
same() { if cmp -s "$1" "$2"; then echo "  $3: identical"; else echo "  $3: DIFFERENT"; diff "$1" "$2" | head -6 | cut -c1-300; fail=1; fi; }
g++ -O2 -std=c++20 -o "$W/sortcheck" "$S/sortcheck.cpp"
g++ -O2 -std=c++20 -o "$W/hashcheck" "$S/hashcheck.cpp"
"$W/sortcheck" > "$W/sort_cpp.txt"; "$W/hashcheck" > "$W/hash_cpp.txt"
echo "sort cases: $(wc -l < "$W/sort_cpp.txt")"
for m in O D I L; do $R "$HERE/sortcheck.lua" $m > "$W/sort_lua_$m.txt"; same "$W/sort_cpp.txt" "$W/sort_lua_$m.txt" "sort, stable_sort, partial_sort ($m), libstdc++ and Lua"; done
$R "$HERE/hashcheck.lua" > "$W/hash_lua.txt"
echo "hash lines: $(wc -l < "$W/hash_cpp.txt")"
same "$W/hash_cpp.txt" "$W/hash_lua.txt" "unordered_map / unordered_set order and std::hash, libstdc++ and Lua"
B=$S/build
(cd "$W/stdcheck" && for s in a c; do env -u TMPDIR PWD="$W/stdcheck" $R "$HERE/streamcheck.lua" $s > "$W/stream_lua_$s.txt"; done)
echo "streams section a: $(wc -l < "$W/stream_lua_a.txt") lines"
if cmp -s "$B/stream_cpp_a.txt" "$W/stream_lua_a.txt"; then echo "  C++ and Lua: identical"
elif cmp -s "$B/stream_cs_a.txt" "$W/stream_lua_a.txt"; then echo "  C# and Lua: identical"
else echo "  Lua equals neither C++ nor C#"; diff "$B/stream_cpp_a.txt" "$W/stream_lua_a.txt" | head -8; fail=1; fi
echo "streams section c: $(cat "$W/stream_lua_c.txt")"
same "$B/stream_cpp_c.txt" "$W/stream_lua_c.txt" "C++ and Lua"
same "$B/stream_cs_c.txt" "$W/stream_lua_c.txt" "C# and Lua"
$R "$HERE/literals_check.lua" || fail=1
rm -rf "$W"
exit $fail
