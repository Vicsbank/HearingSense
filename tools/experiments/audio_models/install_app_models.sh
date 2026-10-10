#!/bin/sh
# Copies the converted classifiers (models/coreml_audio, made by convert_coreml.py) into the app's
# Experiments folder so that Xcode compiles them into Debug builds. The copies are not committed.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TARGET="$ROOT/apps/ios/HearingSense/Experiments/Models"
mkdir -p "$TARGET"
rm -rf "$TARGET"/*.mlpackage
for NAME in YAMNet EfficientAT_MN10_10s EfficientAT_DyMN04_2s; do
    rm -rf "$TARGET/$NAME.mlpackage"
    cp -R "$ROOT/models/coreml_audio/$NAME.mlpackage" "$TARGET/"
    echo "installed $NAME"
done
