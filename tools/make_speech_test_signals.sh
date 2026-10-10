#!/bin/bash
# Generates the Window 3 speech test signals with the macOS text-to-speech voices.
#
# SYNTHETIC speech: useful for checking the transcription → summary pipeline end to end with
# known sentences (including negations), but not evidence of accuracy on human speech.
# Output: data/test_signals/window3/<id>.aiff (not committed; regenerate with this script).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/data/test_signals/window3"
mkdir -p "$out"
tail -n +2 "$root/tools/speech_test_sentences.tsv" | while IFS=$'\t' read -r id voice text; do
    say -v "$voice" -o "$out/$id.aiff" "$text"
    echo "$id ($voice)"
done
