# sample_rerun.py - the models of the Lua port's independent rerun, which is a sample, not the full set (the corpus
# gate took more than five hours of engine time): from the corpus models that passed in the lua6_c* runs,
# 100 drawn with random.Random(20261110).sample(sorted(passed), 100), plus the three decks that SAVE and USE Hydrology/cho.txt
# (save_rtk_long.inp, one_sub_one_rdii_node.inp, Use_SeasonalRDIIn.inp; not repeated if drawn); from the extra decks
# that passed in the lua6_x* runs, 40 drawn the same way. Writes ids_v.txt and ids_vx.txt.
# Copied from perl/gate/sample_rerun.py. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.
import glob, json, os, random
H = os.path.dirname(os.path.abspath(__file__)); R = os.path.join(H, '..', 'results')
CHO = ['55393df61d0a', '1cd1b5e4fa0f', '8c2e17c489af']


def passed(*patterns):
    out = {}
    for f in [f for p in patterns for f in sorted(glob.glob(os.path.join(R, p)))]:
        for r in json.load(open(f)):
            out[r['id']] = r['status']
    return sorted(i for i, s in out.items() if s == 'PASS'), len(out)


pc, nc = passed('lua6_c*.json')
px, nx = passed('lua6_x*.json')
v = random.Random(20261110).sample(pc, 100)
v += [i for i in CHO if i not in v]
vx = random.Random(20261110).sample(px, 40)
open(os.path.join(H, 'ids_v.txt'), 'w').write(''.join(i + '\n' for i in v))
open(os.path.join(H, 'ids_vx.txt'), 'w').write(''.join(i + '\n' for i in vx))
print('corpus: %d results, %d passed; drew 100, with the cho.txt decks %d models (ids_v.txt)' % (nc, len(pc), len(v)))
print('extra: %d results, %d passed; drew 40 (ids_vx.txt)' % (nx, len(px)))
# The 102 corpus models were then cut into two runs of about equal time (ids_v_a.txt, ids_v_b.txt: largest first into
# the lighter, by the first gate's times), each well inside the two-hour limit of a background command.
