"""Check tracked text without confusing verified GitHub artifact references with phone numbers."""
import json
from pathlib import Path
import re
import subprocess

PATTERNS = {
    # Windows (also JSON-escaped "C:\\\\Users"), macOS and Linux home folders, with or without a trailing slash.
    "user_path": re.compile(r"[A-Za-z]:(?:\\\\|[/\\])Users(?:\\\\|[/\\])|/Users/[A-Za-z0-9._-]+|/home/[A-Za-z][A-Za-z0-9._-]*(?=/|$|[\s\"'`)\]>,;:])", re.I),
    "location": re.compile(r"Asia/[A-Z][a-z]+|America/[A-Z][a-z]+"),
    "phone": re.compile(r"(?<![0-9])1[3-9][0-9]{9}(?![0-9])"),
    # Apple development team ID and a SauceNAO key (40 hex digits) written next to their setting names.
    "team_id": re.compile(r"DEVELOPMENT_TEAM\s*[:=]\s*[\"']?[A-Z0-9]{10}\b"),
    "search_key": re.compile(r"(?i)(?:api_key|saucenao[_ ]?key)\s*[:=]\s*[\"']?[0-9a-f]{40}\b"),
}
ARTIFACT_NAME = re.compile(r"(?:core-linux-evidence|apple-evidence|app-evidence|poc-evidence|app-screenshots|PoC-unsigned-ipa)-[0-9]+-[0-9]+")
ARTIFACT_URL = re.compile(
    r"(https://github\.com/7869123/ios/actions/runs/[0-9]+/artifacts/)[0-9]+(?=$|[\s)\]>,\"'])")
PUBLIC_RUNNER_PATH = re.compile(r"/(?:Users|home)/runner(?=/|$|[\s\"'`])")
# Names allowed on commits to push (AGENTS.md section 6); a missing user.name falls back to the account name.
ALLOWED_NAMES = {"Claude", "AIUtility Development", "github-actions[bot]"}


def artifact_metadata(value, path=()):
    if isinstance(value, dict):
        result = {key: artifact_metadata(item, path + (key,)) for key, item in value.items()}
        if len(path) >= 2 and path[-2] == "artifacts" and isinstance(path[-1], int):
            if ARTIFACT_NAME.fullmatch(str(value.get("name", ""))) and type(value.get("id")) is int:
                result["id"] = "CI_ARTIFACT_ID"
        return result
    if isinstance(value, list):
        return [artifact_metadata(item, path + (index,)) for index, item in enumerate(value)]
    return value


def scan_text(path, text):
    # Only structured validation artifact records get the numeric-ID exception.
    # Malformed JSON, other fields, and other files retain the original checks.
    if path.startswith("validation/") and path.endswith(".json"):
        try:
            text = json.dumps(artifact_metadata(json.loads(text)), ensure_ascii=False, indent=2)
        except (ValueError, TypeError):
            pass
    findings = []
    for number, line in enumerate(text.splitlines(), 1):
        public_paths = PUBLIC_RUNNER_PATH.sub("CI_RUNNER", line)
        for name, pattern in PATTERNS.items():
            candidate = ARTIFACT_URL.sub(r"\1CI_ARTIFACT_ID", public_paths) if name == "phone" else public_paths
            if pattern.search(candidate):
                findings.append((number, name))
    return findings


def scan_objects(objects):
    """Text blobs added by the commits being pushed, so an intermediate commit cannot publish what a later
    commit removes. Paths come from `git rev-list --objects` lines ("<oid> <path>")."""
    findings = []
    for line in objects:
        oid, _, name = line.partition(" ")
        if not name or name.endswith((".jpg", ".png")) or (name.startswith("validation/") and name.endswith(".log")):
            continue
        if subprocess.run(["git", "cat-file", "-t", oid], capture_output=True, text=True).stdout.strip() != "blob":
            continue
        data = subprocess.check_output(["git", "cat-file", "-p", oid])
        if b"\0" in data:
            continue
        for number, kind in scan_text(name, data.decode("utf-8", errors="replace")):
            findings.append(f"{name}:{number}: {kind} pattern in a commit to push (value withheld)")
    return findings


def main():
    paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
    findings = []
    import os
    base = os.environ.get("PREPUSH_BASE")
    if base:
        objects = subprocess.check_output(["git", "rev-list", "--objects", f"{base}..HEAD", "--not", "--remotes=origin"]).decode().splitlines()
        findings += scan_objects(objects)
        # Commit messages and author/committer names of the commits to push.
        log = subprocess.check_output(["git", "log", "--format=%H%x00%an%x00%cn%x00%B%x1e", f"{base}..HEAD", "--not", "--remotes=origin"]).decode()
        for record in filter(None, (r.strip() for r in log.split("\x1e"))):
            sha, author, committer, message = (record.split("\0") + ["", "", "", ""])[:4]
            if author not in ALLOWED_NAMES or committer not in ALLOWED_NAMES:
                findings.append(f"commit {sha[:8]}: author or committer name is not an allowed identity (value withheld)")
            for number, kind in scan_text("COMMIT_MESSAGE", message):
                findings.append(f"commit {sha[:8]} message line {number}: {kind} pattern (value withheld)")
    for name in filter(None, paths):
        if name.endswith((".jpg", ".png")) or (name.startswith("validation/") and name.endswith(".log")):
            continue
        data = Path(name).read_bytes()
        if b"\0" in data:
            continue
        for line, kind in scan_text(name, data.decode("utf-8", errors="replace")):
            findings.append(f"{name}:{line}: {kind} pattern (value withheld)")
    print("\n".join(findings) if findings else "no personal path / location / phone patterns")
    return int(bool(findings))


if __name__ == "__main__":
    raise SystemExit(main())
