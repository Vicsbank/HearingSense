"""Match played clips (Mac playback log) with the iPhone diagnostics event log.

Usage: analyze_alerts.py <playback.log> <diagnostics.txt> [window_s]
Prints, per clip, every confirmed event and expansion request inside the window after the
clip's sound onset, with latency from onset. The playback log is Mac local time (MST),
the export is UTC: clip times are shifted by +7 h. The Mac-iPhone clock offset is not measured.
"""
import re, sys, datetime

play_log, diag, window = sys.argv[1], sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 12.0

def t(s):
    h, m, rest = s.split(':')
    return int(h) * 3600 + int(m) * 60 + float(rest)

clips = []
for line in open(play_log):
    m = re.match(r'(\S+) play (\S+) (\S+) onset\+([\d.]+)', line)
    if m:
        clips.append((m.group(2), m.group(3), (t(m.group(1)) + float(m.group(4)) + 7 * 3600) % 86400))

events = []
in_log = False
for line in open(diag, errors='replace'):
    if line.startswith('== Event log'):
        in_log = True; continue
    if line.startswith('== ') and in_log:
        break
    if not in_log:
        continue
    m = re.match(r'(\d\d:\d\d:\d\d\.\d+) \[(\w+)\] (.*)', line.rstrip())
    if m:
        events.append((t(m.group(1)), m.group(3)))

for name, file, onset in clips:
    print(f'== {name} ({file})')
    for ts, text in events:
        if onset - 0.5 <= ts <= onset + window and (
                text.startswith('Event confirmed') or ('expansion requested' in text or 'prominent presentation requested' in text or 'Attention SHOW' in text) or 'Alert' in text
                or 'alert' in text):
            short = re.sub(r', \d+ windows, latency [\d.]+ s audio', '', text)
            print(f'   +{ts - onset:5.2f} s  {short[:150]}')

# Lines outside every clip window that requested an expansion (possible false alerts).
print('== expansion requests outside clip windows')
for ts, text in events:
    if ('expansion requested' in text or 'prominent presentation requested' in text or 'Attention SHOW' in text) and not any(o - 0.5 <= ts <= o + window for _, _, o in clips):
        print(f'   {datetime.timedelta(seconds=ts)}  {text[:150]}')
