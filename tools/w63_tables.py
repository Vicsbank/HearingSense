#!/usr/bin/env python3
"""Window 6.3: prints the numbers of engine runs (JSON written by `hs-semantic-eval run --json`) as Markdown.

  tools/w63_tables.py <label>=<json> [<label>=<json> ...]

Counts only (no sentence text), so it may be used on the sealed runs.
"""
import json, sys

GROUPS = ['implicit relevance recall', 'explicit relevance recall', 'important-event recall',
          'short urgent instruction recall', 'announcement to all or own group', 'said to others, concerns all',
          'another person addressed', 'another group addressed', 'personal relevance accuracy', 'negation accuracy',
          'hypothetical accuracy', 'past and quotation accuracy', 'idiom accuracy', 'recognition-error accuracy',
          'context (several sentences) accuracy', 'unrelated talk accuracy', 'repetition accuracy', 'cut-off sentence accuracy']

def load(path):
    d = json.load(open(path))
    c = d['confusion']; c = c.get('model') or next(iter(c.values()))
    m = [x for x in d['metrics'] if 'Foundation' in x['method']] or d['metrics']
    return d, c, m[-1]

def pct(h, t): return f"{100*h/t:.1f} % ({h}/{t})" if t else "–"

runs = [(a.split('=', 1)[0], *load(a.split('=', 1)[1])) for a in sys.argv[1:]]
print('| | ' + ' | '.join(r[0] for r in runs) + ' |'); print('|---|' + '---|' * len(runs))
def row(name, f): print(f'| {name} | ' + ' | '.join(f(r) for r in runs) + ' |')
row('true alerts / false alerts / misses / silent', lambda r: f"{r[2]['truePositives']} / {r[2]['falsePositives']} / {r[2]['falseNegatives']} / {r[2]['trueNegatives']}")
row('precision', lambda r: pct(r[2]['truePositives'], r[2]['truePositives'] + r[2]['falsePositives']))
row('recall', lambda r: pct(r[2]['truePositives'], r[2]['truePositives'] + r[2]['falseNegatives']))
row('F1', lambda r: f"{2*r[2]['truePositives']/(2*r[2]['truePositives']+r[2]['falsePositives']+r[2]['falseNegatives']):.3f}")
row('false-positive rate', lambda r: pct(r[2]['falsePositives'], r[2]['falsePositives'] + r[2]['trueNegatives']))
row('false-negative rate', lambda r: pct(r[2]['falseNegatives'], r[2]['truePositives'] + r[2]['falseNegatives']))
row('ambiguous (not scored): alerted / listed / nothing', lambda r: f"{r[2]['ambiguousAlerted']} / {r[2]['ambiguousUncertain']} / {r[2]['ambiguousSilent']}")
row('goal named correctly', lambda r: pct(r[3]['goalAccuracy']['hits'], r[3]['goalAccuracy']['total']))
for g in GROUPS:
    if any(g in r[2]['groups'] for r in runs):
        row(g, lambda r: pct(r[2]['groups'][g]['hits'], r[2]['groups'][g]['total']) if g in r[2]['groups'] else '–')
profiles = sorted({p for r in runs for p in r[2]['byProfile']})
for p in profiles:
    def f(r, p=p):
        b = r[2]['byProfile'].get(p)
        if not b: return '–'
        tp, fp, fn = b.get('tp', 0), b.get('fp', 0), b.get('fn', 0)
        return f"P {pct(tp, tp + fp)}, R {pct(tp, tp + fn)}"
    row(f'profile {p}', f)
row('corrections', lambda r: ', '.join(f"{k} {v}" for k, v in sorted(r[3]['corrections'].items()) if k != 'headline_not_shortened'))
row('seconds per sentence, median / p95', lambda r: f"{r[3]['medianSeconds']:.2f} / {r[3]['p95Seconds']:.2f}")
# decisions that differ from the first run
first = {x['id']: x['alerted'] for x in runs[0][1]['outcomes']['model']} if 'model' in runs[0][1]['outcomes'] else {}
def differ(r):
    o = r[1]['outcomes'].get('model')
    if not o or not first: return '–'
    return str(sum(1 for x in o if x['id'] in first and first[x['id']] != x['alerted'])) + f" of {len(o)}"
row('decisions that differ from the first column', differ)
