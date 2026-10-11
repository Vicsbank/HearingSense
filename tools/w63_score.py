#!/usr/bin/env python3
"""Window 6.3: scores raw answers of `hs-semantic-eval probe2` against a labelled set.

  tools/w63_score.py --set dev4 first.json [--check check.json --keep "c['about']=='hereAndNow'"]
                     [--rule "<python over a (fields of the first answer)>"] [--list] [--by category|profile]

An alert needs the rule to hold for the first answer and, when the sentence was checked, the keep
expression to hold for the check's answer. Repetitions are not scored here (the engine's work)
unless --repeats is given, in which case an alert on a repetition counts as a false alert.
"""
import argparse, json, os, sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, 'packages/HearingSenseKit/Sources/SemanticEvaluation/Resources')
DEFAULT_RULE = "a.get('kind') in ('change','request','warning') and int(a.get('goal','0'))>=1 and a.get('verdict') in ('relevant','urgent')"

def load_set(name):
    if name in ('sealed', 'sealed2', 'sealed3', 'heldout'):
        sys.exit('sealed and exposed report-only sets are not scored with this tool')
    items = {}
    for line in open(os.path.join(RES, f'semantic_{name}.txt')):
        if not line.strip() or line[0] in '#@': continue
        f = [x.strip() for x in line.split('|')]
        items[f[0]] = dict(id=f[0], profile=f[1], category=f[2], expected=f[3], goals=f[4], flags=f[5], text=f[6])
    return items

def decide(items, first, check, rule, keep):
    out = {}
    for x in first:
        a = x['fields']; a = dict(a, text=x.get('text') or '')
        try: alert = bool(eval(rule, {}, {'a': a, 'item': items[x['id']]}))
        except Exception: alert = False
        c = check.get(x['id'])
        if alert and c is not None and keep:
            cf = dict(c['fields'], text=c.get('text') or '')
            try: alert = bool(eval(keep, {}, {'c': cf, 'a': a, 'item': items[x['id']]}))
            except Exception: alert = False
        out[x['id']] = alert
    return out

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--set', required=True); p.add_argument('first')
    p.add_argument('--check', action='append', default=[]); p.add_argument('--keep', action='append', default=[])
    p.add_argument('--rule', default=DEFAULT_RULE); p.add_argument('--list', action='store_true')
    p.add_argument('--by', default='category'); p.add_argument('--repeats', action='store_true')
    p.add_argument('--ids-out'); p.add_argument('--quiet', action='store_true')
    args = p.parse_args()
    items = load_set(args.set)
    first = json.load(open(args.first))
    alerts = decide(items, first, {}, args.rule, None)
    for path, keep in zip(args.check, args.keep):
        check = {x['id']: x for x in json.load(open(path))}
        for x in first:
            if alerts[x['id']] and x['id'] in check:
                cf = dict(check[x['id']]['fields'], text=check[x['id']].get('text') or '')
                try: alerts[x['id']] = bool(eval(keep, {}, {'c': cf, 'a': x['fields'], 'item': items[x['id']]}))
                except Exception: alerts[x['id']] = False
    if args.ids_out:
        open(args.ids_out, 'w').write('\n'.join(i for i, v in alerts.items() if v) + '\n')
    tp = fp = fn = tn = amb = amb_n = rep = rep_n = 0
    by = defaultdict(lambda: [0, 0]); fps = []; fns = []; ambs = []
    for x in first:
        it = items[x['id']]; al = alerts[x['id']]; e = it['expected']
        key = it[args.by]
        if e == 'relevant':
            by[key][1] += 1
            if al: tp += 1
            else: fn += 1; fns.append(it); by[key][0] += 1
        elif e == 'irrelevant':
            by[key][1] += 1
            if al: fp += 1; fps.append(it); by[key][0] += 1
            else: tn += 1
        elif e == 'ambiguous':
            amb_n += 1; amb += al
            if al: ambs.append(it)
        elif e == 'repeat':
            rep_n += 1; rep += al
    failed = sum(1 for x in first if x.get('failure'))
    prec = tp / max(1, tp + fp); rec = tp / max(1, tp + fn)
    secs = [x['seconds'] for x in first]; toks = [x['outputTokens'] for x in first if x.get('outputTokens')]
    print(f"{os.path.basename(args.first):34} TP {tp} FP {fp} FN {fn} TN {tn}  P {prec*100:.1f} R {rec*100:.1f}  "
          f"amb {amb}/{amb_n} rep-alerts {rep}/{rep_n} failed {failed}  {sum(secs)/max(1,len(secs)):.2f}s {sum(toks)/max(1,len(toks)):.1f}tok")
    if args.quiet: return
    print('  errors by ' + args.by + ': ' + ', '.join(f"{k} {v[0]}/{v[1]}" for k, v in sorted(by.items()) if v[0]))
    if args.list:
        fa = {x['id']: x['fields'] for x in first}
        for label, group in (('FP', fps), ('FN', fns), ('AMB', ambs)):
            for it in group:
                print(f"  {label} {it['id']} {it['category']:16} {it['text'][:95]}  {json.dumps(fa[it['id']], sort_keys=True)}")

if __name__ == '__main__':
    main()
