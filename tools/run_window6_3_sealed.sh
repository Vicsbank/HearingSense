#!/bin/zsh
# Window 6.3: the sealed evaluation. RUN ONCE, after the configuration is frozen and committed.
#
#   tools/run_window6_3_sealed.sh
#
# semantic_sealed3.txt was written by an author who saw nothing of this repository. Nothing may be
# tuned after this script has run; whatever it prints is reported as it is.
# Each configuration is run once:
#   - the baselines without a language model;
#   - Window 6.3, each sentence by itself (as the set was written);
#   - Window 6.3, each sentence with the three said before it in the file (as the app hands them in);
#   - Window 6.3 as it works while sentences wait (the session continues);
#   - Window 6.2, each sentence by itself, and with the three said before it (as its app handed them in).
# The script refuses to run a second time.
set -u
ROOT="${0:A:h:h}"
OUT="$ROOT/results/window6_3/sealed"
BIN="${W63_BIN:-$ROOT/packages/HearingSenseKit/.build/out/Products/Release/hs-semantic-eval}"
[ -e "$OUT/sealed3_window6_3.json" ] && { echo "The sealed set has been run already ($OUT). It is not run twice."; exit 1; }
[ -x "$BIN" ] || { echo "build first: swift build -c release --product hs-semantic-eval"; exit 1; }
mkdir -p "$OUT"
(cd "$ROOT" && git rev-parse HEAD && git status --short | wc -l | tr -d ' ') > "$OUT/commit.txt"
shasum -a 256 "$ROOT/packages/HearingSenseKit/Sources/SemanticEvaluation/Resources/semantic_sealed3.txt" >> "$OUT/commit.txt"

run() { # $1: name, rest: arguments
  local name="$1"; shift
  caffeinate -i "$BIN" run --set sealed3 --errors "$@" --json "$OUT/$name.json" > "$OUT/$name.txt" 2>/dev/null
  grep -m1 "confusion" "$OUT/$name.txt" | sed "s/^/$name:/"
}
run sealed3_baselines --methods keyword,embedding
run sealed3_window6_3 --methods model --config window6_3 --reuse 1 --no-steps
run sealed3_window6_3_conversation --methods model --config window6_3 --reuse 1 --no-steps --conversation 3
run sealed3_window6_3_busy --methods model --config window6_3
run sealed3_window6_2 --methods model --config window6_2 --reuse 1 --no-steps
run sealed3_window6_2_conversation --methods model --config window6_2 --reuse 1 --no-steps --conversation 3
echo "Wrote $OUT"
