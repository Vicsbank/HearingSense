#!/bin/sh
# Builds the app for the iOS Simulator into a private derived-data folder (nothing is installed)
# and prints errors, warnings from the app's own sources, and the result.
#   tools/build_ios_sim.sh <derived data dir> [extra xcodebuild arguments]
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
dd="${1:?derived data directory}"
shift
xcodebuild build -project "$root/apps/ios/HearingSense.xcodeproj" -scheme HearingSense \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd" -jobs 4 ARCHS=arm64 "$@" 2>&1 \
    | grep -E "^/.*(error|warning):|BUILD (SUCCEEDED|FAILED)" | sed "s|$root/||" | sort -u
