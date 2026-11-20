# compare_rerun.py RERUN_PREFIX FIRST_PREFIX... - for every model of the rerun runs (lua/results/RERUN_PREFIX*.json), its
# status, exit code and .rpt / .out hashes (gate.py's: the .rpt without its clock lines) against the same model's last
# result in the first gate runs (lua/results/FIRST_PREFIX*.json). Prints one line per difference and a count.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
import glob, json, os, sys
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'results')
def load(prefixes):
    out = {}
    for p in prefixes:
        for f in sorted(glob.glob(os.path.join(R, p + '*.json'))):
            for r in json.load(open(f)):
                out[r['id']] = r
    return out
rerun, first = load([sys.argv[1]]), load(sys.argv[2:])
bad = 0
for i, r in sorted(rerun.items()):
    f = first.get(i)
    keys = ('status', 'rc', 'rpt_sha256', 'out_sha256')
    if f is None or any(r[k] != f[k] for k in keys):
        bad += 1
        print('DIFFERENT', i, r['path'], {k: (f or {}).get(k) for k in keys}, {k: r[k] for k in keys})
print('%s*: %d models, %d with the first run\'s status, exit code, .rpt hash and .out hash, %d different'
      % (sys.argv[1], len(rerun), len(rerun) - bad, bad))
