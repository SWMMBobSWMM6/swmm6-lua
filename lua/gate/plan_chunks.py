# plan_chunks.py corpus|extra - cut the Lua gate into chunks: each model's time estimated from the Python port's gate
# times (gate/evidence/py2.json, else py1.json times 0.47, the median py2/py1 ratio of the models both passed; py_x2.json
# for the extra decks) times RATIO, the Lua/Python ratio measured on 40 corpus decks (0.79; lua/results/lua_vs_py.txt),
# times SAFETY for the load of the shared machine, plus a second for the start; a model the Python gate did not pass
# (it stopped at its time limit) is estimated from the TypeScript port's time (ts2.json, ts_x3.json) times 4.24 (the
# median Python/TypeScript ratio, perl/gate/plan_chunks.py). Estimates are capped at the 1800 s limit. Models estimated
# at SLOW s or more go into chunks of their own; the rest are packed into chunks of at most BUDGET s (about an hour, so
# that a chunk and its wait for the lock fit inside the two-hour limit of a background command, and a restart costs
# little). Writes ids_<prefix>NN.txt and prints each chunk's estimate. After perl/gate/plan_chunks.py.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
import json, os, sys
H = os.path.dirname(os.path.abspath(__file__)); E = os.path.join(H, '..', '..', 'gate', 'evidence')
RATIO, SAFETY, START, CAP, SLOW, BUDGET, PY21 = 0.79, 1.15, 1.0, 1800.0, 1200.0, 3300.0, 0.47
kind = sys.argv[1]                      # corpus or extra
def load(n): return {r['id']: r for r in json.load(open(os.path.join(E, n + '.json')))}
if kind == 'corpus':
    py = load('py2'); py1 = load('py1'); ts = load('ts2'); prefix = 'c'
else:
    py = load('py_x2'); py1 = {}; ts = load('ts_x3'); prefix = 'x'
def ok(r): return r is not None and r['status'] == 'PASS'
est = {}
for mid, t in ts.items():
    if ok(py.get(mid)):
        base = py[mid]['sec']
    elif ok(py1.get(mid)):
        base = py1[mid]['sec'] * PY21
    else:
        base = t['sec'] * 4.24
    est[mid] = min(CAP, base * RATIO * SAFETY + START)
slow = sorted([m for m in est if est[m] >= SLOW], key=lambda m: -est[m])
rest = sorted([m for m in est if est[m] < SLOW], key=lambda m: -est[m])
chunks = [[m] for m in slow]
bins = []
for m in rest:                          # first fit, largest first
    for b in bins:
        if sum(est[x] for x in b) + est[m] <= BUDGET:
            b.append(m); break
    else:
        bins.append([m])
chunks = bins + chunks
for k, c in enumerate(chunks, 1):
    open(os.path.join(H, 'ids_%s%02d.txt' % (prefix, k)), 'w').write(''.join(m + '\n' for m in sorted(c)))
    print('%s%02d %3d models  est %5.0f s' % (prefix, k, len(c), sum(est[m] for m in c)))
print('total %d models, est %.2f h' % (len(est), sum(est.values()) / 3600))
