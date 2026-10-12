#!/usr/bin/env python3
"""Window 6.3: one Markdown row per stream run in results/window6_3/stream (counts and times only).

  tools/w63_stream_table.py [directory]
"""
import glob, json, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'results/window6_3/stream')
def q(x): return '–' if x is None else f'{x:.2f}'
print('| run | engine | sentences | evaluated | not evaluated (relevant) | end to end p50 / p95 / p99 s | relevant sentences p50 / p95 s | '
      'wait for a turn p50 / p95 s | line: mean / longest | empty after s | model requests per minute | second looks | '
      'judged again (late alerts) | sentences decided per minute | true / false alerts / misses |')
print('|' + '---|' * 15)
order = ['throughput', 'tour', 'sparse']
for f in sorted(glob.glob(os.path.join(D, '*.json')), key=lambda p: (next((i for i, o in enumerate(order) if os.path.basename(p).startswith(o)), 9), os.path.basename(p).split('_')[-1], os.path.basename(p))):
    name = os.path.basename(f)[:-5]
    if name.startswith('contention'): continue
    d = json.load(open(f)); e = d['endToEnd']; r = d['endToEndRelevant']; w = d['queueWait']; c = d['confusion']
    kind, engine, pattern = name.split('_')[0], '6.2' if 'window6_2' in name else '6.3', name.split('_')[-1]
    label = {'throughput': 'set 3, 16 % relevant', 'tour': 'set 4 (listener says who they are)', 'sparse': 'set 3, 2 relevant in 35'}[kind]
    n = d['sentences']; ne = len(d['notEvaluated'])
    print(f"| {label}, {pattern} | {engine} | {n} | {n - ne} | {ne} ({len(d['notEvaluatedRelevant'])}) | {q(e['p50'])} / {q(e['p95'])} / {q(e['p99'])} | "
          f"{q(r['p50'])} / {q(r['p95'])} | {q(w['p50'])} / {q(w['p95'])} | {d['meanQueueLength']:.1f} / {d['maximumQueueLength']} | "
          f"{d['recoverySeconds']:.1f} | {d['modelCallsPerMinute']:.0f} | {d['secondLooks']} | {d['rechecks']} ({d['recheckAlerts']}) | "
          f"{d['sentencesPerMinute']:.1f} | {c['truePositives']} / {c['falsePositives']} / {c['falseNegatives']} |")
