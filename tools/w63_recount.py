#!/usr/bin/env python3
"""Window 6.3: what a run of the frozen configuration would have counted with the rule for another group
switched off (Configuration.holdsBackOtherGroups = false, the app's default since the sealed evaluation).

  tools/w63_recount.py <set> <frozen 6.3 json> <6.2 json>

A sentence the rule held back ("another_group") went no further in the frozen run. Without the rule it goes on
to the second look, which for such a sentence is the same request as in Window 6.2, so its decision is taken
from the Window 6.2 run on the same sentences. Every other decision is the frozen run's. This is a recount of
runs that were made, not a new measurement; on a sealed set that has been run it is not independent evidence.
Counts only; no sentence text is printed.
"""
import json, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
name, new, old = sys.argv[1:4]
exp = {}
for l in open(os.path.join(ROOT, f'packages/HearingSenseKit/Sources/SemanticEvaluation/Resources/semantic_{name}.txt')):
    if not l.strip() or l[0] in '#@': continue
    f = [x.strip() for x in l.split('|')]; exp[f[0]] = (f[3], f[2])
a = {x['id']: x for x in json.load(open(new))['outcomes']['model']}
b = {x['id']: x for x in json.load(open(old))['outcomes']['model']}
def count(decide):
    tp = fp = fn = tn = 0; cats = {}
    for i, x in a.items():
        e, cat = exp[i]; al = decide(i, x)
        if e == 'relevant': tp += al; fn += (not al)
        elif e in ('irrelevant', 'repeat'): fp += al; tn += (not al)
        if e != 'ambiguous':
            ok = al if e == 'relevant' else not al
            c = cats.setdefault(cat, [0, 0]); c[0] += ok; c[1] += 1
    return tp, fp, fn, tn, cats
def show(label, r):
    tp, fp, fn, tn, cats = r
    print(f"{label}: TP {tp} FP {fp} FN {fn} TN {tn}  precision {100*tp/(tp+fp):.1f} %  recall {100*tp/(tp+fn):.1f} %  F1 {2*tp/(2*tp+fp+fn):.3f}")
    return cats
held = [i for i, x in a.items() if 'another_group' in x['corrections']]
c1 = show('as frozen', count(lambda i, x: x['alerted']))
c2 = show('rule for another group off (recount)', count(lambda i, x: b[i]['alerted'] if 'another_group' in x['corrections'] else x['alerted']))
print(f"sentences the rule held back: {len(held)}; of them relevant {sum(exp[i][0]=='relevant' for i in held)}, "
      f"irrelevant {sum(exp[i][0] in ('irrelevant','repeat') for i in held)}, ambiguous {sum(exp[i][0]=='ambiguous' for i in held)}")
print('categories that change: ' + ', '.join(f"{k} {c1[k][0]}/{c1[k][1]} → {c2[k][0]}/{c2[k][1]}" for k in sorted(c1) if c1[k] != c2[k]))
