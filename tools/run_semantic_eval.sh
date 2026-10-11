#!/bin/sh
# Window 6: runs hs-semantic-eval on one set and stores the report and the JSON under
# results/semantic_eval_window6/. Forward-only inference with the on-device language model
# (about 4 minutes per run on the M1 Max); no training.
#
#   tools/run_semantic_eval.sh dev            keyword, embedding and model, first pass on
#   tools/run_semantic_eval.sh dev no-triage  model only, first pass off
#   tools/run_semantic_eval.sh heldout        report only: do not tune on this set
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
set_name="${1:-dev}"
variant="${2:-triage}"
out="$root/results/semantic_eval_window6"
mkdir -p "$out"
cd "$root/packages/HearingSenseKit"
if [ "$variant" = "no-triage" ]; then
    swift run hs-semantic-eval run --set "$set_name" --methods model --no-triage --errors \
        --json "$out/${set_name}_no_triage.json" > "$out/${set_name}_no_triage.txt" 2>/dev/null
else
    swift run hs-semantic-eval run --set "$set_name" --errors \
        --json "$out/${set_name}_triage.json" > "$out/${set_name}_triage.txt" 2>/dev/null
fi
echo "done: $set_name $variant"
