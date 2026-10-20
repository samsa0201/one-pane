#!/usr/bin/env bash
# Builds mt.dex and pushes it to the emulator/device ($ANDROID_SERIAL).
set -euo pipefail
cd "$(dirname "$0")"
SDK=${ANDROID_HOME:-$HOME/Android/Sdk}
out=$(mktemp -d)
javac -source 11 -target 11 -cp "$SDK/platforms/android-34/android.jar" -d "$out" Mt.java
"$SDK/build-tools/36.0.0/d8" --min-api 26 --output "$out" "$out"/*.class
adb push "$out/classes.dex" /data/local/tmp/mt.dex >/dev/null
rm -rf "$out"
echo "pushed /data/local/tmp/mt.dex"
