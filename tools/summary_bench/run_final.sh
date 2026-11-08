#!/bin/zsh
# Stage B: frozen held-out set, models one after another (never concurrently).
cd "$(dirname "$0")/../.."
for m in apple qwen35-4b lfm25-2.6b; do
  caffeinate -i tools/model_bench/.venv/bin/python tools/summary_bench/sbench.py run --model $m --set final --tasks neutral,prod,continue,latency --phase final 2>&1 | grep -v -i warning
done
echo ALL_DONE
