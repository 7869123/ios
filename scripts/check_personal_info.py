"""Check tracked text without confusing verified GitHub artifact references with phone numbers."""
import json
from pathlib import Path
import re
import subprocess

PATTERNS = {
    "user_path": re.compile(r"[A-Za-z]:[/\\]Users[/\\]|/Users/[A-Za-z0-9._-]+|/home/[a-z][a-z0-9_-]*/", re.I),
    "location": re.compile(r"Asia/[A-Z][a-z]+|America/[A-Z][a-z]+"),
    "phone": re.compile(r"(?<![0-9])1[3-9][0-9]{9}(?![0-9])"),
}
ARTIFACT_NAME = re.compile(r"(?:core-linux-evidence|apple-evidence|app-evidence|poc-evidence|app-screenshots|PoC-unsigned-ipa)-[0-9]+-[0-9]+")
ARTIFACT_URL = re.compile(
    r"(https://github\.com/7869123/ios/actions/runs/[0-9]+/artifacts/)[0-9]+(?=$|[\s)\]>,\"'])")
PUBLIC_RUNNER_PATH = re.compile(r"/(?:Users|home)/runner(?=/|$|[\s\"'`])")


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


def main():
    paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
    findings = []
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
