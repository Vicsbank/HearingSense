#!/bin/zsh
# Window 6.3: runs request descriptions one after another on a development set (the on-device
# model serves one request at a time; two runs at once would distort each other).
#   tools/w63_probe.sh <set> <spec name> [<spec name> ...]
# With W63_FROM=<probe json> and W63_IDS=<ids file> the run is a second request on those sentences.
set -u
ROOT="${0:A:h:h}"
BIN="${W63_BIN:-/private/tmp/claude-501/-Users-vicwei-Desktop-Music-Recognition/72dda449-fe9b-4499-8550-549d97a795b3/scratchpad/build63/release/hs-semantic-eval}"
OUT="$ROOT/results/window6_3/probe"
SET="$1"; shift
python3 "$ROOT/tools/w63_specs.py" > /dev/null
for name in "$@"; do
  extra=()
  [ -n "${W63_FROM:-}" ] && extra+=(--from "$W63_FROM")
  [ -n "${W63_IDS:-}" ] && extra+=(--ids "$W63_IDS")
  suffix="${W63_SUFFIX:-}"
  "$BIN" probe2 --spec "$ROOT/results/window6_3/specs/$name.json" --set "$SET" $extra --json "$OUT/${name}${suffix}_${SET}.json" 2>/dev/null | tail -1
done
