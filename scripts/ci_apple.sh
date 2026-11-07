#!/usr/bin/env bash
# Run actual Apple toolchains; preserve each exit code even when another check fails.
set -u
aiutility_root="$(cd "$(dirname "$0")/.." && pwd)"
aiutility_logs="$aiutility_root/artifacts/apple"
mkdir -p "$aiutility_logs"
: > "$aiutility_logs/exit-codes.txt"
aiutility_failed=0

record() {
  local name="$1"
  shift
  "$@" > "$aiutility_logs/$name.log" 2>&1
  local code=$?
  printf '%s=%s\n' "$name" "$code" >> "$aiutility_logs/exit-codes.txt"
  cat "$aiutility_logs/$name.log"
  if [ "$code" -ne 0 ]; then aiutility_failed=1; fi
}

record environment bash -c 'sw_vers && xcodebuild -version && swift --version && xcodebuild -showsdks'
record mac-core-tests swift test --package-path "$aiutility_root/Packages/AIUtilityCore"
record mac-services-tests swift test --package-path "$aiutility_root/Packages/AIUtilityAppleServices"
cd "$aiutility_root/Packages/AIUtilityAppleServices" || exit 1
record ios-simulator-build xcodebuild -scheme AIUtilityAppleServices -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$aiutility_root/artifacts/apple-simulator-build" \
  CODE_SIGNING_ALLOWED=NO build
record ios-device-build xcodebuild -scheme AIUtilityAppleServices -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath "$aiutility_root/artifacts/apple-device-build" \
  CODE_SIGNING_ALLOWED=NO build
exit "$aiutility_failed"
