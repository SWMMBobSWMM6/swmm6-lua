#!/bin/bash
# snapshot.sh [COMMIT] - export lua/ (the runtime, the engine and the launchers) as committed at COMMIT (default HEAD) (git
# archive: uncommitted edits are left out) to /dev/shm/lua6_eng/<commit>/lua and print the SAVE-file wrapper's path
# there, the ENGINE a gate chunk runs. The gate then runs a fixed commit, and work on the tree while a chunk is queued or
# running cannot change what it runs (SWMM5 lessons/41). After perl/gate/snapshot.sh.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
C=$(git -C "$ROOT" rev-parse --short=7 "${1:-HEAD}")
D=/dev/shm/lua6_eng/$C
if [ ! -f "$D/lua/runswmm6_saves.sh" ]; then
	rm -rf "$D"; mkdir -p "$D"
	git -C "$ROOT" archive "$C" lua/rt lua/gen/engine.lua lua/runswmm6 lua/runswmm6.lua lua/runswmm6.py lua/runswmm6_saves.sh | tar -x -C "$D"
fi
echo "$D/lua/runswmm6_saves.sh"
