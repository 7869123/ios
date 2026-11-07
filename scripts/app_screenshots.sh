#!/usr/bin/env bash
# Capture review screenshots of the home page on an iPad mini simulator (primary) and an iPhone
# simulator (compatibility check). Uses the Debug simulator build produced by ci_app.sh.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/artifacts/app/screenshots"
mkdir -p "$out"
log="$out/screenshots.log"
: > "$log"
exec > >(tee -a "$log") 2>&1
app=$(find "$root/artifacts/app-simulator-build/Build/Products" -path '*iphonesimulator*' -name 'AIUtility.app' -maxdepth 3 | head -1)
[ -n "$app" ] || { echo "simulator AIUtility.app not found"; exit 1; }
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
runtime=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys
r=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["platform"]=="iOS"]
r.sort(key=lambda x:[int(p) for p in x["version"].split(".")])
print(r[-1]["identifier"] if r else "")')
echo "runtime: $runtime"
[ -n "$runtime" ] || { echo "no available iOS runtime"; exit 1; }
# Pick a device type this runtime supports: the first pattern (in priority order) that matches wins,
# newest match within a pattern.
pick_type() {
  xcrun simctl list runtimes -j | python3 -c 'import json,sys,re
rid=sys.argv[1]; pats=[re.compile(p) for p in sys.argv[2:]]
rt=[r for r in json.load(sys.stdin)["runtimes"] if r["identifier"]==rid]
types=rt[0].get("supportedDeviceTypes",[]) if rt else []
for pat in pats:
    t=[d for d in types if pat.search(d["name"])]
    if t: print(t[-1]["identifier"]); break' "$runtime" "$@"
}
# Launch the app so it renders its own window (true interface orientation, no rotation guessing)
# and copy Documents/<name>.png out of the sandbox. Falls back to the raw simctl framebuffer.
capture() {
  local udid="$1" orient="$2"; shift 2
  local name="$label-$orient"
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bundle" "$@" -AIUtilityCapture "$name" && sleep 12
  local data; data=$(xcrun simctl get_app_container "$udid" "$bundle" data 2>/dev/null || true)
  if [ -n "$data" ] && [ -f "$data/Documents/$name.png" ]; then
    cp "$data/Documents/$name.png" "$out/$name.png"
    echo "$name: in-app capture, $(cat "$data/Documents/$name.txt" 2>/dev/null)"
  else
    xcrun simctl io "$udid" screenshot "$out/$name-raw.png"
    echo "$name: in-app capture missing; saved raw simctl framebuffer as $name-raw.png (not rotated)"
  fi
  echo "$name: $(sips -g pixelWidth -g pixelHeight "$out/$name"*.png | awk '/pixel/{printf "%s=%s ", $1, $2}')"
}
shoot() {
  local label="$1" type="$2"
  [ -n "$type" ] || { echo "$label: no device type"; return 1; }
  echo "== $label ($type)"
  local udid
  udid=$(xcrun simctl create "review-$label" "$type" "$runtime") || return 1
  xcrun simctl boot "$udid" && xcrun simctl bootstatus "$udid" -b >/dev/null || return 1
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 || true
  xcrun simctl install "$udid" "$app" || return 1
  capture "$udid" portrait
  capture "$udid" landscape -AIUtilityPreviewLandscape
  xcrun simctl shutdown "$udid" || true
  xcrun simctl delete "$udid" || true
}
failed=0
# iPad mini 6 and iPad mini (A17 Pro) share the 744x1133 pt screen.
shoot ipad-mini "$(pick_type 'iPad mini \(A17 Pro\)' 'iPad mini \(6th generation\)' '^iPad mini')" || failed=1
shoot iphone "$(pick_type '^iPhone 17$' '^iPhone 16$' '^iPhone 15$' '^iPhone [0-9]+$')" || failed=1
ls -la "$out"
exit "$failed"
