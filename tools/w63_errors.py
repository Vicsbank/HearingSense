#!/usr/bin/env python3
"""Window 6.3: lists the wrong decisions of an engine run on a development set.
  tools/w63_errors.py <set> <engine json>"""
import json, sys, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
name, path = sys.argv[1], sys.argv[2]
if name.startswith('sealed') or name == 'heldout': sys.exit('development sets only')
src = {}
for l in open(os.path.join(ROOT, f'packages/HearingSenseKit/Sources/SemanticEvaluation/Resources/semantic_{name}.txt')):
    if not l.strip() or l[0] in '#@': continue
    f = [x.strip() for x in l.split('|')]; src[f[0]] = f
for x in json.load(open(path))['outcomes']['model']:
    f = src[x['id']]; e = f[3]; a = x['alerted']
    label = 'FN' if e == 'relevant' and not a else 'FP' if e in ('irrelevant', 'repeat') and a else 'AMB' if e == 'ambiguous' else None
    if label:
        print(f"{label} {x['id']} {f[2][:14]:14} {x['verdict'][:5]:5} {x.get('kind','')[:8]:8} {x.get('audience') or '-':12} {','.join(c for c in x['corrections'] if c!='headline_not_shortened')[:28]:28} {f[6][:88]}")
