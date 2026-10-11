#!/usr/bin/env python3
"""Window 6.2: summarises the top(1) samples of the system process that runs the on-device
language model, taken every 2 s while a stream benchmark ran (tools/run_window6_2_streams.sh).

    python3 tools/semantic_model_process_summary.py results/window6_2/stream

Columns of a sample: pid, CPU share of one core in percent, memory as top reports it (its
"MEM" column: the process's own footprint, without the model weights the system maps for it),
energy impact. The largest process by memory is taken to be the one that runs the model."""
import glob
import os
import re
import sys


def megabytes(text):
    m = re.match(r"([0-9.]+)([KMG])", text)
    return float(m.group(1)) * {"K": 1 / 1024, "M": 1, "G": 1024}[m.group(2)] if m else 0.0


rows = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.top"))):
    by_pid = {}
    for line in open(path):
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            by_pid.setdefault(parts[0], []).append((float(parts[1]), megabytes(parts[2]), float(parts[3])))
        except ValueError:
            continue
    if not by_pid:
        continue
    samples = max(by_pid.values(), key=lambda s: max(x[1] for x in s))
    rows.append((os.path.basename(path)[:-4], len(samples), sum(x[0] for x in samples) / len(samples),
                 max(x[0] for x in samples), min(x[1] for x in samples), max(x[1] for x in samples),
                 sum(x[2] for x in samples) / len(samples)))
print(f"{'run':40} samples  CPU % mean / max   memory MB min–max   energy impact mean")
for name, n, cpu, cpu_max, low, high, power in rows:
    print(f"{name:40} {n:5}    {cpu:5.1f} / {cpu_max:5.1f}      {low:6.0f}–{high:<6.0f}      {power:6.1f}")
