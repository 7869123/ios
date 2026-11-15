#!/usr/bin/env bash
# Pre-device diagnostics on a macOS runner (workflow input `diagnostics`). Every case runs in its own
# `swift test --filter` process with a time limit; a case that does not finish gets a `sample` of the stuck test
# process (top of its call stacks) before it is stopped. Results are the "DIAG" lines; the step never fails on
# a diagnostic outcome, only on a build error.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/diagnostics"
mkdir -p "$out"
summary="$out/summary.txt"
: > "$summary"
export AIUTILITY_DIAGNOSTICS=1

{ sw_vers; xcodebuild -version; sysctl -n machdep.cpu.brand_string hw.memsize; } > "$out/environment.log" 2>&1
cat "$out/environment.log"

build_failed=0
for pkg in AIUtilityAppleServices AIUtilityMedia; do
  swift build --build-tests --package-path "$root/Packages/$pkg" > "$out/build-$pkg.log" 2>&1 || { echo "BUILD FAILED: $pkg"; tail -40 "$out/build-$pkg.log"; build_failed=1; }
done
[ "$build_failed" -eq 0 ] || exit 1

run_case() {
  local pkg="$1" filter="$2" limit="$3"; shift 3
  local log="$out/$filter.log"
  local report="$out/$filter.diag"; : > "$report"
  env AIUTILITY_DIAG_REPORT="$report" "$@" swift test --skip-build --package-path "$root/Packages/$pkg" --filter "$filter" > "$log" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$limit" ]; do sleep 2; waited=$((waited + 2)); done
  if kill -0 "$pid" 2>/dev/null; then
    echo "DIAG $filter: STILL RUNNING after ${limit}s; sampling" >> "$log"
    for helper in $(pgrep -f 'swiftpm-testing-helper|xctest' || true); do
      sample "$helper" 5 -file "$out/$filter-sample-$helper.txt" > /dev/null 2>&1 || true
      # The deepest frames of the busiest threads show what the process waits on.
      { echo "--- sample of pid $helper (first 80 lines of the call graph)"; sed -n '/Call graph:/,/Total number in stack/p' "$out/$filter-sample-$helper.txt" | head -80; } >> "$log"
    done
    pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; sleep 3
    pkill -KILL -f 'swiftpm-testing-helper|xctest' 2>/dev/null; kill -KILL "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null; local code=$?
  echo "== $filter (exit $code, ${waited}s)" | tee -a "$summary"
  cat "$report" | tee -a "$summary"
  grep -h "DIAG\|✘\|recorded an issue\|passed after\|skipped" "$log" | tee -a "$summary"
}

# Vision language matrix (one process each, so a stall shows exactly which combination stalls).
for filter in diagVision1English diagVision2EnglishJapanese diagVision3EnglishChinese diagVision4EnglishKorean \
              diagVision5AllFour diagVision6AllFourNoDetection diagVision7OldDefaultThree \
              diagVision8TallImageScaled diagVision9OrientedImageRegion; do
  run_case AIUtilityAppleServices "$filter" 150
done
# The opt-in four-language test and the Keychain test, both normally skipped in CI.
run_case AIUtilityAppleServices visionAcceptsEverySupportedLanguageForAutomaticSource 150 AIUTILITY_VISION_LANGUAGE_TESTS=1
run_case AIUtilityAppleServices keychainReplacesSingleProviderRecordAtomically 120 AIUTILITY_KEYCHAIN_TESTS=1
# Local media tools.
for filter in diagPNGTextChunkIsDetectedAndStripped diagHEICStripAndReencode diagGIFPeakMemoryAtTheUILimits; do
  run_case AIUtilityMedia "$filter" 360
done

echo; echo "==== summary"; cat "$summary"
exit 0
