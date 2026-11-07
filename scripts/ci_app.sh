#!/usr/bin/env bash
set -u
aiutility_root="$(cd "$(dirname "$0")/.." && pwd)"
aiutility_logs="$aiutility_root/artifacts/app"
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
record environment bash -c 'sw_vers && xcodebuild -version && swift --version'
record generate bash -c 'set -e; if ! command -v xcodegen >/dev/null; then brew install xcodegen; fi; xcodegen --version; cd "$1"; xcodegen generate --spec Apps/AIUtility/project.yml' _ "$aiutility_root"
record simulator-build xcodebuild -project "$aiutility_root/Apps/AIUtility/AIUtility.xcodeproj" -scheme AIUtility \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$aiutility_root/artifacts/app-simulator-build" CODE_SIGNING_ALLOWED=NO build
record device-build xcodebuild -project "$aiutility_root/Apps/AIUtility/AIUtility.xcodeproj" -scheme AIUtility \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$aiutility_root/artifacts/app-device-build" CODE_SIGNING_ALLOWED=NO build
exit "$aiutility_failed"
