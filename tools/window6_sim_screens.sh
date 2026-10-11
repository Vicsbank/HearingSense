#!/bin/sh
# Window 6: screenshots of the conversation screens in the iOS Simulator, without a microphone.
# Each launch plays the scripted conversation (`--hs-conversation-demo`: synthetic sentences
# through the real buffer, semantic engine and recap engine; nothing is stored) and opens one
# screen (`--hs-screen`). Simulator evidence only.
#
#   tools/window6_sim_screens.sh <simulator UDID> <built HearingSense.app> <output directory>
#
# Use a simulator that no other session is using: the app on it is replaced.
set -eu
udid="${1:?simulator UDID}"
app="${2:?path to HearingSense.app}"
out="${3:?output directory}"
mkdir -p "$out"
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$app"
number=1
for screen in conversation summary history goals privacy icons main; do
    if [ "$screen" = "main" ]; then
        xcrun simctl launch --terminate-running-process "$udid" org.hearingsense.HearingSense --hs-conversation-demo >/dev/null
    else
        xcrun simctl launch --terminate-running-process "$udid" org.hearingsense.HearingSense \
            --hs-conversation-demo --hs-screen "$screen" >/dev/null
    fi
    if [ "$screen" = "icons" ] || [ "$screen" = "privacy" ]; then sleep 6; else sleep 50; fi
    xcrun simctl io "$udid" screenshot "$out/0$number-$screen.png" >/dev/null 2>&1
    echo "$screen"
    number=$((number + 1))
done
xcrun simctl terminate "$udid" org.hearingsense.HearingSense || true
