#!/bin/sh
# Window 6.1: one evaluation run of hs-semantic-eval, stored under results/semantic_optimization/<dir>/.
# Forward-only inference with the on-device language model; no training. One run at a time.
#
#   tools/run_semantic_ablation.sh <dir> <name> <set> [hs-semantic-eval run options...]
#   e.g. tools/run_semantic_ablation.sh ablation lean_dev2 dev2 --style lean --no-triage
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$1"; name="$2"; set_name="$3"; shift 3
out="$root/results/semantic_optimization/$dir"
mkdir -p "$out"
cd "$root/packages/HearingSenseKit"
swift run hs-semantic-eval run --set "$set_name" --methods model --errors "$@" \
    --json "$out/$name.json" > "$out/$name.txt" 2>/dev/null
echo "done: $name"
