"""Scan tracked files and reachable history without printing matched secret values."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).stdout


RULES = {
    "github_token": rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b",
    "provider_key": rb"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}\b",
    "private_key": rb"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----",
    "aws_key": rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "credential_in_url": rb"https?://[^/\s:@]+:[^/@\s]+@",
    "personal_email": rb"\b[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\b",
}


def main():
    rows = git("rev-list", "--objects", "--all").decode().splitlines()
    findings, large, local_paths = [], [], set()
    blob_count = 0
    max_bytes = 0
    for row in rows:
        oid, _, path = row.partition(" ")
        if git("cat-file", "-t", oid).strip() != b"blob":
            continue
        blob_count += 1
        data = git("cat-file", "blob", oid)
        max_bytes = max(max_bytes, len(data))
        if len(data) >= 5 * 1024 * 1024:
            large.append({"path": path, "bytes": len(data), "object": oid})
        if re.search(rb"[A-Z]:[/\\]Users[/\\]", data, re.I):
            local_paths.add(path)
        if path.endswith((".p12", ".pfx", ".mobileprovision", ".key", ".ipa", ".zip", ".bundle")) or Path(path).name.startswith(".env"):
            findings.append({"path": path, "rule": "sensitive_or_generated_file", "object": oid})
        for rule, pattern in RULES.items():
            for match in re.finditer(pattern, data):
                value = match.group()
                if rule == "personal_email" and value.rsplit(b"@", 1)[1].lower() in (b"example.com", b"example.org"):
                    continue
                findings.append({"path": path, "rule": rule, "object": oid,
                                 "line": data[:match.start()].count(b"\n") + 1,
                                 "fingerprint": hashlib.sha256(value).hexdigest()[:12]})
    author_emails = set(git("log", "--all", "--format=%ae%n%ce").decode().splitlines())
    unexpected_authors = [hashlib.sha256(email.encode()).hexdigest()[:12]
                          for email in author_emails if email not in {"aiutility@localhost"}]
    report = {
        "head": git("rev-parse", "HEAD").decode().strip(),
        "reachable_blobs_scanned": blob_count,
        "largest_blob_bytes": max_bytes,
        "sensitive_findings": findings,
        "large_objects": large,
        "unexpected_author_email_fingerprints": unexpected_authors,
        "local_environment_path_files": sorted(local_paths),
        "scope": "Tracked reachable Git history; pattern scan plus manual review, not a guarantee against every possible secret",
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if findings or large or unexpected_authors else 0


if __name__ == "__main__":
    sys.exit(main())
