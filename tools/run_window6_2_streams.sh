#!/bin/zsh
# Window 6.2: stream benchmarks of the semantic engine, Window 6.1 against Window 6.2 on the same
# synthetic, timestamped sentences (development set 3). Mac only; no microphone.
#
#   tools/run_window6_2_streams.sh [output directory]
#
# One run at a time: the on-device model serves one request at a time, and anything else that
# uses it would distort the timings. While a run is going, the memory, CPU share and energy
# impact of the system process that runs the model are sampled with top(1) every 2 s.
# Full output goes to the directory; only one line per run is printed.
set -u
ROOT="${0:A:h:h}"
OUT="${1:-$ROOT/results/window6_2/stream}"
BIN="$ROOT/packages/HearingSenseKit/.build/out/Products/Release/hs-semantic-eval"
mkdir -p "$OUT"
[ -x "$BIN" ] || { echo "build first: swift build -c release --product hs-semantic-eval"; exit 1; }

sample_model_process() { # $1: log file. Samples until killed.
  local pids=($(pgrep -f TGOnDeviceInferenceProviderService))
  [ ${#pids} -eq 0 ] && return
  local args=()
  for pid in $pids; do args+=(-pid $pid); done
  top -l 0 -s 2 -stats pid,cpu,mem,power $args 2>/dev/null | grep --line-buffered -E "^[0-9]+ " > "$1"
}

run() { # $1: name, rest: arguments of hs-semantic-eval
  local name="$1"; shift
  sample_model_process "$OUT/$name.top" &
  local sampler=$!
  "$BIN" "$@" --json "$OUT/$name.json" > "$OUT/$name.txt" 2>/dev/null
  pkill -P $sampler 2>/dev/null; kill $sampler 2>/dev/null
  grep -m1 -E "end to end" "$OUT/$name.txt" | sed "s/^/$name: /"
  sleep 3
}

for pattern in 3.0 1.5 1.0 bursty dense; do
  for config in window6_1 window6_2; do
    run "throughput_${config}_${pattern}" throughput --config $config --pattern $pattern --count 40 --set dev3 --profile tenant
  done
done
for config in window6_1 window6_2; do
  run "contention_${config}" contention --config $config --interval 1.5 --count 16 --set dev3 --profile cook
done
echo "Wrote $OUT"
