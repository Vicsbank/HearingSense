#!/bin/zsh
# Window 6.2: the sealed evaluation. RUN ONCE, after the configuration is frozen and committed.
#
#   tools/run_window6_2_sealed.sh
#
# semantic_sealed2.txt was written by an author who saw nothing of this repository. Nothing may be
# tuned after this script has run; whatever it prints is reported as it is.
# Each configuration is run once: the baselines without a language model, the Window 6.2 engine in
# its normal operation (a session per sentence), the same engine as it works while sentences are
# waiting (the session continues, the kind is asked first), and Windows 6.1 and 6 for comparison.
# The script refuses to run a second time.
set -u
ROOT="${0:A:h:h}"
OUT="$ROOT/results/window6_2/sealed"
BIN="$ROOT/packages/HearingSenseKit/.build/out/Products/Release/hs-semantic-eval"
[ -e "$OUT/sealed2_window6_2.json" ] && { echo "The sealed set has been run already ($OUT). It is not run twice."; exit 1; }
[ -x "$BIN" ] || { echo "build first: swift build -c release --product hs-semantic-eval"; exit 1; }
mkdir -p "$OUT"
(cd "$ROOT" && git rev-parse HEAD && git status --short | wc -l | tr -d ' ') > "$OUT/commit.txt"
shasum -a 256 "$ROOT/packages/HearingSenseKit/Sources/SemanticEvaluation/Resources/semantic_sealed2.txt" >> "$OUT/commit.txt"

run() { # $1: name, rest: arguments
  local name="$1"; shift
  "$BIN" run --set sealed2 --errors "$@" --json "$OUT/$name.json" > "$OUT/$name.txt" 2>/dev/null
  grep -m1 "confusion" "$OUT/$name.txt" | sed "s/^/$name:/"
}
run sealed2_baselines --methods keyword,embedding
run sealed2_window6_2 --methods model --config window6_2 --reuse 1 --no-steps
run sealed2_window6_2_busy --methods model --config window6_2 --reuse 4 --steps
run sealed2_window6_1 --methods model --config window6_1
run sealed2_window6 --methods model --config window6
echo "Wrote $OUT"
