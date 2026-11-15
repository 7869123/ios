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

# Like record, but stops a command that runs longer than $2 seconds so its log is still printed (a stalled test
# otherwise ran into the job timeout with no output at all).
record_limited() {
  local name="$1" seconds="$2"
  shift 2
  "$@" > "$aiutility_logs/$name.log" 2>&1 &
  local pid=$!
  ( sleep "$seconds"; if kill -0 "$pid" 2>/dev/null; then
      echo "WATCHDOG: $name still running after ${seconds}s; stopping it" >> "$aiutility_logs/$name.log"
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; sleep 5
      pkill -KILL -f 'swiftpm-testing-helper|xctest' 2>/dev/null; kill -KILL "$pid" 2>/dev/null
    fi ) &
  local dog=$!
  wait "$pid"; local code=$?
  kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  printf '%s=%s\n' "$name" "$code" >> "$aiutility_logs/exit-codes.txt"
  cat "$aiutility_logs/$name.log"
  if [ "$code" -ne 0 ]; then aiutility_failed=1; fi
}

record environment bash -c 'sw_vers && xcodebuild -version && swift --version && xcodebuild -showsdks'
record_limited mac-core-tests 600 swift test --package-path "$aiutility_root/Packages/AIUtilityCore"
record_limited mac-services-tests 600 swift test --package-path "$aiutility_root/Packages/AIUtilityAppleServices"
cd "$aiutility_root/Packages/AIUtilityAppleServices" || exit 1
record ios-simulator-build xcodebuild -scheme AIUtilityAppleServices -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$aiutility_root/artifacts/apple-simulator-build" \
  CODE_SIGNING_ALLOWED=NO build
record ios-device-build xcodebuild -scheme AIUtilityAppleServices -sdk iphoneos \
  -destination 'generic/platform=iOS' -derivedDataPath "$aiutility_root/artifacts/apple-device-build" \
  CODE_SIGNING_ALLOWED=NO build
exit "$aiutility_failed"
