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
pick_type() {
  xcrun simctl list devicetypes -j | python3 -c 'import json,sys,re
pat=re.compile(sys.argv[1])
t=[d for d in json.load(sys.stdin)["devicetypes"] if pat.search(d["name"])]
print(t[-1]["identifier"] if t else "")' "$1"
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
  xcrun simctl launch "$udid" "$bundle" && sleep 8
  xcrun simctl io "$udid" screenshot "$out/$label-portrait.png"
  xcrun simctl terminate "$udid" "$bundle" || true
  xcrun simctl launch "$udid" "$bundle" -AIUtilityPreviewLandscape && sleep 8
  xcrun simctl io "$udid" screenshot "$out/$label-landscape.png"
  # simctl captures the framebuffer in device orientation; rotate if it came out portrait-shaped.
  w=$(sips -g pixelWidth "$out/$label-landscape.png" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$out/$label-landscape.png" | awk '/pixelHeight/{print $2}')
  if [ "$w" -lt "$h" ]; then sips -r 270 "$out/$label-landscape.png" >/dev/null; echo "rotated landscape capture"; fi
  xcrun simctl shutdown "$udid" || true
  xcrun simctl delete "$udid" || true
}
failed=0
shoot ipad-mini "$(pick_type '^iPad mini')" || failed=1
shoot iphone "$(pick_type '^iPhone [0-9]+$')" || failed=1
ls -la "$out"
exit "$failed"
