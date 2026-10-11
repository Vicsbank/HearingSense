#!/bin/zsh
# Window 6.3: runs the whole engine on a development set, one run after another.
#   tools/w63_engine.sh <name> <set> [arguments of `hs-semantic-eval run`]
set -u
ROOT="${0:A:h:h}"
BIN="${W63_BIN:-/private/tmp/claude-501/-Users-vicwei-Desktop-Music-Recognition/72dda449-fe9b-4499-8550-549d97a795b3/scratchpad/bin63/hs-semantic-eval}"
OUT="$ROOT/results/window6_3/engine"
mkdir -p "$OUT"
name="$1"; set="$2"; shift 2
caffeinate -i "$BIN" run --set "$set" --methods model "$@" --json "$OUT/${name}_${set}.json" > "$OUT/${name}_${set}.txt" 2>/dev/null
grep -E "precision|recall  |false alerts  |ambiguous items" "$OUT/${name}_${set}.txt" | tr -s ' ' | tr '\n' ';' | sed "s/^/${name} ${set}:/"; echo
