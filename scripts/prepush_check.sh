#!/usr/bin/env bash
# Pre-push gate for batched development. Run before pushing a batch; it does NOT replace the
# Apple SDK build (run workflow_dispatch build_apple for that).
#   PYTHON=/path/to/python-with-tree-sitter scripts/prepush_check.sh [base-ref]
# base-ref defaults to the upstream of the current branch.
set -u
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
base="${1:-}"
[ -n "$base" ] || base="@{upstream}"
failed=0
step() { printf '\n== %s\n' "$1"; }
run() { "$@" || failed=1; }

step "1/6 Swift grammar, source hygiene, plists (tree-sitter; not type checking)"
if "$PY" -c 'import tree_sitter, tree_sitter_swift' 2>/dev/null; then
  run "$PY" scripts/check_repository.py --swift-grammar
else
  echo "tree-sitter not available for $PY; grammar check skipped (install tree-sitter tree-sitter-swift)"; failed=1
fi

step "2/6 Workflow YAML and shell syntax"
run "$PY" -c 'import sys, yaml; [yaml.safe_load(open(p)) for p in sys.argv[1:]]; print("yaml ok")' .github/workflows/*.yml
for f in scripts/*.sh; do bash -n "$f" || { echo "shell syntax error: $f"; failed=1; }; done && echo "shell ok"

step "3/6 Resource integrity (project.yml sources, Info.plist, bundled images)"
run "$PY" - <<'PY'
import plistlib, sys, yaml
from pathlib import Path
bad = []
for spec in sorted(Path(".").glob("Apps/*/project.yml")) + sorted(Path(".").glob("PoCs/*/project.yml")):
    root = spec.parent
    project = yaml.safe_load(spec.read_text())
    for name, target in (project.get("targets") or {}).items():
        for src in target.get("sources", []):
            path = root / (src if isinstance(src, str) else src.get("path", ""))
            if not path.exists(): bad.append(f"{spec}: target {name} source missing: {path}")
        plist = (target.get("settings", {}).get("base", {}) or {}).get("INFOPLIST_FILE")
        if plist:
            try: plistlib.loads((root / plist).read_bytes())
            except Exception as e: bad.append(f"{spec}: Info.plist {plist}: {type(e).__name__}")
for image in list(Path("Apps").rglob("*.jpg")) + list(Path("Apps").rglob("*.png")):
    head = image.read_bytes()[:8]
    if not (head.startswith(b"\xff\xd8\xff") or head.startswith(b"\x89PNG")): bad.append(f"{image}: not a valid JPEG/PNG")
    if image.stat().st_size > 2 * 1024 * 1024: bad.append(f"{image}: larger than 2 MB")
for swift in Path("Apps").rglob("*.swift"):
    for res in __import__("re").findall(r'forResource: "([^"]+)", withExtension: "([^"]+)"', swift.read_text()):
        if not list(Path("Apps").rglob(f"{res[0]}.{res[1]}")): bad.append(f"{swift}: bundled resource {res[0]}.{res[1]} not found")
print("\n".join(bad) if bad else "resources ok"); sys.exit(1 if bad else 0)
PY

step "4/6 git diff --check ($base..HEAD and working tree)"
run git diff --check "$base" HEAD
run git diff --check

step "5/6 Personal-info scan of the current tree (must be empty)"
hits=$(git grep -n -I -i -E '[A-Za-z]:[\\/]Users[\\/]|/Users/[A-Za-z0-9._-]+|/home/[a-z][a-z0-9_-]*/|Asia/[A-Z][a-z]+|America/[A-Z][a-z]+|(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)' -- . ':!*.jpg' ':!*.png' ':!validation/**/*.log' | grep -v -E '/Users/runner|/home/runner' || true)
if [ -n "$hits" ]; then echo "$hits" | cut -c1-160; failed=1; else echo "no local paths / timezone / phone patterns"; fi

step "6/6 Secret and author audit of all reachable history (values never printed)"
# Findings in already-pushed history are reported; findings in HEAD's tree or in commits being
# pushed ($base..HEAD) block the push.
report=$("$PY" scripts/prepush_audit.py)
new_objects=$( { git ls-tree -r HEAD | awk '{print $3}'; git rev-list --objects "$base..HEAD" | awk '{print $1}'; } | sort -u)
printf '%s\n' "$report" | NEW_OBJECTS="$new_objects" "$PY" -c '
import json, os, sys
r = json.load(sys.stdin)
new = set(os.environ["NEW_OBJECTS"].split())
blocking = [f for f in r["sensitive_findings"] if f["object"] in new]
history = [f for f in r["sensitive_findings"] if f["object"] not in new]
print("blobs", r["reachable_blobs_scanned"], "| large", len(r["large_objects"]), "| unexpected authors", len(r["unexpected_author_email_fingerprints"]))
print("findings in HEAD / commits to push:", [(f["rule"], f["path"]) for f in blocking] or "none")
print("findings only in already-pushed history (cannot be removed without rewriting):", sorted({(f["rule"], f["path"]) for f in history}) or "none")
print("historical local-path files:", r["local_environment_path_files"])
sys.exit(1 if blocking or r["large_objects"] or r["unexpected_author_email_fingerprints"] else 0)
' || failed=1

printf '\n%s\n' "$([ "$failed" -eq 0 ] && echo 'PRE-PUSH CHECK: PASS (not a substitute for the Apple SDK build)' || echo 'PRE-PUSH CHECK: FAIL')"
exit "$failed"
